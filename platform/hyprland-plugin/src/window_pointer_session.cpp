// SPDX-License-Identifier: GPL-3.0-only
#include "window_pointer_session.hpp"
#include "window_wheel.hpp"
#include "window_input_lifecycle.hpp"
#include "window_input_motion.hpp"
#include "ime_popup_scope.hpp"
#include "diagnostic_clock.hpp"
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/view/View.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
// Hyprland 0.56.2 has no public accessor for the seat's surface-local pointer
// snapshot. This ABI-private read is confined to this native implementation;
// the plugin entrypoint already rejects a mismatched compositor ABI hash.
#define private public
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/protocols/core/Seat.hpp>
#include <hyprland/src/protocols/core/DataDevice.hpp>
#undef private
#include <hyprland/src/managers/input/InputManager.hpp>
#include <linux/input-event-codes.h>
#include <algorithm>
#include <utility>
#include <cstdio>
#include <unwind.h>

namespace viewflow::hyprland {
bool WindowPointerSession::acceptsImeKeyboard(const SP<IKeyboard>& keyboard) const {
  return m_keyboard && m_keyboard->acceptsImeKeyboard(keyboard);
}
bool WindowPointerSession::imeKey(const SP<IKeyboard>& keyboard, std::uint32_t key, std::uint32_t state, std::uint32_t timeMs) {
  if (m_keyboard && m_keyboard->imeKey(keyboard, key, state, timeMs)) return true;
  end(WindowPointerRevocation::RouteUnavailable);
  return false;
}
bool WindowPointerSession::imeModifiers(const SP<IKeyboard>& keyboard) {
  if (m_keyboard && m_keyboard->imeModifiers(keyboard)) return true;
  end(WindowPointerRevocation::RouteUnavailable);
  return false;
}


WindowPointerSession::WindowPointerSession(WindowInputTarget target,
                                         Clock::time_point expires, bool allowButtons, bool allowWheel, bool allowKeyboard, bool allowAdmissionWait)
    : m_target(std::move(target)), m_expires(expires), m_allowButtons(allowButtons), m_allowWheel(allowWheel), m_allowKeyboard(allowKeyboard) {
  m_target.onRevoked([this](WindowPointerRevocation reason) { end(reason); });
  m_target.onImePopupRetired([this](WP<CWLSurfaceResource> recipient) {
    if (!retiresImePointerRecipient(m_ended, m_started, m_owned.lock().get(), recipient.lock().get())) return;
    const auto owned = m_owned.lock();
    const auto timeMs = static_cast<std::uint32_t>(std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count());
    // Candidate hide/focus loss retires only this pointer recipient. An old
    // button-up cannot acquire another surface; the exact keyboard stays owned.
    releaseButtons(timeMs);
    m_started = false;
    m_owned.reset();
    m_previous.reset();
    if (g_pSeatManager && owned && g_pSeatManager->m_state.pointerFocus.lock() == owned)
      g_pSeatManager->setPointerFocus(nullptr, {});
  });
  if (!g_pEventLoopManager || Clock::now() >= expires) {
    end();
    return;
  }
  if (allowKeyboard) {
    m_keyboard = std::make_unique<WindowKeyboardSession>(m_target, expires, allowAdmissionWait);
    if (!m_keyboard->active() && !m_keyboard->admissionPending()) { end(WindowPointerRevocation::RouteUnavailable); return; }
  }
  // Expiry is independent of incoming pointer traffic or output redraws.
  // This object is deliberately immovable and removes its callbacks in end().
  m_expiryTimer = makeShared<CEventLoopTimer>(
      (admissionPending() ? m_keyboard->admissionDeadline() : expires) - Clock::now(),
      [this](SP<CEventLoopTimer>, void *) {
        if (admissionPending()) pollAdmission();
        else end(WindowPointerRevocation::Expired);
      }, nullptr);
  g_pEventLoopManager->addTimer(m_expiryTimer);
  m_tick = Event::bus()->m_events.tick.listen([this] {
    if (admissionPending()) { pollAdmission(); return; }
    if (const auto reason = inactiveReason(); reason != WindowPointerRevocation::None)
      end(reason);
  });
  if (g_pSeatManager) m_pointerFocusChange = g_pSeatManager->m_events.pointerFocusChange.listen([this] {
    const auto owned = m_owned.lock();
    const auto current = g_pSeatManager->m_state.pointerFocus.lock();
    // Observe only a non-null external replacement of our installed pointer.
    // Normal cleanup and resendEnter's temporary null are not actor evidence.
    if (m_ended || !m_started || !owned || !current || current == owned || m_focusTrace.count) return;
    const auto role = [](const SP<CWLSurfaceResource>& surface) -> std::uint32_t {
      const auto wl = Desktop::View::CWLSurface::fromResource(surface);
      const auto view = wl ? wl->view() : nullptr;
      return view ? 1U + static_cast<std::uint32_t>(view->type()) : 0U;
    };
    // bits 0 desktop focus, 1 keyboard focus, 2 same client, 3 held buttons,
    // 4 keyboard active, 5 focus snapshot invalidated;
    // nibbles 8 and 12 are current/owned view type + 1.
    m_focusTrace.roles = std::uint32_t(current == Desktop::focusState()->surface()) |
        (std::uint32_t(current == g_pSeatManager->m_state.keyboardFocus.lock()) << 1U) |
        (std::uint32_t(current->client() == owned->client()) << 2U) |
        (std::uint32_t(ownsButtons()) << 3U) |
        (std::uint32_t(m_keyboard && m_keyboard->active()) << 4U) |
        (std::uint32_t(m_externalFocusChanged) << 5U) |
        (role(current) << 8U) | (role(owned) << 12U);
    m_focusTrace.observedNs = diagnosticMonotonicNs();
    _Unwind_Backtrace([](_Unwind_Context* context, void* data) {
      auto& trace = *static_cast<PointerFocusTrace*>(data);
      if (trace.count == trace.frames.size()) return _URC_END_OF_STACK;
      const auto ip = _Unwind_GetIP(context);
      if (ip) trace.frames[trace.count++] = ip;
      return _URC_NO_REASON;
    }, &m_focusTrace);
  });
  if (g_pInputManager) {
    const auto initial = g_pInputManager->getMouseCoordsInternal().floor();
    m_initialGlobalPointer = initial;
    m_initialDesktopFocus = Desktop::focusState()->surface();
    m_initialKeyboardFocus = g_pSeatManager ? g_pSeatManager->m_state.keyboardFocus : WP<CWLSurfaceResource>{};
    m_initialDesktopPresent = bool(m_initialDesktopFocus.lock());
    m_initialKeyboardPresent = bool(m_initialKeyboardFocus.lock());
    if (g_pSeatManager) m_seatFocusIdentityChange = g_pSeatManager->m_events.keyboardFocusChange.listen([this] {
      if (g_pSeatManager->m_state.keyboardFocus.lock() != m_initialKeyboardFocus.lock())
        m_externalFocusChanged = true;
    });
    m_desktopFocusIdentityChange = Event::bus()->m_events.input.keyboard.focus.listen([this](SP<CWLSurfaceResource> surface) {
      if (surface != m_initialDesktopFocus.lock()) m_externalFocusChanged = true;
    });
    const WP<CWLSurfaceResource> preparedPointer = g_pSeatManager ? g_pSeatManager->m_state.pointerFocus : WP<CWLSurfaceResource>{};
    const bool preparedPointerPresent = bool(preparedPointer.lock());
    m_stationaryRecheck = Event::bus()->m_events.input.mouse.move.listen(
        [this, initial, preparedPointer, preparedPointerPresent](Vector2D position, Event::SCallbackInfo& info) {
      // BEGIN can establish keyboard focus before the first pointer command.
      // Protect that bounded gap only while the exact keyboard binding and
      // original pointer snapshot both remain installed.
      if (g_pSeatManager && suppressPreparedKeyboardRecheck(
              !m_ended && !m_started && !m_target.revoked() && Clock::now() < m_expires &&
                  (!preparedPointerPresent || bool(preparedPointer.lock())),
              m_keyboard && m_keyboard->active(), preparedPointer.lock().get(),
              g_pSeatManager->m_state.pointerFocus.lock().get(),
              initial.x, initial.y, position.x, position.y))
        info.cancelled = true;
      if (suppressStationaryPointerRecheck(!m_ended && m_started && !m_target.revoked() &&
              Clock::now() < m_expires, m_owned.lock().get(),
              g_pSeatManager ? g_pSeatManager->m_state.pointerFocus.lock().get() : nullptr,
              initial.x, initial.y, position.x, position.y))
        info.cancelled = true;
    });
  }
}

void WindowPointerSession::pollAdmission() {
  if (!admissionPending()) return;
  m_keyboard->pollAdmission();
  if (admissionPending()) return;
  if (!m_keyboard->active()) { end(WindowPointerRevocation::RouteUnavailable); return; }
  if (m_expiryTimer) m_expiryTimer->updateTimeout(m_expires - Clock::now());
}

WindowPointerSession::~WindowPointerSession() { end(); }

bool WindowPointerSession::active() const {
  return inactiveReason() == WindowPointerRevocation::None;
}

WindowPointerRevocation WindowPointerSession::resizeGuardReason() const {
  if (!m_ended || m_endReason != WindowPointerRevocation::Resized || !cleanupSucceeded())
    return WindowPointerRevocation::RouteUnavailable;
  const auto reason = m_target.resizeGuardReason();
  if (reason != WindowPointerRevocation::Resized) return reason;
  return Clock::now() >= m_expires ? WindowPointerRevocation::Expired : reason;
}

std::unique_ptr<WindowPointerSession> WindowPointerSession::rebindAfterResize(
    std::uint64_t windowAddress, std::uint64_t surfaceAddress,
    std::uint32_t pid, const Vector2D& extent, Clock::time_point expires) const {
  if (resizeGuardReason() != WindowPointerRevocation::Resized || expires <= Clock::now())
    return {};
  auto target = m_target.rebindAfterResize(windowAddress, surfaceAddress, pid, extent);
  if (!target) return {};
  // Capabilities come exclusively from the retired session, never the request.
  return std::make_unique<WindowPointerSession>(std::move(*target), expires,
      m_allowButtons, m_allowWheel, m_allowKeyboard);
}

bool WindowPointerSession::renew(std::uint64_t windowAddress, std::uint64_t surfaceAddress,
                                 std::uint32_t pid, const Vector2D& extent,
                                 Clock::time_point expires, bool allowButtons, bool allowWheel, bool allowKeyboard) {
  if (!active() || allowButtons != m_allowButtons || allowWheel != m_allowWheel || allowKeyboard != m_allowKeyboard || !m_expiryTimer || expires <= m_expires ||
      !m_target.matches(windowAddress, surfaceAddress, pid, extent))
    return false;
  const auto now = Clock::now();
  if (now >= m_expires || expires <= now)
    return false;
  if (m_keyboard && !m_keyboard->renew(expires)) return false;
  // Preserve the exact focused surface, prior-focus snapshot and session
  // listeners. Recreating the session sends leave/enter on every renewal and
  // cannot preserve future button ownership during an uninterrupted drag.
  m_expires = expires;
  m_expiryTimer->updateTimeout(expires - now);
  return true;
}

WindowPointerRevocation WindowPointerSession::inactiveReason() const {
  if (m_ended) return observedRevocation(m_endReason, m_target.revocationReason());
  if (m_target.revoked()) return m_target.revocationReason();
  if (Clock::now() >= m_expires) return WindowPointerRevocation::Expired;
  if (m_keyboard && !m_keyboard->active()) return WindowPointerRevocation::RouteUnavailable;
  if (m_started) {
    if ((!g_pSeatManager || g_pSeatManager->m_state.pointerFocus.lock() != m_owned.lock()) &&
        !mayRetainKeyboardWithoutPointer()) {
      recordFocusDiagnostic(1);
      if (m_keyboard && !m_focusDiagnosticRecorded) {
        m_focusDiagnosticRecorded = true;
        const auto owned = m_owned.lock();
        const auto current = g_pSeatManager ? g_pSeatManager->m_state.pointerFocus.lock() : nullptr;
        std::fprintf(stderr,
            "viewflow-pointer-focus-retire owned_present=%d current_present=%d same_client=%d held_buttons=%d keyboard_active=%d\n",
            bool(owned), bool(current), owned && current && owned->client() == current->client(),
            ownsButtons(), m_keyboard->active());
      }
      return WindowPointerRevocation::FocusChanged;
    }
    if (!m_target.resolve(m_lastPoint))
      return m_target.revoked() ? m_target.revocationReason() : WindowPointerRevocation::TargetInvalid;
  }
  return WindowPointerRevocation::None;
}

bool WindowPointerSession::move(const Vector2D &point,
                                Clock::time_point eventDeadline,
                                std::uint32_t timeMs) {
  if (m_ended)
    return false;
  const auto now = Clock::now();
  if (now >= m_expires || m_target.revoked()) {
    end(inactiveReason());
    return false;
  }
  if (now >= eventDeadline)
    return false;
  const auto target = m_target.resolve(point);
  if (!target) {
    if (m_target.revoked())
      end(m_target.revocationReason());
    return false;
  }
  if (m_started && g_pSeatManager->m_state.pointerFocus.lock() != m_owned.lock()) {
    if (!mayRetainKeyboardWithoutPointer()) {
      recordFocusDiagnostic(2);
      // An active pressed grab or keyboard route needs separate recovery.
      m_target.revoke(WindowPointerRevocation::FocusChanged);
      end(WindowPointerRevocation::FocusChanged);
      return false;
    }
    // A new motion resolves and re-enters its actual target. Passive focus
    // changes do not terminate hover, and no old focus is restored here.
    m_started = false;
    m_owned.reset();
    m_previous.reset();
  }
  // Retain a pressed grab's exact surface. Cross-subsurface and out-of-window
  // drag routing needs an explicit geometry/grab implementation, not refocus.
  if (ownsButtons() && target->surface != m_owned.lock()) return false;
  if (!m_started) {
    m_previous = g_pSeatManager->m_state.pointerFocus;
    m_previousLocal = g_pSeatManager->m_lastLocalCoords;
  }
  // Target resolution and native send occur synchronously on the compositor
  // thread. Keep the target objects alive until the frame is delivered.
  if (Clock::now() >= eventDeadline || Clock::now() >= m_expires)
    return false;
  m_owned = target->surface;
  m_target.observeResolved(*target);
  m_lastPoint = point;
  m_started = true;
  g_pSeatManager->setPointerFocus(target->surface, target->local);
  // Focus-change listeners run synchronously and may revoke or take focus.
  // They must see our ownership snapshot, and cannot be followed by injection.
  if (m_ended || m_target.revoked() ||
      Clock::now() >= m_expires || g_pSeatManager->m_state.pointerFocus.lock() != target->surface) {
    if (g_pSeatManager->m_state.pointerFocus.lock() != target->surface) recordFocusDiagnostic(3);
    if (!m_ended) end(inactiveReason() == WindowPointerRevocation::None ?
        WindowPointerRevocation::Expired : inactiveReason());
    return false;
  }
  // An event can become obsolete while focus listeners run. Drop that motion
  // without ending the still-live window route or releasing unrelated input.
  if (Clock::now() >= eventDeadline) return false;
  g_pSeatManager->sendPointerMotion(timeMs, target->local);
  g_pSeatManager->sendPointerFrame();
  return true;
}

namespace {
constexpr std::array<std::uint32_t, 5> BUTTON_CODES{BTN_LEFT, BTN_MIDDLE, BTN_RIGHT, BTN_SIDE, BTN_EXTRA};
std::uint32_t cleanupTimeMs() {
  return static_cast<std::uint32_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
      WindowPointerSession::Clock::now().time_since_epoch()).count());
}
}

bool WindowPointerSession::ownsButtons() const {
  return std::ranges::any_of(m_buttons, [](const auto& recipients) { return !recipients.empty(); });
}

bool WindowPointerSession::suppressConvenienceMotion() const {
  if (!g_pInputManager || !g_pSeatManager || !m_started || m_ended || !m_owned.lock()) return false;
  const auto desktop = m_initialDesktopFocus.lock();
  const auto keyboard = m_initialKeyboardFocus.lock();
  const auto point = g_pInputManager->getMouseCoordsInternal().floor();
  return suppressCompositorFocusMotion(active(), g_pSeatManager->m_state.pointerFocus.lock() == m_owned.lock(),
      (!m_initialDesktopPresent || desktop) && Desktop::focusState()->surface() == desktop,
      (!m_initialKeyboardPresent || keyboard) && g_pSeatManager->m_state.keyboardFocus.lock() == keyboard,
      !m_externalFocusChanged,
      !localPointerPositionChanged(m_initialGlobalPointer.x, m_initialGlobalPointer.y, point.x, point.y));
}

void WindowPointerSession::recordFocusDiagnostic(std::uint32_t phase) const {
  // Low two bits: 1=inactive check, 2=before move, 3=after setPointerFocus.
  // Bits 2..9: seat, mouse, DND, owned, current, exact equality, keyboard, buttons.
  // This bounded first observation contains neither addresses nor input data.
  if (m_focusDiagnostic) return;
  const auto owned = m_owned.lock();
  const auto current = g_pSeatManager ? g_pSeatManager->m_state.pointerFocus.lock() : nullptr;
  m_focusDiagnostic = phase | (bool(g_pSeatManager) << 2U) |
      ((g_pSeatManager && bool(g_pSeatManager->m_mouse.lock())) << 3U) |
      ((PROTO::data && PROTO::data->dndActive()) << 4U) |
      (bool(owned) << 5U) | (bool(current) << 6U) | ((owned && owned == current) << 7U) |
      ((m_keyboard && m_keyboard->active()) << 8U) | (ownsButtons() << 9U);
}

bool WindowPointerSession::mayRetainKeyboardWithoutPointer() const {
  return mayResumeHover(bool(m_keyboard), bool(g_pSeatManager), ownsButtons()) ||
      viewflow::hyprland::mayRetainKeyboardWithoutPointer(
      m_keyboard && m_keyboard->active(), bool(m_owned.lock()), bool(g_pSeatManager),
      g_pSeatManager && bool(g_pSeatManager->m_state.pointerFocus.lock()), ownsButtons());
}

bool WindowPointerSession::button(const Vector2D& point, std::uint32_t button,
                                   std::uint32_t state, Clock::time_point deadline,
                                   std::uint32_t timeMs) {
  if (!m_allowButtons || button < 1 || button > BUTTON_CODES.size() || state < 1 || state > 2 || !active()) return false;
  auto& recipients = m_buttons[button - 1];
  const bool pressed = state == 1;
  if (pressed == !recipients.empty()) return false; // duplicate down or orphan up
  if (!PROTO::seat || !PROTO::data || PROTO::data->dndActive()) {
    end(WindowPointerRevocation::RouteUnavailable);
    return false;
  }
  if (!move(point, deadline, timeMs)) return false;
  const auto owned = m_owned.lock();
  const auto code = BUTTON_CODES[button - 1];
  if (pressed) {
    std::vector<WP<CWLPointerResource>> targets;
    std::size_t inspected = 0;
    for (const auto& pointer : PROTO::seat->m_pointers) {
      if (++inspected > 1024) return false;
      if (!pointer || pointer->m_currentSurface.lock() != owned || !pointer->good()) continue;
      if (std::ranges::find(pointer->m_pressedButtons, code) != pointer->m_pressedButtons.end()) return false;
      if (targets.size() >= 64) return false;
      targets.emplace_back(pointer);
    }
    if (targets.empty() || Clock::now() >= deadline || !active()) return false;
    recipients = std::move(targets);
    for (const auto& weak : recipients) {
      if (Clock::now() >= deadline || Clock::now() >= m_expires) {
        end(WindowPointerRevocation::Expired);
        return false;
      }
      const auto pointer = weak.lock();
      if (!pointer) {
        end(WindowPointerRevocation::RouteUnavailable);
        return false;
      }
      pointer->sendButton(timeMs, code, WL_POINTER_BUTTON_STATE_PRESSED);
      pointer->sendFrame();
    }
    if (std::ranges::any_of(recipients, [code](const auto& weak) {
          const auto pointer = weak.lock();
          return !pointer || std::ranges::find(pointer->m_pressedButtons, code) == pointer->m_pressedButtons.end();
        })) {
      end(WindowPointerRevocation::RouteUnavailable);
      return false;
    }
  } else {
    if (Clock::now() >= deadline || !active()) return false;
    bool sent = false;
    for (const auto& weak : recipients) {
      if (Clock::now() >= deadline || Clock::now() >= m_expires) {
        end(WindowPointerRevocation::Expired);
        return false;
      }
      if (const auto pointer = weak.lock(); pointer && pointer->m_currentSurface.lock() == owned &&
          std::ranges::find(pointer->m_pressedButtons, code) != pointer->m_pressedButtons.end()) {
        pointer->sendButton(timeMs, code, WL_POINTER_BUTTON_STATE_RELEASED);
        pointer->sendFrame();
        if (std::ranges::find(pointer->m_pressedButtons, code) != pointer->m_pressedButtons.end()) {
          end(WindowPointerRevocation::RouteUnavailable);
          return false;
        }
        sent = true;
      }
    }
    recipients.clear();
    if (!sent) return false;
  }
  return true;
}

bool WindowPointerSession::wheel(const Vector2D& point, std::int32_t vertical120,
                                std::int32_t horizontal120, Clock::time_point deadline,
                                std::uint32_t timeMs) {
  const auto axes = windowWheelAxes(vertical120, horizontal120);
  if (!m_allowWheel || !axes || !active() || Clock::now() >= deadline) return false;
  if (!PROTO::seat || !PROTO::data || PROTO::data->dndActive() ||
      !(PROTO::seat->m_currentCaps & eHIDCapabilityType::HID_INPUT_CAPABILITY_POINTER)) return false;
  if (!move(point, deadline, timeMs)) return false;
  const auto owned = m_owned.lock();
  std::vector<SP<CWLPointerResource>> recipients;
  std::size_t inspected = 0;
  for (const auto& pointer : PROTO::seat->m_pointers) {
    if (++inspected > 1024) return false;
    if (!pointer || !pointer->good() || pointer->m_currentSurface.lock() != owned) continue;
    if (recipients.size() >= 64) return false;
    recipients.push_back(pointer);
  }
  if (recipients.empty()) return false;
  for (const auto& pointer : recipients) {
    if (Clock::now() >= deadline || !active() || pointer->m_currentSurface.lock() != owned) return false;
    pointer->sendAxisSource(WL_POINTER_AXIS_SOURCE_WHEEL);
    for (std::size_t index = 0; index < axes->size(); ++index) {
      const auto& value = (*axes)[index];
      if (!value.value120) continue;
      const auto axis = index == 0 ? WL_POINTER_AXIS_VERTICAL_SCROLL : WL_POINTER_AXIS_HORIZONTAL_SCROLL;
      if (pointer->version() >= 8) pointer->sendAxisValue120(axis, value.value120);
      // Do not round fractional detents into legacy full steps. Such clients
      // still receive the proportional axis distance; no delayed residual can
      // escape into another window or frame.
      else if (value.value120 % 120 == 0) pointer->sendAxisDiscrete(axis, value.value120 / 120);
      pointer->sendAxisRelativeDirection(axis, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
      pointer->sendAxis(timeMs, axis, value.distance);
    }
    pointer->sendFrame();
  }
  return true;
}

void WindowPointerSession::releaseButtons(std::uint32_t timeMs) {
  if (!ownsButtons()) return;
  const auto owned = m_owned.lock();
  // Never cancel another actor's drag, nor send releases into changed focus.
  if (owned && PROTO::data && PROTO::data->dndActive() &&
      PROTO::data->m_dnd.originSurface.lock() == owned)
    PROTO::data->abortDndIfPresent();
  for (std::size_t index = 0; index < m_buttons.size(); ++index) {
    for (const auto& weak : m_buttons[index]) {
      const auto pointer = weak.lock();
      if (!pointer) continue;
      const auto code = BUTTON_CODES[index];
      const bool pressed = std::ranges::find(pointer->m_pressedButtons, code) != pointer->m_pressedButtons.end();
      cleanupRecordedPointerButton(bool(owned), pointer->m_currentSurface.lock() == owned, pressed,
          [&] {
            pointer->sendButton(timeMs, code, WL_POINTER_BUTTON_STATE_RELEASED);
            pointer->sendFrame();
          }, [&] {
            // Unmap may clear focus before our callback. Retire only this
            // recorded recipient/button and its original-surface serials.
            if (g_pSeatManager)
              g_pSeatManager->clearPointerButtonSerials(pointer->m_owner.lock(), owned, code);
            std::erase(pointer->m_pressedButtons, code);
          });
    }
    m_buttons[index].clear();
  }
}

void WindowPointerSession::end(WindowPointerRevocation reason, bool preserveFocus) {
  if (m_ended)
    return;
  m_ended = true;
  m_endReason = retirementReason(reason);
  m_target.onRevoked({});
  m_target.onImePopupRetired({});
  releaseButtons(cleanupTimeMs());
  if (m_keyboard) m_keyboard->end(mayRestoreInputFocus(m_endReason, m_target.revoked(), preserveFocus));
  m_tick.reset();
  m_stationaryRecheck.reset();
  m_pointerFocusChange.reset();
  m_seatFocusIdentityChange.reset();
  m_desktopFocusIdentityChange.reset();
  if (m_expiryTimer) {
    m_expiryTimer->cancel();
    if (g_pEventLoopManager)
      g_pEventLoopManager->removeTimer(m_expiryTimer);
    m_expiryTimer.reset();
  }
  // A takeover/unmap/lock revocation must never restore stale focus. An
  // ordinary release may restore only while our exact focused surface remains
  // installed and the target's safety checks still pass.
  if (m_started && mayRestoreInputFocus(m_endReason, m_target.revoked(), preserveFocus) && cleanupSucceeded() && g_pSeatManager &&
      m_target.resolve(m_lastPoint) &&
      g_pSeatManager->m_state.pointerFocus.lock() == m_owned.lock()) {
    const auto previous = m_previous.lock();
    if (previous && previous->m_mapped)
      g_pSeatManager->setPointerFocus(previous, m_previousLocal);
    else
      g_pSeatManager->setPointerFocus(nullptr, {});
  }
  // Preserve resize-only as an observation, without restoring authority. Its
  // still-live target listeners may promote it to a terminal safety reason.
  m_target.revoke(m_endReason);
  m_owned.reset();
  m_previous.reset();
}

bool WindowPointerSession::key(std::uint16_t page, std::uint16_t usage, std::uint32_t state,
    bool repeat, Clock::time_point deadline, std::uint32_t timeMs) {
  if (!m_allowKeyboard || !m_keyboard || !active()) return false;
  if (m_keyboard->key(page, usage, state, repeat, deadline, timeMs)) return true;
  // Never leave a failed/late keyboard transition silently pending.
  end(WindowPointerRevocation::RouteUnavailable);
  return false;
}

} // namespace viewflow::hyprland

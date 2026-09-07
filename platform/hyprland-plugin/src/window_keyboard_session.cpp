// SPDX-License-Identifier: GPL-3.0-only
#include "window_keyboard_session.hpp"
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>

// Exact-recipient checks depend on this installed, ABI-hash-checked compositor.
// The private surface snapshot is never used to route to a different recipient.
#define private public
#include <hyprland/src/protocols/InputMethodV2.hpp>
#include <hyprland/src/protocols/core/Seat.hpp>
#undef private
#include <hyprland/src/managers/input/InputManager.hpp>
#include <linux/input-event-codes.h>
#include <algorithm>
#include <ranges>

namespace viewflow::hyprland {

KeyboardRouteFailure WindowKeyboardSession::routeFailure() const {
  return keyboardRouteFailure(bool(g_pSeatManager), bool(g_pInputManager), bool(PROTO::seat),
      PROTO::seat && (PROTO::seat->m_currentCaps & eHIDCapabilityType::HID_INPUT_CAPABILITY_KEYBOARD), false);
}

SP<CInputMethodV2> WindowKeyboardSession::scopedIme() const {
  if (!g_pInputManager || !g_pSeatManager) return nullptr;
  const auto owned = m_owned.lock();
  const auto ime = g_pInputManager->m_relay.m_inputMethod.lock();
  const auto text = g_pInputManager->m_relay.getFocusedTextInput();
  if (!owned || !ime || !ime->good() || !ime->m_active || !ime->client() || !text || !text->isEnabled() ||
      text->focusedSurface() != owned || g_pSeatManager->m_state.keyboardFocus.lock() != owned ||
      Desktop::focusState()->surface() != owned) return nullptr;
  return ime;
}

SP<IKeyboard> WindowKeyboardSession::sourceKeyboardCandidate() const {
  if (!g_pInputManager || !g_pSeatManager) return nullptr;
  const auto permitted = [this](const SP<IKeyboard>& keyboard) {
    return keyboard && !keyboard->isVirtual() && keyboard->m_allowed &&
        (keyboard->m_enabled || m_target.captureLoopbackKeyboard(keyboard.get()));
  };
  if (const auto current = g_pSeatManager->m_keyboard.lock(); permitted(current)) return current;
  for (const auto& keyboard : g_pInputManager->m_keyboards | std::views::reverse)
    if (permitted(keyboard)) return keyboard;
  return nullptr;
}

bool WindowKeyboardSession::routeAvailable() const {
  return routeFailure() == KeyboardRouteFailure::None;
}

bool WindowKeyboardSession::compatibleSeatIme(const SP<IKeyboard>& keyboard) const {
  const auto ime = g_pInputManager ? g_pInputManager->m_relay.m_inputMethod.lock() : nullptr;
  return compatibleImeSeatKeyboard(keyboard && keyboard->isVirtual(), ime && ime->good(),
      keyboard ? keyboard->getClient() : nullptr, ime ? ime->client() : nullptr);
}

WindowKeyboardSession::WindowKeyboardSession(WindowInputTarget& target, Clock::time_point expires, bool allowAdmissionWait)
    : m_target(target), m_allowAdmissionWait(allowAdmissionWait), m_expires(expires) {
  if (const auto failure = routeFailure(); !keyboardRouteMayStartAdmission(failure, allowAdmissionWait)) {
    m_startupFailure = 1U | (static_cast<std::uint32_t>(failure) << 16U); return;
  }
  if (Clock::now() >= expires) { m_startupFailure = 2; return; }
  const auto bound = target.resolveKeyboard();
  if (!bound) { m_startupFailure = 3; return; }
  if (!g_pSeatManager->m_keyboard) { m_startupFailure = 4; return; }
  m_owned = bound->surface;
  m_previous = g_pSeatManager->m_state.keyboardFocus;
  m_started = true;
  m_admission.emplace(Clock::now(), expires);
  // This is the exact authorized target's normal focus transition; it neither
  // warps the pointer nor injects any key. An old app's IME grab must actually
  // disappear before BEGIN can be acknowledged and application input enabled.
  Desktop::focusState()->rawSurfaceFocus(bound->surface, bound->window);
  m_focusChange = g_pSeatManager->m_events.keyboardFocusChange.listen([this] {
    if (g_pSeatManager->m_state.keyboardFocus.lock() != m_owned.lock()) {
      // resendEnterEvents clears then restores seat focus synchronously. Real
      // focus loss can initially look identical, so suspend sends and verify
      // restoration at idle rather than treating a null notification as final.
      if (!m_ended && g_pEventLoopManager && mayDeferEmptySeatFocus(
              m_admission && m_admission->phase() == KeyboardAdmissionGate::Phase::Ready,
              bool(g_pSeatManager->m_state.keyboardFocus.lock()), exactBindingFailure(),
              routeAvailable(), Clock::now() < m_expires)) {
        if (!m_focusRecheck) {
          m_focusRecheckLife = std::make_shared<int>(0);
          const std::weak_ptr<int> life = m_focusRecheckLife;
          m_focusRecheck = g_pEventLoopManager->doLaterLock([this, life] {
            // Idle callbacks can already be copied out of the manager's queue
            // when another callback destroys this session. A weak token also
            // fences that case, beyond removing the queued callback.
            if (life.expired()) return;
            cancelFocusRecheck();
            if (!active()) end(false);
          });
        }
        return;
      }
      if (admissionPending()) m_startupFailure = 9U | (1U << 16U);
      end(false);
    } else if (m_focusRecheck) {
      const bool restored = !m_ended && m_started && Clock::now() < m_expires &&
          restoredSeatFocus(exactBindingFailure(), routeAvailable(), Clock::now() < m_expires);
      cancelFocusRecheck();
      if (!restored) end(false);
      else if ((m_runtimeDiagnostic & 0x0fffffffU) == (1U << 16U))
        m_runtimeDiagnostic = 0; // only the verified transient observation
    }
  });
  pollAdmission();
}

void WindowKeyboardSession::pollAdmission() {
  if (!admissionPending()) return;
  const auto route = routeFailure();
  auto bindingFailure = targetFocusFailure();
  bool valid = route == KeyboardRouteFailure::None && Clock::now() < m_expires && bindingFailure == 0;
  const auto ime = g_pInputManager ? g_pInputManager->m_relay.m_inputMethod.lock() : nullptr;
  const auto scoped = scopedIme();
  // An old app's grab may drain after focus. An exact target-owned grab is a
  // valid source IME route and must never be mistaken for a blocking grab.
  const bool foreignGrab = ime && ime->hasGrab() && !scoped;
  bool keyboardReady = false;
  if (valid && !foreignGrab && Clock::now() < m_admission->deadline()) {
    const auto keyboard = sourceKeyboardCandidate();
    keyboardReady = bool(keyboard);
    if (keyboardReady) {
      {
        // Remote key transitions establish this session's held state. A local
        // modifier held while selecting a proxy must neither block admission
        // nor become an unsolicited modifier in the remote window.
        const auto& mods = keyboard->m_modifiersState;
        m_state = WindowKeyboardState::create(keyboard->m_xkbKeymap,
            {0U, 0U, mods.locked, mods.group});
        m_sourceKeyboard = keyboard;
        if (scoped) m_ime = scoped;
        bindingFailure |= exactBindingFailure();
        const auto current = g_pSeatManager->m_keyboard.lock();
        const bool trustedVirtual = compatibleSeatIme(current);
        if (keyboardAdmissionWaitsForForeignVirtual(bindingFailure, m_allowAdmissionWait,
            current && current->isVirtual(), trustedVirtual)) {
          // Grab destruction and virtual-device destruction are distinct client
          // requests. Keep the original admission deadline between those events.
          keyboardReady = false;
          valid = true;
        } else valid = bindingFailure == 0;
      }
    }
  }
  if (!m_allowAdmissionWait && (foreignGrab || !keyboardReady)) valid = false;
  const auto phase = m_admission->observe(Clock::now(), valid, foreignGrab, keyboardReady);
  if (phase == KeyboardAdmissionGate::Phase::Rejected) {
    m_startupFailure = (valid ? (foreignGrab ? 10U : 11U) : 9U) | bindingFailure
        | (Clock::now() >= m_expires ? (1U << 18U) : 0U)
        | (route != KeyboardRouteFailure::None ? (static_cast<std::uint32_t>(route) << 24U) : 0U);
    end(false);
  }
}

WindowKeyboardSession::~WindowKeyboardSession() { end(false); }

void WindowKeyboardSession::cancelFocusRecheck() {
  m_focusRecheckLife.reset();
  m_focusRecheck.reset();
}

std::uint32_t WindowKeyboardSession::targetFocusFailure() const {
  const auto bound = m_target.resolveKeyboard();
  const auto owned = m_owned.lock();
  std::uint32_t failure = 0;
  if (!bound) failure |= 1U << 12U;
  if (!bound || bound->surface != owned) failure |= 1U << 13U;
  if (!g_pSeatManager || g_pSeatManager->m_state.keyboardFocus.lock() != owned) failure |= 1U << 16U;
  if (Desktop::focusState()->surface() != owned) failure |= 1U << 17U;
  return failure;
}

std::uint32_t WindowKeyboardSession::exactBindingFailure() const {
  const auto keyboard = m_sourceKeyboard.lock();
  std::uint32_t failure = targetFocusFailure();
  if (!m_state) failure |= 1U << 8U;
  if (!keyboard) failure |= 1U << 9U;
  if (keyboard && !keyboard->m_enabled && !m_target.captureLoopbackKeyboard(keyboard.get())) failure |= 1U << 10U;
  if (keyboard && !keyboard->m_allowed) failure |= 1U << 11U;
  const auto current = g_pSeatManager ? g_pSeatManager->m_keyboard.lock() : nullptr;
  const bool trustedVirtual = compatibleSeatIme(current);
  if (!current || (current != keyboard && !trustedVirtual)) failure |= 1U << 14U;
  if (!m_state || !keyboard || !m_state->matchesKeymap(keyboard->m_xkbKeymap)) failure |= 1U << 15U;
  return failure;
}

bool WindowKeyboardSession::exactBindingValid() const {
  return exactBindingFailure() == 0;
}

bool WindowKeyboardSession::active() const {
  const bool valid = !m_ended && m_started && m_admission && m_admission->phase() == KeyboardAdmissionGate::Phase::Ready
      && Clock::now() < m_expires && routeAvailable() && exactBindingValid();
  if (!valid && !m_runtimeDiagnostic && m_admission && m_admission->phase() == KeyboardAdmissionGate::Phase::Ready)
    m_runtimeDiagnostic = runtimeState();
  return valid;
}

std::uint32_t WindowKeyboardSession::runtimeState() const {
  // 0 ended, 1 not started, 2 no admission, 3 admission not ready, 4 expired,
  // 5 seat keyboard focus present;
  // 8..17 exactBindingFailure; 24..27 routeFailure; 28 current present,
  // 29 virtual, 30 equals bound physical, 31 registered IME-compatible.
  const auto current = g_pSeatManager ? g_pSeatManager->m_keyboard.lock() : nullptr;
  return exactBindingFailure() | std::uint32_t(m_ended) | (std::uint32_t(!m_started) << 1U) |
      (std::uint32_t(!m_admission) << 2U) |
      (std::uint32_t(m_admission && m_admission->phase() != KeyboardAdmissionGate::Phase::Ready) << 3U) |
      (std::uint32_t(Clock::now() >= m_expires) << 4U) |
      (std::uint32_t(g_pSeatManager && bool(g_pSeatManager->m_state.keyboardFocus.lock())) << 5U) |
      (static_cast<std::uint32_t>(routeFailure()) << 24U) |
      (std::uint32_t(bool(current)) << 28U) |
      (std::uint32_t(current && current->isVirtual()) << 29U) |
      (std::uint32_t(current && current == m_sourceKeyboard.lock()) << 30U) |
      (std::uint32_t(compatibleSeatIme(current)) << 31U);
}

bool WindowKeyboardSession::renew(Clock::time_point expires) {
  if (!active() || expires <= m_expires) return false;
  m_expires = expires;
  return true;
}

bool WindowKeyboardSession::key(std::uint16_t page, std::uint16_t usage, std::uint32_t state,
    bool repeat, Clock::time_point deadline, std::uint32_t timeMs) {
  if (!active() || Clock::now() >= deadline) return false;
  const auto code = keyboardUsageToEvdev(page, usage);
  if (!code) return false;
  const auto ime = scopedIme();
  const auto currentIme = g_pInputManager->m_relay.m_inputMethod.lock();
  if (currentIme && currentIme->hasGrab() && !ime) return false;
  std::vector<WP<CInputMethodKeyboardGrabV2>> grabs;
  if (state == 1 && !repeat && ime && ime->hasGrab()) {
    if (m_ime && m_ime.lock() != ime) return false;
    m_ime = ime;
    for (const auto& weak : ime->m_grabs) {
      const auto grab = weak.lock();
      if (!grab || !grab->good() || grab->getOwner() != ime || grab->client() != ime->client()) continue;
      if (grabs.size() >= 64) return false;
      grabs.emplace_back(grab);
    }
    if (grabs.empty()) return false;
  } else if (const auto held = m_imeRecipients.find(*code); held != m_imeRecipients.end()) {
    grabs = held->second;
  }
  if (!grabs.empty()) {
    // input-method-v2 has no repeated key state: the IME owns repeat timing.
    if (repeat) return true;
    for (const auto& weak : grabs) {
      const auto grab = weak.lock();
      if (!ime || !grab || !grab->good() || grab->getOwner() != ime || grab->client() != ime->client()) return false;
    }
    const auto priorMods = m_state->modifiers();
    const auto transition = m_state->transition(page, usage, state, repeat);
    if (!transition) return false;
    if (state == 1) m_imeRecipients.emplace(*code, grabs);
    for (const auto& weak : grabs) {
      const auto grab = weak.lock();
      if (!active() || Clock::now() >= deadline || !grab || !grab->good()) { end(false); return false; }
      grab->sendKeyboardData(m_sourceKeyboard.lock());
      grab->sendMods(priorMods.depressed, priorMods.latched, priorMods.locked, priorMods.group);
      grab->sendKey(timeMs, transition->evdev, static_cast<wl_keyboard_key_state>(transition->state));
      const auto& mods = transition->modifiers;
      grab->sendMods(mods.depressed, mods.latched, mods.locked, mods.group);
    }
    if (Clock::now() >= deadline || !active()) { end(false); return false; }
    if (state == 2) m_imeRecipients.erase(*code);
    return true;
  }
  const auto owned = m_owned.lock();
  std::vector<WP<CWLKeyboardResource>> recipients;
  if (state == 1 && !repeat) {
    std::size_t inspected = 0;
    for (const auto& keyboard : PROTO::seat->m_keyboards) {
      if (++inspected > 1024) return false;
      if (!keyboard || !keyboard->good() || keyboard->m_currentSurface.lock() != owned) continue;
      if (recipients.size() >= 64) return false;
      recipients.emplace_back(keyboard);
    }
  } else if (const auto held = m_recipients.find(*code); held != m_recipients.end()) {
    recipients = held->second;
  }
  if (recipients.empty()) return false;
  for (const auto& weak : recipients) {
    const auto keyboard = weak.lock();
    if (!keyboard || !keyboard->good() || keyboard->m_currentSurface.lock() != owned ||
        (repeat && keyboard->m_resource->version() < WL_KEYBOARD_KEY_STATE_REPEATED_SINCE_VERSION)) return false;
  }
  if (!active() || Clock::now() >= deadline) return false;
  const auto transition = m_state->transition(page, usage, state, repeat);
  if (!transition) return false;
  // Retain exact possibly-pressed recipients BEFORE the first send. A partial
  // dispatch/late release is not confirmed and must remain eligible for cleanup.
  if (state == 1 && !repeat) m_recipients.emplace(*code, recipients);
  g_pSeatManager->setKeyboard(m_sourceKeyboard.lock());
  for (const auto& weak : recipients) {
    const auto keyboard = weak.lock();
    if (!active() || Clock::now() >= deadline || !keyboard || !keyboard->good() ||
        keyboard->m_currentSurface.lock() != owned) {
      end(false);
      return false;
    }
    keyboard->sendKey(timeMs, transition->evdev, static_cast<wl_keyboard_key_state>(transition->state));
    const auto& mods = transition->modifiers;
    keyboard->sendMods(mods.depressed, mods.latched, mods.locked, mods.group);
  }
  if (Clock::now() >= deadline || !active()) { end(false); return false; }
  if (state == 2) m_recipients.erase(*code);
  return true;
}

bool WindowKeyboardSession::acceptsImeKeyboard(const SP<IKeyboard>& keyboard) const {
  const auto ime = scopedIme();
  return active() && keyboard && keyboard->isVirtual() && ime && m_ime.lock() == ime &&
      keyboard->getClient() == ime->client();
}

bool WindowKeyboardSession::imeModifiers(const SP<IKeyboard>& keyboard) {
  if (!acceptsImeKeyboard(keyboard)) return false;
  g_pSeatManager->setKeyboard(keyboard);
  const auto owned = m_owned.lock();
  const auto& mods = keyboard->m_modifiersState;
  for (const auto& recipient : PROTO::seat->m_keyboards) {
    if (recipient && recipient->good() && recipient->m_currentSurface.lock() == owned)
      recipient->sendMods(mods.depressed, mods.latched, mods.locked, mods.group);
  }
  return true;
}

bool WindowKeyboardSession::imeKey(const SP<IKeyboard>& keyboard, std::uint32_t code,
    std::uint32_t state, std::uint32_t timeMs) {
  if (!acceptsImeKeyboard(keyboard) || code > KEY_MAX || state > 1) return false;
  // An IME cannot release a separately owned direct-application press.
  if (m_recipients.contains(code)) return true;
  if ((state == 1) == m_imeAppRecipients.contains(code)) return true;
  const auto owned = m_owned.lock();
  if (state == 1) {
    if (m_imeAppRecipients.size() >= 256) return false;
    std::vector<WP<CWLKeyboardResource>> recipients;
    std::size_t inspected = 0;
    for (const auto& recipient : PROTO::seat->m_keyboards) {
      if (++inspected > 1024) return false;
      if (!recipient || !recipient->good() || recipient->m_currentSurface.lock() != owned) continue;
      if (recipients.size() >= 64) return false;
      recipients.emplace_back(recipient);
    }
    if (recipients.empty()) return false;
    m_imeAppRecipients.emplace(code, std::move(recipients));
  }
  // SeatManager sends this virtual device's actual keymap before application
  // keys; the physical keymap remains pinned separately for IME input.
  g_pSeatManager->setKeyboard(keyboard);
  for (const auto& weak : m_imeAppRecipients.at(code)) {
    const auto recipient = weak.lock();
    if (!acceptsImeKeyboard(keyboard) || !recipient || !recipient->good() || recipient->m_currentSurface.lock() != owned) return false;
    recipient->sendKey(timeMs, code, static_cast<wl_keyboard_key_state>(state));
  }
  if (state == 0) m_imeAppRecipients.erase(code);
  return imeModifiers(keyboard);
}

bool WindowKeyboardSession::end(bool restoreFocus) {
  if (m_ended) return m_cleanupSucceeded;
  const bool admitted = m_admission && m_admission->phase() == KeyboardAdmissionGate::Phase::Ready;
  if (admitted && !m_runtimeDiagnostic) m_runtimeDiagnostic = runtimeState();
  m_ended = true;
  cancelFocusRecheck();
  if (m_admission) m_admission->reject();
  m_focusChange.reset();
  const auto owned = m_owned.lock();
  const auto keyboard = g_pSeatManager ? g_pSeatManager->m_keyboard.lock() : nullptr;
  const auto timeMs = static_cast<std::uint32_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
      Clock::now().time_since_epoch()).count());
  for (const auto& [code, recipients] : m_imeRecipients) {
    for (const auto& weak : recipients) {
      const auto grab = weak.lock();
      if (!grab || !grab->good()) continue;
      if (!g_pSeatManager || !PROTO::seat || !(PROTO::seat->m_currentCaps & eHIDCapabilityType::HID_INPUT_CAPABILITY_KEYBOARD)) {
        m_cleanupSucceeded = false; continue;
      }
      // Exact original resources only, including after IME focus changes.
      grab->sendKey(timeMs, code, WL_KEYBOARD_KEY_STATE_RELEASED);

    }
  }
  const auto physicalKeyboard = m_sourceKeyboard.lock();
  for (const auto& [_, recipients] : m_imeRecipients) {
    for (const auto& weak : recipients) {
      const auto grab = weak.lock();
      if (m_cleanupSucceeded && grab && grab->good()) grab->sendMods(0, 0,
          physicalKeyboard ? physicalKeyboard->m_modifiersState.locked : 0,
          physicalKeyboard ? physicalKeyboard->m_modifiersState.group : 0);
    }
  }
  for (const auto& [code, recipients] : m_imeAppRecipients) {
    for (const auto& weak : recipients) {
      const auto recipient = weak.lock();
      if (recipient && recipient->good() && owned && recipient->m_currentSurface.lock() == owned) {
        if (!g_pSeatManager || !PROTO::seat || !keyboard || !(PROTO::seat->m_currentCaps & eHIDCapabilityType::HID_INPUT_CAPABILITY_KEYBOARD)) {
          m_cleanupSucceeded = false; continue;
        }
        recipient->sendKey(timeMs, code, WL_KEYBOARD_KEY_STATE_RELEASED);
      }
    }
  }
  for (const auto& [code, recipients] : m_recipients) {
    for (const auto& weak : recipients) {
      const auto recipient = weak.lock();
      // A destroyed recipient or one that already received leave cannot retain
      // these Wayland key states. Never send an up to its new focused surface.
      if (!recipient || !recipient->good() || !owned || recipient->m_currentSurface.lock() != owned) continue;
      if (!g_pSeatManager || !PROTO::seat ||
          !(PROTO::seat->m_currentCaps & eHIDCapabilityType::HID_INPUT_CAPABILITY_KEYBOARD)) {
        m_cleanupSucceeded = false;
        continue;
      }
      recipient->sendKey(timeMs, code, WL_KEYBOARD_KEY_STATE_RELEASED);
      if (!keyboard) m_cleanupSucceeded = false;
    }
  }
  // Reset modifiers only AFTER all ups. Sending a zero mask between A-up and
  // Shift-up makes clients interpret that later modifier release with an
  // incorrect prior mask. If every key was already released, lock state still
  // needs replacing
  // before restoring local ownership. Do not alter another focused surface.
  if (admitted && owned && g_pSeatManager && keyboard && PROTO::seat &&
      g_pSeatManager->m_state.keyboardFocus.lock() == owned) {
    const auto& mods = keyboard->m_modifiersState;
    for (const auto& recipient : PROTO::seat->m_keyboards) {
      if (recipient && recipient->good() && recipient->m_currentSurface.lock() == owned)
        recipient->sendMods(m_target.captureLoopbackKeyboard(physicalKeyboard.get()) ? 0U : mods.depressed,
            m_target.captureLoopbackKeyboard(physicalKeyboard.get()) ? 0U : mods.latched, mods.locked, mods.group);
    }
  }
  if (restoreFocus && m_started && m_cleanupSucceeded && !m_target.revoked() && owned &&
      g_pSeatManager && g_pSeatManager->m_state.keyboardFocus.lock() == owned &&
      Desktop::focusState()->surface() == owned && m_target.resolveKeyboard()) {
    const auto previous = m_previous.lock();
    Desktop::focusState()->rawSurfaceFocus(previous && previous->m_mapped ? previous : nullptr);
  }
  return m_cleanupSucceeded;
}

} // namespace viewflow::hyprland

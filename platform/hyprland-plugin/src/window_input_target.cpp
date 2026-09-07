// SPDX-License-Identifier: GPL-3.0-only
#include "window_input_target.hpp"
#include "window_input_motion.hpp"
#include "window_input_lifecycle.hpp"
#include "ime_popup_scope.hpp"

#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/view/Popup.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
// Exact IME ownership/popup enumeration has no public accessor in the pinned
// compositor ABI. Keep these private reads inside the native adapter.
#define private public
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/protocols/InputMethodV2.hpp>
#undef private
#include <hyprland/src/protocols/SessionLock.hpp>
#include <algorithm>
#include <cmath>

namespace viewflow::hyprland {

struct WindowInputTarget::Lifetime {
  std::function<void(WindowPointerRevocation)> onRevoked;
  WindowPointerRevocation reason = WindowPointerRevocation::None;
  CHyprSignalListener unmap;
  CHyprSignalListener surfaceUnmap;
  CHyprSignalListener surfaceDestroy;
  CHyprSignalListener commit;
  CHyprSignalListener newLock;
  CHyprSignalListener mouseMove;
  CHyprSignalListener mouseButton;
  CHyprSignalListener mouseAxis;
  CHyprSignalListener key;
  std::function<void(WP<CWLSurfaceResource>)> onImePopupRetired;
  WP<CInputMethodPopupV2> imePopup;
  WP<CWLSurfaceResource> imeRecipient;
  bool imeRetired = false;
  CHyprSignalListener imeUnmap;
  CHyprSignalListener imeDestroy;
  CHyprSignalListener imeOwnerDestroy;
  CHyprSignalListener imeFocus;
  CHyprSignalListener imeTick;
};

namespace {
ImePopupScope popupScope(const SP<CWLSurfaceResource>& main,
                        const SP<CInputMethodV2>& ime,
                        const SP<CInputMethodPopupV2>& popup) {
  const auto input = g_pInputManager ? g_pInputManager->m_relay.getFocusedTextInput() : nullptr;
  const auto currentIme = g_pInputManager ? g_pInputManager->m_relay.m_inputMethod.lock() : nullptr;
  const auto root = popup ? popup->surface() : nullptr;
  return {main.get(), input ? input->focusedSurface().get() : nullptr,
      currentIme == ime ? ime.get() : nullptr, popup ? popup->m_owner.lock().get() : nullptr,
      main ? main->client() : nullptr, input ? input->client() : nullptr,
      ime ? ime->client() : nullptr, root ? root->client() : nullptr,
      input && input->isEnabled(), ime && ime->m_active, popup && popup->m_mapped};
}
}

void WindowInputTarget::onImePopupRetired(std::function<void(WP<CWLSurfaceResource>)> callback) {
  if (m_lifetime) m_lifetime->onImePopupRetired = std::move(callback);
}

void WindowInputTarget::observeResolved(const Resolved& resolved) {
  if (!m_lifetime || !resolved.imePopup || !resolved.ime || !resolved.surface) return;
  if (m_lifetime->imePopup.lock() == resolved.imePopup && !m_lifetime->imeRetired) {
    m_lifetime->imeRecipient = resolved.surface;
    return;
  }
  auto& state = *m_lifetime;
  state.imePopup = resolved.imePopup;
  state.imeRecipient = resolved.surface;
  state.imeRetired = false;
  const std::weak_ptr<Lifetime> weak = m_lifetime;
  const auto retire = [weak]() {
    if (const auto state = weak.lock(); state && !state->imeRetired) {
      state->imeRetired = true;
      const auto callback = state->onImePopupRetired;
      if (callback) callback(state->imeRecipient);
    }
  };
  state.imeUnmap = resolved.imePopup->m_events.unmap.listen(retire);
  state.imeDestroy = resolved.imePopup->m_events.destroy.listen(retire);
  state.imeOwnerDestroy = resolved.ime->m_events.destroy.listen(retire);
  const WP<CInputMethodPopupV2> popup = resolved.imePopup;
  const WP<CInputMethodV2> ime = resolved.ime;
  const WP<CWLSurfaceResource> main = m_surface;
  const auto validate = [retire, popup, ime, main]() {
    const auto surface = main.lock();
    if (!ownsImePopup(popupScope(surface, ime.lock(), popup.lock())) ||
        !g_pSeatManager || g_pSeatManager->m_state.keyboardFocus.lock() != surface)
      retire();
  };
  state.imeFocus = g_pSeatManager->m_events.keyboardFocusChange.listen(validate);
  state.imeTick = Event::bus()->m_events.tick.listen(validate);
}

void WindowInputTarget::onRevoked(std::function<void(WindowPointerRevocation)> callback) {
  if (m_lifetime) m_lifetime->onRevoked = std::move(callback);
}

void WindowInputTarget::revoke(WindowPointerRevocation reason) {
  if (m_lifetime)
    m_lifetime->reason = observedRevocation(m_lifetime->reason, retirementReason(reason));
}

bool WindowInputTarget::revoked() const {
  return revocationReason() != WindowPointerRevocation::None;
}

WindowPointerRevocation WindowInputTarget::revocationReason() const {
  return m_lifetime ? m_lifetime->reason : WindowPointerRevocation::TargetInvalid;
}

bool WindowInputTarget::matches(std::uint64_t windowAddress, std::uint64_t surfaceAddress,
                                std::uint32_t pid, const Vector2D& extent) const {
  const auto window = m_window.lock();
  const auto surface = m_surface.lock();
  return !revoked() && window && surface &&
      reinterpret_cast<std::uintptr_t>(window.get()) == windowAddress &&
      reinterpret_cast<std::uintptr_t>(surface.get()) == surfaceAddress &&
      m_pid > 0 && static_cast<std::uint32_t>(m_pid) == pid && m_size == extent &&
      Desktop::View::validMapped(window) && !window->isHidden() &&
      window->getPID() == m_pid && window->wlSurface() &&
      window->wlSurface()->resource() == surface && surface->m_current.size == m_size;
}

WindowPointerRevocation WindowInputTarget::resizeGuardReason() const {
  if (revocationReason() != WindowPointerRevocation::Resized)
    return revocationReason();
  const auto window = m_window.lock();
  const auto surface = m_surface.lock();
  if (!Desktop::View::validMapped(window) || window->isHidden() || window->m_isX11 ||
      window->getPID() != m_pid || !surface || !window->wlSurface() ||
      window->wlSurface()->resource() != surface)
    m_lifetime->reason = WindowPointerRevocation::TargetInvalid;
  else if (!PROTO::sessionLock || PROTO::sessionLock->isLocked())
    m_lifetime->reason = WindowPointerRevocation::SessionLocked;
  else if (!g_pSeatManager || !g_pInputManager || (g_pInputManager->hasHeldButtons() &&
       !(m_captureLoopback && m_captureLoopback->active)) ||
      g_pSeatManager->m_seatGrab ||
      std::ranges::any_of(g_pInputManager->m_exclusiveLSes,
          [](const auto& layer) { return bool(layer.lock()); }))
    m_lifetime->reason = WindowPointerRevocation::SeatUnavailable;
  return m_lifetime->reason;
}

std::optional<WindowInputTarget> WindowInputTarget::rebindAfterResize(
    std::uint64_t windowAddress, std::uint64_t surfaceAddress,
    std::uint32_t pid, const Vector2D& extent) const {
  if (resizeGuardReason() != WindowPointerRevocation::Resized)
    return std::nullopt;
  const auto window = m_window.lock();
  const auto surface = m_surface.lock();
  if (!window || !surface || reinterpret_cast<std::uintptr_t>(window.get()) != windowAddress ||
      reinterpret_cast<std::uintptr_t>(surface.get()) != surfaceAddress ||
      static_cast<std::uint32_t>(m_pid) != pid || !std::isfinite(extent.x) ||
      !std::isfinite(extent.y) || extent.x <= 0 || extent.y <= 0 || surface->m_current.size != extent)
    return std::nullopt;
  // Retain the old listeners until the replacement has installed its listeners.
  return bind(window, m_captureLoopback);
}

std::optional<WindowInputTarget>
WindowInputTarget::bind(const PHLWINDOW &window, std::shared_ptr<CaptureLoopbackState> captureLoopback) {
  // XWayland activation/scaling and related popup ownership require a separate
  // implementation; never silently resolve another focused X11 window here.
  if (!PROTO::sessionLock || PROTO::sessionLock->isLocked() ||
      !g_pInputManager || (g_pInputManager->hasHeldButtons() &&
       !(captureLoopback && captureLoopback->active)) ||
      !Desktop::View::validMapped(window) || window->isHidden() ||
      window->m_isX11 || !window->wlSurface())
    return std::nullopt;
  const auto surface = window->wlSurface()->resource();
  if (!surface || window->getPID() <= 0 ||
      surface->m_current.size.x <= 0 || surface->m_current.size.y <= 0)
    return std::nullopt;
  WindowInputTarget target;
  target.m_captureLoopback = captureLoopback;
  target.m_window = window;
  target.m_surface = surface;
  target.m_size = surface->m_current.size;
  target.m_pid = window->getPID();
  // Callbacks never capture the movable target or retain the source window.
  // The target is move-only so one session owns the immediate cleanup callback.
  // Listener callbacks hold only a weak lifetime token, not an ownership cycle.
  target.m_lifetime = std::make_shared<Lifetime>();
  const std::weak_ptr<Lifetime> weak = target.m_lifetime;
  const auto invalidate = [weak](WindowPointerRevocation reason) {
    if (const auto state = weak.lock()) {
      const auto next = observedRevocation(state->reason, reason);
      if (next == state->reason) return;
      state->reason = next;
      // Release this session's native buttons before the local input callback
      // continues into Hyprland. Copy the callback because end() unregisters it.
      const auto callback = state->onRevoked;
      if (callback) callback(next);
    }
  };
  target.m_lifetime->unmap = window->m_events.unmap.listen([invalidate] { invalidate(WindowPointerRevocation::WindowUnmapped); });
  target.m_lifetime->surfaceUnmap = surface->m_events.unmap.listen([invalidate] { invalidate(WindowPointerRevocation::SurfaceUnmapped); });
  target.m_lifetime->surfaceDestroy = surface->m_events.destroy.listen([invalidate] { invalidate(WindowPointerRevocation::SurfaceDestroyed); });
  const WP<CWLSurfaceResource> weakSurface = surface;
  const Vector2D expectedSize = target.m_size;
  target.m_lifetime->commit = surface->m_events.commit.listen(
      [weakSurface, expectedSize, invalidate]() {
        const auto current = weakSurface.lock();
        if (!current)
          invalidate(WindowPointerRevocation::SurfaceDestroyed);
        else if (current->m_current.size != expectedSize)
          invalidate(WindowPointerRevocation::Resized);
      });
  target.m_lifetime->newLock = PROTO::sessionLock->m_events.newLock.listen(
      [invalidate](SP<CSessionLock>) { invalidate(WindowPointerRevocation::SessionLocked); });
  auto &input = Event::bus()->m_events.input;
  const auto initialPointer = g_pInputManager->getMouseCoordsInternal().floor();
  target.m_lifetime->mouseMove = input.mouse.move.listen(
      [invalidate, initialPointer, captureLoopback](Vector2D position, Event::SCallbackInfo &info) {
        if (captureLoopback && captureLoopback->active && info.cancelled) return;
        if (localPointerPositionChanged(initialPointer.x, initialPointer.y, position.x, position.y))
          invalidate(WindowPointerRevocation::LocalMotion);
      });
  target.m_lifetime->mouseButton = input.mouse.button.listen(
      [invalidate, captureLoopback](IPointer::SButtonEvent, Event::SCallbackInfo &info) {
        if (captureLoopback && captureLoopback->active && info.cancelled) return;
        invalidate(WindowPointerRevocation::LocalButton);
      });
  target.m_lifetime->mouseAxis = input.mouse.axis.listen(
      [invalidate, captureLoopback](IPointer::SAxisEvent, Event::SCallbackInfo &info) {
        if (captureLoopback && captureLoopback->active && info.cancelled) return;
        invalidate(WindowPointerRevocation::LocalAxis);
      });
  target.m_lifetime->key = input.keyboard.key.listen(
      [invalidate, captureLoopback](IKeyboard::SKeyEvent, Event::SCallbackInfo &info) {
        if (captureLoopback && captureLoopback->active && info.cancelled) return;
        invalidate(WindowPointerRevocation::LocalKey);
      });
  return target;
}

std::optional<WindowInputTarget::Resolved>
WindowInputTarget::resolve(const Vector2D &point) const {
  const auto target = resolveKeyboard();
  if (!target) return std::nullopt;
  const auto main = target->surface;
  if (!std::isfinite(point.x) || !std::isfinite(point.y) || point.x < 0 ||
      point.y < 0 || point.x >= m_size.x || point.y >= m_size.y)
    return std::nullopt;
  // Input-method popups are a distinct client's tree. Never admit them by
  // client/PID similarity: require this exact TextInput and active relay IME.
  // The main-surface extent above remains authoritative, including for IME.
  auto& relay = g_pInputManager->m_relay;
  const auto ime = relay.m_inputMethod.lock();
  const auto mainBox = target->window->getWindowMainSurfaceBox();
  for (auto it = relay.m_inputMethodPopups.rbegin(); it != relay.m_inputMethodPopups.rend(); ++it) {
    const auto& popup = *it;
    const auto protocol = popup ? popup->m_popup.lock() : nullptr;
    if (!ownsImePopup(popupScope(main, ime, protocol))) continue;
    const auto root = popup->getSurface();
    if (!root || !root->m_mapped) continue;
    const auto offset = popup->globalBox().pos() - mainBox.pos();
    if (!std::isfinite(offset.x) || !std::isfinite(offset.y)) return std::nullopt;
    const auto [surface, local] = root->at(point - offset, true);
    if (!surface) continue;
    if (surface->client() != ime->client() || !surface->m_mapped ||
        !std::isfinite(local.x) || !std::isfinite(local.y)) return std::nullopt;
    return Resolved{target->window, surface, local, protocol, ime};
  }
  // wl_surface::at only walks subsurfaces. XDG popups are separate trees:
  // visit this exact window's popups in reverse compositor stacking order,
  // then perform input-region-aware hit testing within each popup tree.
  // The negotiated extent remains the main surface; out-of-extent family
  // input must wait for an explicitly negotiated geometry change.
  if (const auto head = target->window->m_popupHead) {
    std::vector<SP<Desktop::View::CPopup>> popups;
    head->breadthfirst([&popups](SP<Desktop::View::CPopup> popup, void*) {
      popups.push_back(popup);
    }, nullptr);
    for (auto it = popups.rbegin(); it != popups.rend(); ++it) {
      const auto& popup = *it;
      if (!popup || !popup->m_mapped || popup->inert() ||
          popup->getT1Owner() != target->window->wlSurface())
        continue;
      const auto wrapper = popup->wlSurface();
      const auto resource = wrapper ? wrapper->resource() : nullptr;
      if (!resource || resource->client() != main->client())
        continue;
      const auto offset = popup->coordsRelativeToParent();
      if (!std::isfinite(offset.x) || !std::isfinite(offset.y))
        return std::nullopt;
      const auto [surface, local] = resource->at(point - offset, true);
      if (!surface) continue;
      if (surface->client() != main->client() ||
          !std::isfinite(local.x) || !std::isfinite(local.y))
        return std::nullopt;
      return Resolved{target->window, surface, local};
    }
  }
  const auto [surface, local] = main->at(point, true);
  // No fallback to the main surface when hit testing rejects an input region.
  if (!surface || !std::isfinite(local.x) || !std::isfinite(local.y))
    return std::nullopt;
  return Resolved{target->window, surface, local};
}

std::optional<WindowInputTarget::Resolved>
WindowInputTarget::resolveKeyboard() const {
  // Lock the exact objects, not an address/name lookup that could select a
  // replacement after closure. The unmap listener also invalidates a target
  // when the same source objects are subsequently mapped again.
  if (revoked())
    return std::nullopt;
  const auto window = m_window.lock();
  const auto main = m_surface.lock();
  if (!Desktop::View::validMapped(window) || window->isHidden() ||
      window->m_isX11 || window->getPID() != m_pid || !main ||
      !window->wlSurface() || window->wlSurface()->resource() != main ||
      main->m_current.size != m_size) {
    m_lifetime->reason = WindowPointerRevocation::TargetInvalid;
    return std::nullopt;
  }
  if (!g_pSeatManager || !g_pInputManager || !PROTO::sessionLock ||
      (g_pInputManager->hasHeldButtons() &&
       !(m_captureLoopback && m_captureLoopback->active)) ||
      PROTO::sessionLock->isLocked() || g_pSeatManager->m_seatGrab ||
      std::ranges::any_of(g_pInputManager->m_exclusiveLSes,
                         [](const auto &layer) { return bool(layer.lock()); })) {
    m_lifetime->reason = WindowPointerRevocation::SeatUnavailable;
    return std::nullopt;
  }
  return Resolved{window, main, {}};
}

} // namespace viewflow::hyprland

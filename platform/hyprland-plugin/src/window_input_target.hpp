// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "window_pointer_authority.hpp"

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <optional>
#include <memory>
#include <functional>

class CInputMethodPopupV2;
class CInputMethodV2;

namespace viewflow::hyprland {

// Compositor-thread-only lifetime binding. This performs no authorization or
// input injection. A native session must also own a window-specific grant.
struct CaptureLoopbackState {
  bool active = false;
  const void *keyboard = nullptr;
};

class WindowInputTarget {
public:
  WindowInputTarget(WindowInputTarget&&) = default;
  WindowInputTarget& operator=(WindowInputTarget&&) = default;
  WindowInputTarget(const WindowInputTarget&) = delete;
  WindowInputTarget& operator=(const WindowInputTarget&) = delete;
  struct Resolved {
    PHLWINDOW window;
    SP<CWLSurfaceResource> surface;
    Vector2D local;
    SP<CInputMethodPopupV2> imePopup = {};
    SP<CInputMethodV2> ime = {};
  };

  static std::optional<WindowInputTarget> bind(const PHLWINDOW &window, std::shared_ptr<CaptureLoopbackState> captureLoopback = {});
  std::optional<Resolved> resolve(const Vector2D &surfacePoint) const;
  // Keyboard focus is the exact bound main surface, not a fabricated pointer
  // hit-test. A separate keyboard-capable native session must own admission.
  std::optional<Resolved> resolveKeyboard() const;
  void observeResolved(const Resolved& resolved);
  void onImePopupRetired(std::function<void(WP<CWLSurfaceResource>)> callback);
  void revoke(WindowPointerRevocation reason = WindowPointerRevocation::Cancelled);
  bool revoked() const;
  bool captureLoopbackKeyboard(const void *keyboard) const {
    return m_captureLoopback && m_captureLoopback->active && keyboard &&
        m_captureLoopback->keyboard == keyboard;
  }
  WindowPointerRevocation revocationReason() const;
  void onRevoked(std::function<void(WindowPointerRevocation)> callback);
  // Read-only safety check for a retired target; grants no input capability.
  WindowPointerRevocation resizeGuardReason() const;
  std::optional<WindowInputTarget> rebindAfterResize(std::uint64_t windowAddress,
      std::uint64_t surfaceAddress, std::uint32_t pid, const Vector2D& extent) const;
  bool matches(std::uint64_t windowAddress, std::uint64_t surfaceAddress,
               std::uint32_t pid, const Vector2D& extent) const;

private:
  WindowInputTarget() = default;
  struct Lifetime;
  std::shared_ptr<Lifetime> m_lifetime;
  PHLWINDOWREF m_window;
  WP<CWLSurfaceResource> m_surface;
  Vector2D m_size;
  pid_t m_pid = 0;
  std::shared_ptr<CaptureLoopbackState> m_captureLoopback;
};

} // namespace viewflow::hyprland

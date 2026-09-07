// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "window_input_target.hpp"
#include "window_keyboard_session.hpp"
#include "pointer_focus_trace.hpp"
#include <chrono>
#include <array>
#include <vector>

class CEventLoopTimer;
class CWLPointerResource;

namespace viewflow::hyprland {

// Compositor-thread-only native half of a source-authorized window grant.
// No network parser may construct this directly from untrusted peer fields.
// Owns exact native recipients. Keyboard is a separate explicit capability.
class WindowPointerSession {
public:
  bool acceptsImeKeyboard(const SP<IKeyboard>& keyboard) const;
  bool imeKey(const SP<IKeyboard>& keyboard, std::uint32_t key, std::uint32_t state, std::uint32_t timeMs);
  bool imeModifiers(const SP<IKeyboard>& keyboard);
  using Clock = std::chrono::steady_clock;
  WindowPointerSession(WindowInputTarget target, Clock::time_point expires, bool allowButtons = false, bool allowWheel = false, bool allowKeyboard = false, bool allowAdmissionWait = false);
  ~WindowPointerSession();
  WindowPointerSession(const WindowPointerSession &) = delete;
  WindowPointerSession &operator=(const WindowPointerSession &) = delete;
  WindowPointerSession(WindowPointerSession &&) = delete;
  WindowPointerSession &operator=(WindowPointerSession &&) = delete;

  bool move(const Vector2D &surfacePoint, Clock::time_point eventDeadline,
            std::uint32_t waylandTimeMs);
  bool button(const Vector2D& surfacePoint, std::uint32_t button, std::uint32_t state,
              Clock::time_point eventDeadline, std::uint32_t waylandTimeMs);
  bool wheel(const Vector2D& surfacePoint, std::int32_t vertical120, std::int32_t horizontal120,
             Clock::time_point eventDeadline, std::uint32_t waylandTimeMs);
  bool key(std::uint16_t page, std::uint16_t usage, std::uint32_t state, bool repeat,
           Clock::time_point eventDeadline, std::uint32_t waylandTimeMs);
  bool cleanupSucceeded() const { return !m_keyboard || m_keyboard->cleanupSucceeded(); }
  void end(WindowPointerRevocation reason = WindowPointerRevocation::Cancelled, bool preserveFocus = false);
  void cancel() { m_target.revoke(); end(); }
  // Check revocation synchronously, not only after the next compositor tick.
  // A BEGIN queued after local input must not race that tick and renew focus.
  bool active() const;
  bool admissionPending() const { return !m_ended && m_keyboard && m_keyboard->admissionPending(); }
  void pollAdmission();
  std::uint32_t keyboardStartupFailure() const { return m_keyboard ? m_keyboard->startupFailure() : 0; }
  WindowPointerRevocation inactiveReason() const;
  std::uint32_t focusDiagnostic() const { return m_focusDiagnostic; }
  const PointerFocusTrace& focusTrace() const { return m_focusTrace; }
  bool suppressConvenienceMotion() const;
  std::uint32_t keyboardRuntimeDiagnostic() const { return m_keyboard ? m_keyboard->runtimeDiagnostic() : 0; }
  WindowPointerRevocation resizeGuardReason() const;
  std::unique_ptr<WindowPointerSession> rebindAfterResize(std::uint64_t windowAddress,
      std::uint64_t surfaceAddress, std::uint32_t pid, const Vector2D& extent,
      Clock::time_point expires) const;
  bool renew(std::uint64_t windowAddress, std::uint64_t surfaceAddress,
             std::uint32_t pid, const Vector2D& extent, Clock::time_point expires,
             bool allowButtons, bool allowWheel = false, bool allowKeyboard = false);

private:
  bool ownsButtons() const;
  bool mayRetainKeyboardWithoutPointer() const;
  void recordFocusDiagnostic(std::uint32_t phase) const;
  void releaseButtons(std::uint32_t timeMs);
  WindowInputTarget m_target;
  Clock::time_point m_expires;
  WP<CWLSurfaceResource> m_previous;
  WP<CWLSurfaceResource> m_owned;
  Vector2D m_previousLocal;
  Vector2D m_lastPoint;
  bool m_started = false;
  bool m_ended = false;
  mutable bool m_focusDiagnosticRecorded = false;
  mutable std::uint32_t m_focusDiagnostic = 0;
  PointerFocusTrace m_focusTrace;
  WP<CWLSurfaceResource> m_initialDesktopFocus, m_initialKeyboardFocus;
  Vector2D m_initialGlobalPointer;
  bool m_initialDesktopPresent = false, m_initialKeyboardPresent = false;
  bool m_externalFocusChanged = false;
  const bool m_allowButtons;
  const bool m_allowWheel;
  const bool m_allowKeyboard;
  std::unique_ptr<WindowKeyboardSession> m_keyboard;
  std::array<std::vector<WP<CWLPointerResource>>, 5> m_buttons;
  WindowPointerRevocation m_endReason = WindowPointerRevocation::None;
  SP<CEventLoopTimer> m_expiryTimer;
  CHyprSignalListener m_tick;
  CHyprSignalListener m_stationaryRecheck;
  CHyprSignalListener m_pointerFocusChange;
  CHyprSignalListener m_seatFocusIdentityChange, m_desktopFocusIdentityChange;
};

} // namespace viewflow::hyprland

// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "window_input_target.hpp"
#include "window_keyboard_state.hpp"
#include "window_keyboard_route.hpp"
#include "window_keyboard_admission.hpp"
#include <chrono>
#include <vector>

class CWLKeyboardResource;
class IKeyboard;
class CInputMethodV2;
class CInputMethodKeyboardGrabV2;
struct SEventLoopDoLaterLock;

namespace viewflow::hyprland {

// Exact application or source IME route with original-recipient key cleanup.
// No global InputManager key event or text-injection fallback is permitted.
class WindowKeyboardSession {
public:
  using Clock = std::chrono::steady_clock;
  WindowKeyboardSession(WindowInputTarget& target, Clock::time_point expires, bool allowAdmissionWait = false);
  ~WindowKeyboardSession();
  bool active() const;
  bool admissionPending() const { return !m_ended && m_admission && m_admission->phase() == KeyboardAdmissionGate::Phase::Waiting; }
  void pollAdmission();
  Clock::time_point admissionDeadline() const { return m_admission ? m_admission->deadline() : m_expires; }
  std::uint32_t startupFailure() const { return m_startupFailure; }
  std::uint32_t runtimeDiagnostic() const { return m_runtimeDiagnostic; }
  bool renew(Clock::time_point expires);
  bool key(std::uint16_t page, std::uint16_t usage, std::uint32_t state, bool repeat,
           Clock::time_point deadline, std::uint32_t timeMs);
  bool end(bool restoreFocus);
  bool cleanupSucceeded() const { return m_cleanupSucceeded; }
  bool acceptsImeKeyboard(const SP<IKeyboard>& keyboard) const;
  bool imeKey(const SP<IKeyboard>& keyboard, std::uint32_t key, std::uint32_t state, std::uint32_t timeMs);
  bool imeModifiers(const SP<IKeyboard>& keyboard);

private:
  std::uint32_t targetFocusFailure() const;
  std::uint32_t exactBindingFailure() const;
  bool exactBindingValid() const;
  bool compatibleSeatIme(const SP<IKeyboard>& keyboard) const;
  std::uint32_t runtimeState() const;
  void cancelFocusRecheck();
  SP<CInputMethodV2> scopedIme() const;
  SP<IKeyboard> sourceKeyboardCandidate() const;
  KeyboardRouteFailure routeFailure() const;
  bool routeAvailable() const;
  WindowInputTarget& m_target;
  const bool m_allowAdmissionWait;
  Clock::time_point m_expires;
  WP<CWLSurfaceResource> m_owned, m_previous;
  WP<IKeyboard> m_sourceKeyboard;
  WP<CInputMethodV2> m_ime;
  std::map<std::uint32_t, std::vector<WP<CInputMethodKeyboardGrabV2>>> m_imeRecipients;
  std::map<std::uint32_t, std::vector<WP<CWLKeyboardResource>>> m_imeAppRecipients;
  std::unique_ptr<WindowKeyboardState> m_state;
  std::map<std::uint32_t, std::vector<WP<CWLKeyboardResource>>> m_recipients;
  CHyprSignalListener m_focusChange;
  UP<SEventLoopDoLaterLock> m_focusRecheck;
  std::shared_ptr<int> m_focusRecheckLife;
  std::optional<KeyboardAdmissionGate> m_admission;
  std::uint32_t m_startupFailure = 0;
  mutable std::uint32_t m_runtimeDiagnostic = 0;
  bool m_started = false, m_ended = false, m_cleanupSucceeded = true;
};

} // namespace viewflow::hyprland

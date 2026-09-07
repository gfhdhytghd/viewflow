// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <chrono>
#include <cstdint>
namespace viewflow::hyprland {
// Only an isolated seat-keyboard mismatch from the retiring foreign virtual
// keyboard is transient. Focus, permission, keymap and source loss stay fatal.
constexpr bool keyboardAdmissionWaitsForForeignVirtual(std::uint32_t bindingFailure,
    bool allowWait, bool currentVirtual, bool trustedTargetIme) {
  return allowWait && currentVirtual && !trustedTargetIme && bindingFailure == (1U << 14U);
}
// Focus may ask the old text-input client to relinquish its IME grab. This
// gate never owns input and cannot become ready by timeout or deadline renewal.
class KeyboardAdmissionGate {
public:
  using Clock = std::chrono::steady_clock;
  enum class Phase { Waiting, Ready, Rejected };
  KeyboardAdmissionGate(Clock::time_point now, Clock::time_point leaseDeadline)
      : m_deadline(std::min(leaseDeadline, now + std::chrono::milliseconds(20))) {}
  Phase observe(Clock::time_point now, bool exactBindingValid, bool inputMethodGrab, bool stableKeyboardReady = true) {
    if (m_phase != Phase::Waiting) return m_phase;
    if (!exactBindingValid || now >= m_deadline) m_phase = Phase::Rejected;
    else if (!inputMethodGrab && stableKeyboardReady) m_phase = Phase::Ready;
    return m_phase;
  }
  void reject() { m_phase = Phase::Rejected; }
  Phase phase() const { return m_phase; }
  Clock::time_point deadline() const { return m_deadline; }
private:
  Clock::time_point m_deadline;
  Phase m_phase = Phase::Waiting;
};
}

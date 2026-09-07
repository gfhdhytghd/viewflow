// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>

namespace viewflow::hyprland {

// Local IPC reason codes. Never include pressed key/button values or text.
enum class WindowPointerRevocation : std::uint32_t {
  None = 0, Cancelled = 1, WindowUnmapped = 2, SurfaceUnmapped = 3,
  SurfaceDestroyed = 4, Resized = 5, SessionLocked = 6, LocalMotion = 7,
  LocalButton = 8, LocalAxis = 9, LocalKey = 10, TargetInvalid = 11,
  SeatUnavailable = 12, Expired = 13, FocusChanged = 14, RouteUnavailable = 15,
};

// Connection-local generation ordering. A revoked route can be replaced after
// explicit END confirms native cleanup; ordinary BEGIN renewal cannot reopen it.
class WindowPointerAuthority {
public:
  void reset() { m_generation = 0; m_revoked = false; m_resizeSuspended = false; m_targetRetired = false; }
  void revoke() { m_revoked = true; m_resizeSuspended = false; m_targetRetired = false; }
  // Explicit paired physical-capture activation is a new authority boundary.
  // Preserve the generation floor: neither old BEGIN nor automatic renewal can
  // clear a takeover by themselves.
  void rearmForCapture() { m_revoked = false; m_resizeSuspended = false; }
  void retireTarget() { revoke(); m_targetRetired = true; }
  // Called only after the exact generation has been ended and native cleanup
  // succeeded. Keep the generation floor so an old BEGIN cannot be replayed.
  bool end(std::uint64_t generation, bool cleanupSucceeded) {
    if (!generation || generation != m_generation || !cleanupSucceeded) return false;
    m_targetRetired = false;
    m_revoked = false;
    m_resizeSuspended = false;
    return true;
  }
  bool suspendForResize() {
    if (m_revoked || !m_generation) return false;
    m_resizeSuspended = true;
    return true;
  }
  bool resizeSuspended() const { return m_resizeSuspended && !m_revoked; }
  bool rebind(std::uint64_t generation, bool routeAvailable) {
    if (!generation || generation <= m_generation) return false;
    m_generation = generation;
    if (!resizeSuspended() || !routeAvailable) return false;
    m_resizeSuspended = false;
    return true;
  }
  std::uint64_t generation() const { return m_generation; }
  bool begin(std::uint64_t generation, bool routeAvailable) {
    if (generation == 0 || generation <= m_generation)
      return false;
    m_generation = generation; // A denied generation cannot be replayed later.
    return !m_revoked && !m_resizeSuspended && routeAvailable;
  }
private:
  std::uint64_t m_generation = 0;
  bool m_revoked = false;
  bool m_targetRetired = false;
  bool m_resizeSuspended = false;
};

} // namespace viewflow::hyprland

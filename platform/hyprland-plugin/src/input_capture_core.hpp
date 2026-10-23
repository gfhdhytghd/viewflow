// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "viewflow_hyprland/protocol.hpp"

#include <array>
#include <algorithm>
#include <cstdint>
#include <memory>
#include <optional>
#include <set>
#include <span>
#include <vector>

namespace viewflow::hyprland {

struct InputRect {
  std::int64_t monitorId = -1;
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
};

struct EdgeCandidate {
  protocol::Edge edge = protocol::Edge::LEFT;
  std::int64_t monitorId = -1;
  double edgePosition = 0;
  double anchorX = 0;
  double anchorY = 0;
  std::optional<std::array<double, 2>> entryPosition = std::nullopt;
};

struct InputLeaseIdentity {
  std::uint64_t generation = 0;
  std::array<std::uint8_t, 16> targetDevice{};
};

enum class CapturePhase : std::uint8_t {
  LOCAL,
  EDGE_ARMED,
  CAPTURE_PENDING,
  REMOTE_CAPTURED,
};

constexpr bool windowPointerRouteAllowed(CapturePhase phase) {
  return phase == CapturePhase::LOCAL || phase == CapturePhase::EDGE_ARMED;
}

struct ReleaseState {
  std::optional<InputLeaseIdentity> lease;
  std::set<std::uint32_t> buttons;
  std::set<std::uint32_t> keys;
};

class EnabledStateLease {
public:
  EnabledStateLease() = default;
  EnabledStateLease(const EnabledStateLease&) = delete;
  EnabledStateLease& operator=(const EnabledStateLease&) = delete;
  bool permitted(bool enabled) const { return m_original ? *m_original : enabled; }
  void suppress(bool &enabled);
  void restore(bool &enabled);
  [[nodiscard]] bool active() const noexcept;

private:
  // All routes suppressing the same keyboard share its original state.
  // Weak registry entries never retain a destroyed device or dereference it.
  std::shared_ptr<const bool> m_original;
};

// Compositor-thread arbitration: reserving an edge and capturing its input are
// one ownership interval. Disconnecting an idle route cannot release its peer.
class CaptureSeat {
public:
  bool available(const void* route) const { return !m_owner || m_owner == route; }
  bool claim(const void* route) {
    if (!route || !available(route)) return false;
    m_owner = route; return true;
  }
  void release(const void* route) { if (m_owner == route) m_owner = nullptr; }
  // A returned remote gesture can enter only the adjacent destination that
  // contains its return coordinate. Local presses never create this record.
  void returnHeldLeft(const void* route, InputRect origin, double x, double y) {
    m_returned = Returned{route, origin, x, y};
  }
  void clearHeldLeft() { m_returned.reset(); }
  void forget(const void* route) { if (m_returned && m_returned->route == route) clearHeldLeft(); }
  bool inheritsHeldLeft(const void* route, const std::optional<InputRect>& remote) const {
    if (!m_returned || !remote || route == m_returned->route) return false;
    const auto& a=m_returned->origin; const auto& b=*remote;
    const bool adjacent=((a.x+a.width==b.x || b.x+b.width==a.x) &&
        std::max(a.y,b.y)<std::min(a.y+a.height,b.y+b.height)) ||
        ((a.y+a.height==b.y || b.y+b.height==a.y) &&
        std::max(a.x,b.x)<std::min(a.x+a.width,b.x+b.width));
    return adjacent && m_returned->x>=b.x && m_returned->x<b.x+b.width &&
        m_returned->y>=b.y && m_returned->y<b.y+b.height;
  }
private:
  const void* m_owner = nullptr;
  struct Returned { const void* route; InputRect origin; double x, y; };
  std::optional<Returned> m_returned;
};

class InputCaptureCore {
public:
  explicit InputCaptureCore(double edgeBandDip = 2.0,
                            double outwardThresholdDip = 1.0);

  // The exact output created by this paired session; other outputs stay local.
  void resetConnection();
  [[nodiscard]] bool configureRemote(std::optional<InputRect> remote);
  void observePosition(double x, double y, std::span<const InputRect> monitors);
  [[nodiscard]] bool emergencyEscape() const noexcept;
  [[nodiscard]] const std::optional<InputRect> &remote() const { return m_remote; }
  [[nodiscard]] std::optional<EdgeCandidate>
  observeMotion(double unacceleratedX, double unacceleratedY);

  [[nodiscard]] bool activate(InputLeaseIdentity lease);
  [[nodiscard]] ReleaseState release();
  [[nodiscard]] bool button(std::uint32_t code, bool pressed);
  [[nodiscard]] bool key(std::uint32_t code, bool pressed);

  void allowHeldLeftReturn(bool allowed) { m_heldLeftReturn = allowed; }
  [[nodiscard]] bool continuingHeldLeft() const {
    return m_heldLeftReturn && m_physicalButtons.size()==1 && m_physicalButtons.contains(272) && m_physicalKeys.empty();
  }
  [[nodiscard]] bool physicalButtonHeld(std::uint32_t code) const { return m_physicalButtons.contains(code); }
  void armDragReturn(std::uint64_t generation) { m_pendingReturnGeneration = !m_lease && physicalButtonHeld(272) ? generation : 0; }
  [[nodiscard]] bool canContinueDrag(std::uint64_t generation) const {
    return generation != 0 && generation == m_pendingReturnGeneration && !m_lease && physicalButtonHeld(272);
  }
  void finishDragReturn() { m_pendingReturnGeneration = 0; }
  [[nodiscard]] CapturePhase phase() const noexcept;
  [[nodiscard]] bool captured() const noexcept;
  [[nodiscard]] const std::optional<EdgeCandidate> &activeEdge() const noexcept;
  [[nodiscard]] const std::optional<InputLeaseIdentity> &lease() const noexcept;

private:
  [[nodiscard]] static double outward(protocol::Edge edge, double dx,
                                      double dy) noexcept;

  double m_edgeBandDip;
  double m_outwardThresholdDip;
  CapturePhase m_phase = CapturePhase::LOCAL;
  std::vector<EdgeCandidate> m_armedEdges;
  std::optional<EdgeCandidate> m_activeEdge;
  std::optional<InputLeaseIdentity> m_lease;
  std::uint64_t m_lastGeneration = 0;
  std::optional<InputRect> m_remote;
  bool m_insideRemoteArm = false;
  bool m_heldLeftReturn = false;
  std::uint64_t m_pendingReturnGeneration = 0;
  std::set<std::uint32_t> m_physicalButtons;
  std::set<std::uint32_t> m_physicalKeys;
  std::set<std::uint32_t> m_buttons;
  std::set<std::uint32_t> m_keys;
};

} // namespace viewflow::hyprland

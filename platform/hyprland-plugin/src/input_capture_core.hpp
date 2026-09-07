// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "viewflow_hyprland/protocol.hpp"

#include <array>
#include <cstdint>
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
  bool permitted(bool enabled) const { return m_original.value_or(enabled); }
  void suppress(bool &enabled);
  void restore(bool &enabled);
  [[nodiscard]] bool active() const noexcept;

private:
  std::optional<bool> m_original;
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
  std::set<std::uint32_t> m_physicalButtons;
  std::set<std::uint32_t> m_physicalKeys;
  std::set<std::uint32_t> m_buttons;
  std::set<std::uint32_t> m_keys;
};

} // namespace viewflow::hyprland

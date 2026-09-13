// SPDX-License-Identifier: GPL-3.0-only
#include "input_capture_core.hpp"

#include <algorithm>
#include <cmath>

namespace viewflow::hyprland {
namespace {

bool contains(const InputRect &rect, double x, double y) {
  return x >= rect.x && x < rect.x + rect.width && y >= rect.y &&
         y < rect.y + rect.height;
}

double normalized(double value, double origin, double length) {
  if (!std::isfinite(value) || !std::isfinite(origin) ||
      !std::isfinite(length) || length <= 0)
    return 0;
  return std::clamp((value - origin) / length, 0.0, 1.0);
}

} // namespace

void EnabledStateLease::suppress(bool &enabled) {
  if (!m_original)
    m_original = enabled;
  enabled = false;
}

void EnabledStateLease::restore(bool &enabled) {
  if (!m_original)
    return;
  enabled = *m_original;
  m_original.reset();
}

bool EnabledStateLease::active() const noexcept {
  return m_original.has_value();
}

InputCaptureCore::InputCaptureCore(double edgeBandDip,
                                   double outwardThresholdDip)
    : m_edgeBandDip(std::max(0.25, edgeBandDip)),
      m_outwardThresholdDip(std::max(0.0, outwardThresholdDip)) {}

void InputCaptureCore::resetConnection() {
  m_pendingReturnGeneration = 0;
  (void)release();
  m_lastGeneration = 0;
  m_remote.reset();
  m_insideRemoteArm = false;
}

bool InputCaptureCore::configureRemote(std::optional<InputRect> remote) {
  if (captured() || m_phase == CapturePhase::CAPTURE_PENDING)
    return false;
  if (remote && (remote->monitorId < 0 || !std::isfinite(remote->x) ||
      !std::isfinite(remote->y) || !std::isfinite(remote->width) ||
      !std::isfinite(remote->height) || remote->width <= 0 || remote->height <= 0 ||
      !std::isfinite(remote->x + remote->width) ||
      !std::isfinite(remote->y + remote->height)))
    return false;
  m_remote = remote;
  m_armedEdges.clear();
  m_activeEdge.reset();
  m_phase = CapturePhase::LOCAL;
  return true;
}

bool InputCaptureCore::emergencyEscape() const noexcept {
  // Physical Ctrl+Alt+Escape is always compositor-local.
  return captured() && m_physicalKeys.contains(1) &&
      (m_physicalKeys.contains(29) || m_physicalKeys.contains(97)) &&
      (m_physicalKeys.contains(56) || m_physicalKeys.contains(100));
}

void InputCaptureCore::observePosition(double x, double y,
                                       std::span<const InputRect> monitors) {
  if (captured() || m_phase == CapturePhase::CAPTURE_PENDING)
    return;

  m_armedEdges.clear();
  m_insideRemoteArm = false;
  constexpr double OUTSIDE_PROBE_DIP = 1.0;
  constexpr double ANCHOR_INSET_DIP = 1.0;

  const auto ownedRemote = [&](const InputRect &monitor) {
    return m_remote && monitor.monitorId == m_remote->monitorId &&
        monitor.x == m_remote->x && monitor.y == m_remote->y &&
        monitor.width == m_remote->width && monitor.height == m_remote->height;
  };
  // A stale topology cannot grant capture of a different or resized output.
  if (m_remote && !std::ranges::any_of(monitors, ownedRemote)) {
    m_phase = CapturePhase::LOCAL;
    return;
  }
  // A window drag may carry the physical pointer into the virtual output
  // while buttons/modifiers prevent capture. Resume at that exact coordinate
  // after release; never strand the user behind the seam.
  if (m_remote && contains(*m_remote, x, y)) {
    if (!m_physicalButtons.empty() || !m_physicalKeys.empty()) {
      m_phase = CapturePhase::LOCAL;
      return;
    }
    for (const auto &monitor : monitors) {
      if (ownedRemote(monitor) || monitor.width <= 0 || monitor.height <= 0) continue;
      const auto top = std::max(monitor.y, m_remote->y);
      const auto bottom = std::min(monitor.y + monitor.height, m_remote->y + m_remote->height);
      const auto left = std::max(monitor.x, m_remote->x);
      const auto right = std::min(monitor.x + monitor.width, m_remote->x + m_remote->width);
      std::optional<EdgeCandidate> candidate;
      if (top < bottom && monitor.x + monitor.width == m_remote->x) {
        const auto anchorY = std::clamp(y, top, std::nextafter(bottom, top));
        candidate = EdgeCandidate{protocol::Edge::RIGHT, monitor.monitorId,
            normalized(anchorY, monitor.y, monitor.height), monitor.x + monitor.width - 1, anchorY};
      } else if (top < bottom && m_remote->x + m_remote->width == monitor.x) {
        const auto anchorY = std::clamp(y, top, std::nextafter(bottom, top));
        candidate = EdgeCandidate{protocol::Edge::LEFT, monitor.monitorId,
            normalized(anchorY, monitor.y, monitor.height), monitor.x + 1, anchorY};
      } else if (left < right && monitor.y + monitor.height == m_remote->y) {
        const auto anchorX = std::clamp(x, left, std::nextafter(right, left));
        candidate = EdgeCandidate{protocol::Edge::BOTTOM, monitor.monitorId,
            normalized(anchorX, monitor.x, monitor.width), anchorX, monitor.y + monitor.height - 1};
      } else if (left < right && m_remote->y + m_remote->height == monitor.y) {
        const auto anchorX = std::clamp(x, left, std::nextafter(right, left));
        candidate = EdgeCandidate{protocol::Edge::TOP, monitor.monitorId,
            normalized(anchorX, monitor.x, monitor.width), anchorX, monitor.y + 1};
      }
      if (candidate) {
        candidate->entryPosition = std::array{x, y};
        m_armedEdges.push_back(*candidate);
        m_insideRemoteArm = true;
        break;
      }
    }
    m_phase = m_armedEdges.empty() ? CapturePhase::LOCAL : CapturePhase::EDGE_ARMED;
    return;
  }
  for (const auto &monitor : monitors) {
    if (ownedRemote(monitor))
      continue;
    if (monitor.width <= 0 || monitor.height <= 0 || !contains(monitor, x, y))
      continue;

    const auto hasAdjacent = [&](double probeX, double probeY) {
      return std::ranges::any_of(monitors, [&](const InputRect &other) {
        return other.monitorId != monitor.monitorId && !ownedRemote(other) &&
               contains(other, probeX, probeY);
      });
    };

    const auto remoteAcross = [&](protocol::Edge edge) {
      if (!m_remote)
        return true; // Preserve the separate legacy capture adapter.
      switch (edge) {
      case protocol::Edge::LEFT:
        return m_remote->x + m_remote->width == monitor.x &&
            y >= m_remote->y && y < m_remote->y + m_remote->height;
      case protocol::Edge::RIGHT:
        return monitor.x + monitor.width == m_remote->x &&
            y >= m_remote->y && y < m_remote->y + m_remote->height;
      case protocol::Edge::TOP:
        return m_remote->y + m_remote->height == monitor.y &&
            x >= m_remote->x && x < m_remote->x + m_remote->width;
      case protocol::Edge::BOTTOM:
        return monitor.y + monitor.height == m_remote->y &&
            x >= m_remote->x && x < m_remote->x + m_remote->width;
      }
      return false;
    };
    if (remoteAcross(protocol::Edge::LEFT) && x - monitor.x <= m_edgeBandDip &&
        !hasAdjacent(monitor.x - OUTSIDE_PROBE_DIP, y)) {
      m_armedEdges.push_back({protocol::Edge::LEFT, monitor.monitorId,
                              normalized(y, monitor.y, monitor.height),
                              monitor.x + ANCHOR_INSET_DIP, y});
    }
    if (remoteAcross(protocol::Edge::RIGHT) && monitor.x + monitor.width - x <= m_edgeBandDip &&
        !hasAdjacent(monitor.x + monitor.width + OUTSIDE_PROBE_DIP, y)) {
      m_armedEdges.push_back({protocol::Edge::RIGHT, monitor.monitorId,
                              normalized(y, monitor.y, monitor.height),
                              monitor.x + monitor.width - ANCHOR_INSET_DIP, y});
    }
    if (remoteAcross(protocol::Edge::TOP) && y - monitor.y <= m_edgeBandDip &&
        !hasAdjacent(x, monitor.y - OUTSIDE_PROBE_DIP)) {
      m_armedEdges.push_back({protocol::Edge::TOP, monitor.monitorId,
                              normalized(x, monitor.x, monitor.width), x,
                              monitor.y + ANCHOR_INSET_DIP});
    }
    if (remoteAcross(protocol::Edge::BOTTOM) && monitor.y + monitor.height - y <= m_edgeBandDip &&
        !hasAdjacent(x, monitor.y + monitor.height + OUTSIDE_PROBE_DIP)) {
      m_armedEdges.push_back({protocol::Edge::BOTTOM, monitor.monitorId,
                              normalized(x, monitor.x, monitor.width), x,
                              monitor.y + monitor.height - ANCHOR_INSET_DIP});
    }
  }

  m_phase =
      m_armedEdges.empty() ? CapturePhase::LOCAL : CapturePhase::EDGE_ARMED;
}

std::optional<EdgeCandidate>
InputCaptureCore::observeMotion(double unacceleratedX, double unacceleratedY) {
  if (m_phase != CapturePhase::EDGE_ARMED || !m_physicalButtons.empty() || !m_physicalKeys.empty())
    return std::nullopt;

  const auto selected = std::ranges::max_element(
      m_armedEdges, {}, [&](const EdgeCandidate &candidate) {
        return outward(candidate.edge, unacceleratedX, unacceleratedY);
      });
  if (selected == m_armedEdges.end() ||
      (!m_insideRemoteArm && outward(selected->edge, unacceleratedX, unacceleratedY) <
          m_outwardThresholdDip))
    return std::nullopt;

  m_activeEdge = *selected;
  m_phase = CapturePhase::CAPTURE_PENDING;
  return m_activeEdge;
}

bool InputCaptureCore::activate(InputLeaseIdentity lease) {
  const bool targetIsZero = std::ranges::all_of(
      lease.targetDevice, [](std::uint8_t byte) { return byte == 0; });
  if (m_phase != CapturePhase::CAPTURE_PENDING ||
      lease.generation <= m_lastGeneration || targetIsZero ||
      !m_physicalButtons.empty() || !m_physicalKeys.empty())
    return false;
  m_pendingReturnGeneration = 0;
  m_lease = lease;
  m_lastGeneration = lease.generation;
  m_phase = CapturePhase::REMOTE_CAPTURED;
  m_buttons.clear();
  m_keys.clear();
  return true;
}

ReleaseState InputCaptureCore::release() {
  ReleaseState result{m_lease, std::move(m_buttons), std::move(m_keys)};
  m_buttons.clear();
  m_keys.clear();
  m_lease.reset();
  m_activeEdge.reset();
  m_armedEdges.clear();
  m_phase = CapturePhase::LOCAL;
  return result;
}

bool InputCaptureCore::button(std::uint32_t code, bool pressed) {
  if (code == 272) m_pendingReturnGeneration = 0;
  if (pressed) m_physicalButtons.insert(code);
  else m_physicalButtons.erase(code);
  if (!captured())
    return false;
  if (pressed)
    m_buttons.insert(code);
  else
    m_buttons.erase(code);
  return true;
}

bool InputCaptureCore::key(std::uint32_t code, bool pressed) {
  if (pressed) m_physicalKeys.insert(code);
  else m_physicalKeys.erase(code);
  if (!captured())
    return false;
  if (pressed)
    m_keys.insert(code);
  else
    m_keys.erase(code);
  return true;
}

CapturePhase InputCaptureCore::phase() const noexcept { return m_phase; }

bool InputCaptureCore::captured() const noexcept {
  return m_phase == CapturePhase::REMOTE_CAPTURED;
}

const std::optional<EdgeCandidate> &
InputCaptureCore::activeEdge() const noexcept {
  return m_activeEdge;
}

const std::optional<InputLeaseIdentity> &
InputCaptureCore::lease() const noexcept {
  return m_lease;
}

double InputCaptureCore::outward(protocol::Edge edge, double dx,
                                 double dy) noexcept {
  switch (edge) {
  case protocol::Edge::LEFT:
    return -dx;
  case protocol::Edge::RIGHT:
    return dx;
  case protocol::Edge::TOP:
    return -dy;
  case protocol::Edge::BOTTOM:
    return dy;
  }
  return 0;
}

} // namespace viewflow::hyprland

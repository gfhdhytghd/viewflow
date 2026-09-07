// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "window_capture_geometry.hpp"
#include "window_gpu_wire.hpp"
#include <array>
#include <cstdint>
#include <limits>
#include <optional>

namespace viewflow_capture {

constexpr std::optional<std::uint64_t> nextCaptureGeometryEpoch(std::uint64_t current, bool changed) {
    if (current == 0) return 1;
    if (!changed) return current;
    if (current == std::numeric_limits<std::uint64_t>::max()) return std::nullopt;
    return current + 1;
}

// Producer-owned identity, not remote input authority. A new epoch makes the
// old atlas/input mapping unusable until the consumer negotiates the new one.
// Include the input sidecar: the main surface can move/resize within unchanged
// family bounds, and a scale change can alter pixels without logical movement.
class CaptureGeometryEpoch {
  public:
    using Input = std::optional<std::array<std::uint8_t, gpuwire::HCGI_BYTES>>;
    std::optional<std::uint64_t> observe(const WindowCaptureGeometry& geometry, const Input& input) {
        if (!geometry.supported || !std::isfinite(geometry.x) || !std::isfinite(geometry.y) ||
            !std::isfinite(geometry.width) || !std::isfinite(geometry.height) ||
            geometry.width <= 0 || geometry.height <= 0 ||
            geometry.pixelWidth <= 0 || geometry.pixelHeight <= 0)
            return std::nullopt;
        const auto next = nextCaptureGeometryEpoch(m_epoch, geometry != m_geometry || input != m_input);
        if (!next) return std::nullopt;
        m_geometry = geometry;
        m_input = input;
        m_epoch = *next;
        return next;
    }

  private:
    WindowCaptureGeometry m_geometry;
    Input m_input;
    std::uint64_t m_epoch = 0;
};
} // namespace viewflow_capture

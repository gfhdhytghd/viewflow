// SPDX-License-Identifier: GPL-3.0-only
// Derived from HyprCapture caa7657; see ../NOTICE.
#pragma once

#include <cmath>
#include <limits>

namespace viewflow_capture {

// Bounds include decorations. All consumers share the same outward-rounded
// pixel grid and logical origin, even on fractional-scale/negative outputs.
// The render projection is upright; output transform never swaps these axes.
struct WindowCaptureGeometry {
    double x = 0, y = 0, width = 0, height = 0;
    int pixelWidth = 0, pixelHeight = 0;
    bool supported = false;
    bool operator==(const WindowCaptureGeometry&) const = default;
};

inline WindowCaptureGeometry planWindowCaptureGeometry(double x, double y, double width, double height,
                                                       double monitorX, double monitorY, double scale, int transform) {
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) ||
        !std::isfinite(monitorX) || !std::isfinite(monitorY) || !std::isfinite(scale) ||
        width <= 0 || height <= 0 || scale <= 0 || transform < 0 || transform > 7)
        return {};
    const double left = std::floor((x - monitorX) * scale);
    const double top = std::floor((y - monitorY) * scale);
    const double right = std::ceil((x - monitorX + width) * scale);
    const double bottom = std::ceil((y - monitorY + height) * scale);
    const double w = right - left, h = bottom - top;
    // pixman/GL dimensions are signed integers. Pixel coordinates must remain
    // exactly representable so moving a window cannot overflow the crop math.
    constexpr double limit = std::numeric_limits<int>::max();
    if (!std::isfinite(w) || !std::isfinite(h) || w < 1 || h < 1 || w > limit || h > limit ||
        std::abs(left) > limit || std::abs(top) > limit || std::abs(right) > limit || std::abs(bottom) > limit)
        return {};
    return {.x = monitorX + left / scale, .y = monitorY + top / scale,
            .width = w / scale, .height = h / scale,
            .pixelWidth = static_cast<int>(w), .pixelHeight = static_cast<int>(h), .supported = true};
}

} // namespace viewflow_capture

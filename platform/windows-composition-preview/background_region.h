#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <stdexcept>
namespace viewflow::background {
// The first rectangle uses the display cache. Four disjoint outside strips
// keep ordinary live rendering when a window straddles the display boundary.
inline std::array<std::array<float, 4>, 5>
display_partition(float w, float h, std::array<float, 4> display) {
  const float l = std::clamp(display[0], 0.0f, w),
              t = std::clamp(display[1], 0.0f, h);
  const float r = std::clamp(display[2], 0.0f, w),
              b = std::clamp(display[3], 0.0f, h);
  return {
      {{l, t, r, b}, {0, 0, w, t}, {0, b, w, h}, {0, t, l, b}, {r, t, w, b}}};
}
struct Rect {
  int64_t left{}, top{}, right{}, bottom{};
  int64_t width() const { return std::max<int64_t>(0, right - left); }
  int64_t height() const { return std::max<int64_t>(0, bottom - top); }
  bool empty() const { return right <= left || bottom <= top; }
  bool contains(Rect b) const {
    return !b.empty() && left <= b.left && top <= b.top && right >= b.right &&
           bottom >= b.bottom;
  }
  bool operator==(Rect const &) const = default;
};
inline Rect intersect(Rect a, Rect b) {
  return {std::max(a.left, b.left), std::max(a.top, b.top),
          std::min(a.right, b.right), std::min(a.bottom, b.bottom)};
}
// Includes conservative tap and bilinear support of all down/up passes. Larger
// than Hyprland's damage expansion, so a cached edge cannot truncate the
// kernel.
inline int64_t hyprland_support(unsigned size, unsigned passes) {
  if (!size || size > 40 || !passes || passes > 8)
    throw std::invalid_argument("blur parameters");
  return (2 * int64_t(size) + 2) * ((int64_t(1) << passes) - 1) + 2;
}
struct Plan {
  Rect bounds;
  Rect visible;
  int64_t kernel{}, motion_x{}, motion_y{};
  bool fits_texture{};
};
inline Plan plan(Rect window, Rect desktop, int64_t kernel,
                 double velocity_x = 0, double velocity_y = 0, unsigned hz = 30,
                 int64_t max_texture = 16384) {
  if (window.empty() || desktop.empty() || kernel < 0 || !hz ||
      !std::isfinite(velocity_x) || !std::isfinite(velocity_y))
    throw std::invalid_argument("background geometry");
  Plan p;
  p.visible = intersect(window, desktop);
  p.kernel = kernel;
  if (p.visible.empty())
    return p;
  // Two update periods of motion, plus a minimum 128 physical-pixel reserve.
  auto margin = [&](double v) {
    return int64_t(
        std::ceil(std::min(16384.0, std::max(128.0, std::abs(v) * 2.0 / hz))));
  };
  p.motion_x = margin(velocity_x);
  p.motion_y = margin(velocity_y);
  const auto x = kernel + p.motion_x, y = kernel + p.motion_y;
  p.bounds = intersect({p.visible.left - x, p.visible.top - y,
                        p.visible.right + x, p.visible.bottom + y},
                       desktop);
  p.fits_texture =
      p.bounds.width() <= max_texture && p.bounds.height() <= max_texture;
  return p;
}
inline Rect usable(Rect cached, Rect desktop, int64_t kernel) {
  return {cached.left == desktop.left ? desktop.left : cached.left + kernel,
          cached.top == desktop.top ? desktop.top : cached.top + kernel,
          cached.right == desktop.right ? desktop.right : cached.right - kernel,
          cached.bottom == desktop.bottom ? desktop.bottom
                                          : cached.bottom - kernel};
}
inline bool needs_urgent_refresh(Rect cached, Rect window, Rect desktop,
                                 int64_t kernel, int64_t guard = 64) {
  return !usable(cached, desktop, kernel + guard)
              .contains(intersect(window, desktop));
}
// Translation stays in screen coordinates when the window moves/resizes. The
// previous texture is never stretched to pretend it covers newly exposed areas.
inline std::pair<int64_t, int64_t>
brush_offset(Rect cached, Rect window, int64_t node_x = 0, int64_t node_y = 0) {
  return {cached.left - window.left - node_x, cached.top - window.top - node_y};
}
} // namespace viewflow::background

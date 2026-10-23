#pragma once

#include "atlas_record.h"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>

namespace viewflow::windows_preview {

// This is deliberately an explicit receiver mapping, rather than a call to
// GetDpiForWindow(). A window can cross monitors with different DPI and an HWND
// has no meaningful DPI until it has already been placed.
struct DesktopDisplay {
  int64_t global_x_millidip{}, global_y_millidip{};
  int32_t physical_x{}, physical_y{};
  uint32_t physical_width{}, physical_height{};
  uint64_t scale_milli{};
};
struct PhysicalRect {
  int32_t x{}, y{};
  uint32_t width{}, height{};
};
struct DesktopSlice {
  vfgp::DesktopRect global;
  PhysicalRect physical;
  // Full source window in this display's physical scale, and the crop offset
  // of `physical` within it. Composition renders the full visual shifted by
  // this offset; the HWND clips it to the configured local display.
  uint32_t full_physical_width{}, full_physical_height{};
  int32_t crop_x{}, crop_y{};
};

// Scale is pixels per logical pixel times 1000: 1500 means 1.5x.
inline bool ValidDisplay(const DesktopDisplay &display) {
  return display.physical_width && display.physical_height &&
         display.scale_milli >= 125 && display.scale_milli <= 8000;
}
inline std::optional<vfgp::DesktopRect>
DisplayGlobalRect(const DesktopDisplay &display) {
  if (!ValidDisplay(display)) return {};
  const auto width = uint64_t(display.physical_width) * 1'000'000 / display.scale_milli;
  const auto height = uint64_t(display.physical_height) * 1'000'000 / display.scale_milli;
  if (display.global_x_millidip > INT64_MAX - static_cast<int64_t>(width) ||
      display.global_y_millidip > INT64_MAX - static_cast<int64_t>(height)) return {};
  return vfgp::DesktopRect{display.global_x_millidip, display.global_y_millidip, width, height};
}
inline std::optional<vfgp::DesktopRect>
IntersectDesktop(const vfgp::DesktopRect &a, const vfgp::DesktopRect &b) {
  if (!a.width_millidip || !a.height_millidip || !b.width_millidip ||
      !b.height_millidip || a.width_millidip > uint64_t(INT64_MAX) ||
      a.height_millidip > uint64_t(INT64_MAX) ||
      b.width_millidip > uint64_t(INT64_MAX) ||
      b.height_millidip > uint64_t(INT64_MAX))
    return {};
  const int64_t ar = a.x_millidip + static_cast<int64_t>(a.width_millidip);
  const int64_t ab = a.y_millidip + static_cast<int64_t>(a.height_millidip);
  const int64_t br = b.x_millidip + static_cast<int64_t>(b.width_millidip);
  const int64_t bb = b.y_millidip + static_cast<int64_t>(b.height_millidip);
  const int64_t left = (std::max)(a.x_millidip, b.x_millidip),
                top = (std::max)(a.y_millidip, b.y_millidip);
  const int64_t right = (std::min)(ar, br), bottom = (std::min)(ab, bb);
  if (right <= left || bottom <= top)
    return {};
  return vfgp::DesktopRect{left, top, uint64_t(right - left),
                           uint64_t(bottom - top)};
}
inline std::optional<uint32_t> MillidipToPixelsCeil(uint64_t value, uint64_t scale) {
  if (!scale || value > (UINT64_MAX - 999'999) / scale) return {};
  const uint64_t result = (value * scale + 999'999) / 1'000'000;
  if (!result || result > UINT32_MAX) return {};
  return uint32_t(result);
}
inline std::optional<uint32_t> MillidipToPixelsFloor(uint64_t value, uint64_t scale) {
  if (!scale || value > UINT64_MAX / scale) return {};
  const uint64_t result = value * scale / 1'000'000;
  if (result > INT32_MAX) return {};
  return uint32_t(result);
}
inline std::optional<DesktopSlice>
SliceForDisplay(const vfgp::DesktopRect &window,
                const DesktopDisplay &display) {
  const auto viewport = DisplayGlobalRect(display);
  if (!viewport)
    return {};
  const auto intersection = IntersectDesktop(window, *viewport);
  if (!intersection)
    return {};
  const auto full_width = MillidipToPixelsCeil(
      window.width_millidip, display.scale_milli);
  const auto full_height = MillidipToPixelsCeil(
      window.height_millidip, display.scale_milli);
  const auto visible_width = MillidipToPixelsCeil(
      intersection->width_millidip, display.scale_milli);
  const auto visible_height = MillidipToPixelsCeil(
      intersection->height_millidip, display.scale_milli);
  const int64_t dx = intersection->x_millidip - window.x_millidip;
  const int64_t dy = intersection->y_millidip - window.y_millidip;
  if (!full_width || !full_height || !visible_width || !visible_height || dx < 0 || dy < 0)
    return {};
  const auto crop_x = MillidipToPixelsFloor(uint64_t(dx), display.scale_milli);
  const auto crop_y = MillidipToPixelsFloor(uint64_t(dy), display.scale_milli);
  const auto offset_x = MillidipToPixelsFloor(uint64_t(intersection->x_millidip - viewport->x_millidip), display.scale_milli);
  const auto offset_y = MillidipToPixelsFloor(uint64_t(intersection->y_millidip - viewport->y_millidip), display.scale_milli);
  if (!crop_x || !crop_y || !offset_x || !offset_y) return {};
  const int64_t px = int64_t(display.physical_x) + *offset_x;
  const int64_t py = int64_t(display.physical_y) + *offset_y;
  if (px < INT32_MIN || px > INT32_MAX || py < INT32_MIN || py > INT32_MAX) return {};
  return DesktopSlice{*intersection,
      {int32_t(px), int32_t(py), *visible_width, *visible_height},
      *full_width, *full_height, int32_t(*crop_x), int32_t(*crop_y)};

}
// The OS moves the complete source window. Cropping belongs to its window
// region, never to HWND size: otherwise a cross-display drag resizes the source
// to the visible fragment and changes the pointer's grab offset.
inline std::optional<PhysicalRect> FullWindowForSlice(const DesktopSlice& slice) {
  const int64_t x = int64_t(slice.physical.x) - slice.crop_x;
  const int64_t y = int64_t(slice.physical.y) - slice.crop_y;
  if (x < INT32_MIN || x > INT32_MAX || y < INT32_MIN || y > INT32_MAX ||
      !slice.full_physical_width || !slice.full_physical_height ||
      slice.full_physical_width > INT32_MAX || slice.full_physical_height > INT32_MAX) return {};
  return PhysicalRect{int32_t(x), int32_t(y), slice.full_physical_width, slice.full_physical_height};
}
inline PhysicalRect ClipPhysicalWindow(const PhysicalRect& window, const DesktopDisplay& display) {
  const int64_t left = (std::max)(int64_t(window.x), int64_t(display.physical_x));
  const int64_t top = (std::max)(int64_t(window.y), int64_t(display.physical_y));
  const int64_t right = (std::min)(int64_t(window.x) + window.width,
                                  int64_t(display.physical_x) + display.physical_width);
  const int64_t bottom = (std::min)(int64_t(window.y) + window.height,
                                   int64_t(display.physical_y) + display.physical_height);
  if (right <= left || bottom <= top) return {};
  return {int32_t(left-window.x), int32_t(top-window.y), uint32_t(right-left), uint32_t(bottom-top)};
}

inline std::optional<std::pair<int64_t, int64_t>>
ScreenToGlobalMillidip(int32_t x, int32_t y, const DesktopDisplay &display) {
  if (!ValidDisplay(display) || x < display.physical_x ||
      y < display.physical_y ||
      uint64_t(int64_t(x) - display.physical_x) >= display.physical_width ||
      uint64_t(int64_t(y) - display.physical_y) >= display.physical_height)
    return {};
  const int64_t dx = (int64_t(x) - display.physical_x) * 1'000'000 / int64_t(display.scale_milli);
  const int64_t dy = (int64_t(y) - display.physical_y) * 1'000'000 / int64_t(display.scale_milli);
  if (display.global_x_millidip > INT64_MAX - dx ||
      display.global_y_millidip > INT64_MAX - dy)
    return {};
  return std::pair{display.global_x_millidip + dx,
                   display.global_y_millidip + dy};
}

} // namespace viewflow::windows_preview

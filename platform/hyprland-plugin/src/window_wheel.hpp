// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <array>
#include <cstdint>
#include <optional>

namespace viewflow::hyprland {
struct WheelAxis {
  std::int32_t value120;
  double distance;
};
// wl_fixed_t is signed 24.8. Hyprland uses 15 surface units per detent,
// hence value120 / 8 and a fixed representation of value120 * 32.
constexpr std::int32_t MAX_WHEEL_120 = 67'108'863;
inline std::optional<std::array<WheelAxis, 2>> windowWheelAxes(
    std::int32_t verticalUp120, std::int32_t horizontalRight120) {
  if ((!verticalUp120 && !horizontalRight120) ||
      verticalUp120 < -MAX_WHEEL_120 || verticalUp120 > MAX_WHEEL_120 ||
      horizontalRight120 < -MAX_WHEEL_120 || horizontalRight120 > MAX_WHEEL_120)
    return std::nullopt;
  return std::array<WheelAxis, 2>{{
      {-verticalUp120, -double(verticalUp120) / 8.0},
      {horizontalRight120, double(horizontalRight120) / 8.0}}};
}
}

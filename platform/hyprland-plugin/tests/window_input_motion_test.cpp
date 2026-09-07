// SPDX-License-Identifier: GPL-3.0-only
#include "window_input_motion.hpp"
#include <cstdlib>
#include <limits>

static void require(bool condition) { if (!condition) std::abort(); }
int main() {
  using viewflow::hyprland::localPointerPositionChanged;
  // Actual trial 67: popup recheck had identical initial/current coordinates.
  require(!localPointerPositionChanged(317, 960, 317, 960));
  require(!localPointerPositionChanged(-10, 0, -10, -0.0));
  require(localPointerPositionChanged(317, 960, 318, 960));
  require(localPointerPositionChanged(317, 960, 317, 959));
  require(localPointerPositionChanged(317, 960, -317, 960));
  require(localPointerPositionChanged(317, 960, 317.5, 960));
  const auto nan = std::numeric_limits<double>::quiet_NaN();
  const auto inf = std::numeric_limits<double>::infinity();
  require(localPointerPositionChanged(nan, 960, 317, 960));
  require(localPointerPositionChanged(317, 960, nan, 960));
  require(localPointerPositionChanged(317, inf, 317, inf));
  require(localPointerPositionChanged(317, 960, 317, -inf));
  using viewflow::hyprland::suppressStationaryPointerRecheck;
  int owned, unrelated;
  // Mapping a candidate can request a stationary recheck; preserve exact seat
  // focus while remote input owns it, including during a held-button drag.
  require(suppressStationaryPointerRecheck(true, &owned, &owned, 317, 960, 317, 960));
  require(!suppressStationaryPointerRecheck(true, &owned, &owned, 317, 960, 318, 960));
  require(!suppressStationaryPointerRecheck(true, &owned, &owned, 317, 960, nan, 960));
  require(!suppressStationaryPointerRecheck(false, &owned, &owned, 317, 960, 317, 960));
  require(!suppressStationaryPointerRecheck(true, nullptr, nullptr, 317, 960, 317, 960));
  require(!suppressStationaryPointerRecheck(true, &owned, nullptr, 317, 960, 317, 960));
  require(!suppressStationaryPointerRecheck(true, &owned, &unrelated, 317, 960, 317, 960));
  using viewflow::hyprland::suppressPreparedKeyboardRecheck;
  require(suppressPreparedKeyboardRecheck(true, true, &owned, &owned, 317, 960, 317, 960));
  require(suppressPreparedKeyboardRecheck(true, true, nullptr, nullptr, 317, 960, 317, 960));
  require(!suppressPreparedKeyboardRecheck(true, false, &owned, &owned, 317, 960, 317, 960));
  require(!suppressPreparedKeyboardRecheck(false, true, &owned, &owned, 317, 960, 317, 960));
  require(!suppressPreparedKeyboardRecheck(true, true, &owned, &unrelated, 317, 960, 317, 960));
  require(!suppressPreparedKeyboardRecheck(true, true, &owned, nullptr, 317, 960, 317, 960));
  require(!suppressPreparedKeyboardRecheck(true, true, &owned, &owned, 317, 960, 318, 960));
  using viewflow::hyprland::suppressCompositorFocusMotion;
  // Convenience hover repaint can retain the pointer. Every missing proof
  // (dead/expired/unstarted target, lost pointer, stale or changed focus,
  // an intervening focus transition, real cursor movement) calls the original.
  for (unsigned mask = 0; mask < 64; ++mask)
    require(suppressCompositorFocusMotion(mask & 1U, mask & 2U, mask & 4U,
        mask & 8U, mask & 16U, mask & 32U) == (mask == 63));
}

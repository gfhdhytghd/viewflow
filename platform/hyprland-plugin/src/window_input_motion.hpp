// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cmath>

namespace viewflow::hyprland {
// Hyprland's public mouse.move signal carries floored global coordinates and
// also fires for forced, stationary focus rechecks (e.g. mapping an IME popup).
// The first coordinate change revokes the target; malformed coordinates fail
// closed. This does not exempt any device/client, button, wheel or key event.
inline bool localPointerPositionChanged(double initialX, double initialY, double x, double y) {
  return !std::isfinite(initialX) || !std::isfinite(initialY) ||
      !std::isfinite(x) || !std::isfinite(y) || initialX != x || initialY != y;
}
// Preserve only an already installed exact pointer binding. A changed local
// coordinate, expired/revoked grant, or external focus takeover must pass through.
inline bool suppressStationaryPointerRecheck(bool live, const void* owned, const void* current,
    double initialX, double initialY, double x, double y) {
  return live && owned && owned == current && !localPointerPositionChanged(initialX, initialY, x, y);
}
inline bool suppressPreparedKeyboardRecheck(bool live, bool exactKeyboardActive,
    const void* originalPointer, const void* currentPointer,
    double initialX, double initialY, double x, double y) {
  return live && exactKeyboardActive && originalPointer == currentPointer &&
      !localPointerPositionChanged(initialX, initialY, x, y);
}
constexpr bool suppressCompositorFocusMotion(bool live, bool pointerOwned,
    bool unchangedDesktopFocus, bool unchangedKeyboardFocus, bool focusNeverChanged,
    bool pointerNeverMoved) {
  return live && pointerOwned && unchangedDesktopFocus && unchangedKeyboardFocus &&
      focusNeverChanged && pointerNeverMoved;
}
}

#pragma once
#include <algorithm>

namespace viewflow::macos {
enum class WindowGesture { forward, move, resize };
inline WindowGesture window_gesture(bool popup, bool command, bool shift) {
    if (popup || !command) return WindowGesture::forward;
    return shift ? WindowGesture::resize : WindowGesture::move;
}
// A locally owned move must reach the neighbouring viewport, including above
// the menu bar. Resizing and fullscreen keep the native frame constraints.
inline bool unconstrained_move(bool applying,bool dragging,bool resizing,bool fullscreen) {
    (void)applying;
    return dragging && !resizing && !fullscreen;
}
struct GestureRect { double x, y, width, height; };
// AppKit screen coordinates increase upwards. Keep the top left fixed and
// resize from the original press, so repeated events do not accumulate error.
inline GestureRect resize_from_press(GestureRect start, double dx, double dy) {
    const auto height = std::max(1., start.height - dy);
    return {start.x, start.y + start.height - height,
            std::max(1., start.width + dx), height};
}
}

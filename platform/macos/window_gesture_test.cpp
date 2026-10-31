#include "window_gesture.hpp"
#include <cassert>
using namespace viewflow::macos;
int main() {
    assert(window_gesture(false, false, false) == WindowGesture::forward);
    assert(window_gesture(false, false, true) == WindowGesture::forward);
    assert(window_gesture(true, true, true) == WindowGesture::forward);
    assert(window_gesture(false, true, false) == WindowGesture::move);
    assert(window_gesture(false, true, true) == WindowGesture::resize);
    assert(unconstrained_move(true,false,false,false));
    assert(unconstrained_move(false,true,false,false));
    assert(!unconstrained_move(false,true,true,false));
    assert(!unconstrained_move(false,true,false,true));
    assert(!unconstrained_move(false,false,false,false));
    const auto grow = resize_from_press({-100, 50, 200, 120}, 20, -30);
    assert(grow.x == -100 && grow.y == 20 && grow.width == 220 && grow.height == 150);
    const auto shrink = resize_from_press({-100, 50, 200, 120}, -300, 200);
    assert(shrink.width == 1 && shrink.height == 1 && shrink.y == 169);
}

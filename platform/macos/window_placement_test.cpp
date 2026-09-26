#include "window_placement.hpp"
#include <cassert>
int main() {
    viewflow::macos::PendingGeometry geometry;
    geometry.queue({10,1,2,800,600});
    geometry.queue({12,100,200,800,600}); // Latest drag position replaces a failed AX request.
    geometry.queue({11,50,60,800,600});
    assert(geometry.latest->sequence == 12 && geometry.latest->x == 100);
    assert(!geometry.complete(10) && geometry.latest); // An old completion cannot acknowledge final mouse-up.
    assert(geometry.complete(12) && !geometry.latest);
    viewflow::macos::WindowPlacement p;
    p.observe(200, 100);
    assert(p.pointer_x(240) == 240);
    // Entire proxy is left of the Mac display; a click still hits its backing.
    p.place(-1200, 50);
    assert(p.pointer_x(-1160) == 240 && p.pointer_y(70) == 120);
    // Moving the actual Mac window preserves the logical/native relationship.
    p.observe(220, 130);
    assert(p.x == -1180 && p.y == 80);
    assert(p.pointer_x(-1140) == 260 && p.pointer_y(100) == 150);
    p.expect_backing(-1472, -90);
    p.observe(220, 130); // Stale WindowServer result after successful AX setter.
    p.place(-1472, -90);
    p.observe(-1472, -90); // Delayed echo must not apply displacement twice.
    assert(p.x == -1472 && p.y == -90);
    assert(p.pointer_x(-1400) == -1400);
    p.observe(-1452, -80); // A later native move still propagates.
    assert(p.x == -1452 && p.y == -80);
    p.place(-3000, -1000);
    assert(p.pointer_x(-3000) == -1452 && p.pointer_y(-1000) == -80);
}

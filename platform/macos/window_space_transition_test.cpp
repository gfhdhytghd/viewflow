#include "window_space_transition.hpp"
#include <cassert>
#include <cstdio>
using namespace viewflow::macos;
static std::vector<SpaceWindow> windows(double dx = 0) {
    return {{1,100+dx,0,500,500,1}, {2,200+dx,50,500,500,1}, {3,300+dx,100,500,500,1}};
}
int main() {
    SpaceTransitionGate gate;
    assert(!gate.observe(1,false,false,{{1,10}},windows()));
    auto drag = windows(); drag[0].x += 50;
    assert(!gate.observe(1.05,false,false,{{1,10}},drag)); // Ordinary drag: no delay.
    assert(gate.observe(2,true,false,{{1,10}},windows())); // Before any bounds move.
    assert(gate.observe(10,true,false,{{1,10}},windows())); // Long/paused gesture.
    assert(gate.observe(10.1,false,false,{{1,10}},windows())); // Cancel, no notification.
    assert(!gate.observe(10.3,false,false,{{1,10}},windows()));
    assert(gate.observe(11,false,false,{{1,11}},windows())); // Active Space change.
    assert(gate.observe(11.2,false,true,{{1,11}},windows())); // End notification settles.
    assert(!gate.observe(11.5,false,false,{{1,11}},windows()));
    SpaceTransitionGate fallback;
    assert(!fallback.observe(1,false,false,{},windows()));
    assert(fallback.observe(1.05,false,false,{},windows(-20)));
    assert(fallback.observe(1.07,false,false,{}, {}, false)); // Signal-only refresh preserves geometry.
    assert(fallback.observe(1.1,false,false,{},windows(-40)));
    assert(fallback.observe(1.2,false,false,{},windows(-40)));
    assert(!fallback.observe(1.4,false,false,{},windows(-40)));
    SpaceTransitionGate mixed;
    auto baseline = windows(); baseline[2].display = 2;
    assert(!mixed.observe(1,false,false,{},baseline));
    for (auto& w:baseline) w.x += 20;
    assert(!mixed.observe(1.1,false,false,{},baseline)); // Different physical displays.
    SpaceTransitionGate resize;
    assert(!resize.observe(1,false,false,{},windows()));
    auto sized = windows(20); for (auto& w:sized) w.width += 10;
    assert(!resize.observe(1.1,false,false,{},sized));
    assert(!resize.observe(2,false,false,{},{})); // Missing inventory doesn't latch forever.
    std::puts("PASS Spaces gate: animation, cancel, settle, notification, fallback, drag, display isolation, resize");
}

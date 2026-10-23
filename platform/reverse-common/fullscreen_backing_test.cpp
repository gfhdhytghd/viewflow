#include "fullscreen_backing.hpp"
#include "window_surface.hpp"
#include <cassert>
using namespace viewflow::reverse;
int main() {
    assert(windows_fullscreen_backing_enabled(false,true,false,false,false));
    assert(!windows_fullscreen_backing_enabled(true,true,false,false,false));
    assert(!windows_fullscreen_backing_enabled(false,false,false,false,false));
    assert(!windows_fullscreen_backing_enabled(false,true,true,false,false));
    assert(!windows_fullscreen_backing_enabled(false,true,false,true,false));
    assert(!windows_fullscreen_backing_enabled(false,true,false,false,true));
    // A 6K backing at an unrelated guest origin must map the proxy center
    // to the source center, independent of host desktop origin/global scale.
    assert(body_pointer(1536,0,3072,6144,250,1)==3322);
    assert(body_pointer(864,0,1728,3456,100,1)==1828);
    assert(body_pointer(768,0,3072,6144,250,1)==1786);
    const Geometry small{10,20,800,600},full{10,20,6144,3456};
    FullscreenRouteControl route;
    assert(!route.observe(false,small,0) && route.exit_delivered());
    assert(route.observe(true,full,1)->mode==2);route.sent(0);
    assert(!route.observe(true,full,500));
    assert(route.observe(true,full,501));route.sent(90);
    assert(!route.observe(true,full,10000));
    assert(route.observe(true,small,10001)->width==800);route.sent(91);
    assert(route.observe(false,small,10002)->mode==0);route.sent(0);
    assert(!route.exit_delivered());
    assert(route.observe(false,small,10502));route.sent(92);
    assert(route.exit_delivered() && !route.observe(false,small,20000));
    assert(!route.observe(true,std::nullopt,20001));
    assert(route.observe(true,full,20002)->height==3456);route.sent(93);
    assert(fullscreen_backing_extent(small,6144,3456,0)==full);
    assert((fullscreen_backing_extent(small,6144,3456,1)==Geometry{10,20,3456,6144}));
    assert(!fullscreen_backing_extent(small,16385,1,0));
    FullscreenBacking state;
    assert(!state.observe(false,small,small,0,0).consume);
    assert(state.observe(true,full,small,0,0).send);state.sent(10,0);
    assert(!state.observe(true,full,small,0,499).send);
    assert(state.observe(true,full,small,0,500).send);state.sent(11,500);
    assert(!state.observe(true,full,full,11,501).send);
    assert(state.observe(false,small,full,11,502).send);state.sent(12,502);
    assert(state.observe(false,small,full,11,503).consume && state.active);
    assert(state.observe(false,small,full,11,1002).send);state.sent(13,1002);
    assert(state.observe(false,small,small,11,1003).consume && state.active); // old fullscreen receipt
    assert(state.observe(false,small,small,12,1004).consume && !state.active);
    assert(!state.observe(false,small,small,13,1005).consume);
    // Enter during restoration, late exit receipt, and changed monitor extent.
    assert(state.observe(true,full,small,13,1010).send);state.sent(14,1010);
    assert(state.observe(false,small,full,14,1011).send);state.sent(15,1011);
    assert(state.observe(true,full,small,15,1012).send);state.sent(16,1012);
    assert(!state.observe(true,full,small,15,1013).send);
    auto rotated=fullscreen_backing_extent(small,6144,3456,3);
    assert(state.observe(true,rotated,full,16,1014).send);state.sent(0,1014);
    assert(state.observe(true,rotated,full,16,1514).send);
    // Restored geometry remains host-owned if floating -> tiled changes it.
    assert(state.observe(false,small,full,16,1515).send);state.sent(17,1515);
    Geometry tiled{20,30,1000,900};
    assert(state.observe(false,tiled,small,17,1516).send);state.sent(18,1516);
    assert(state.observe(false,tiled,tiled,18,1517).consume && !state.active);
    // Missing output temporarily retains ownership and existing snapshot.
    assert(!state.observe(true,std::nullopt,tiled,18,1518).send && state.active);
    assert(state.observe(true,full,tiled,18,1519).send);
}

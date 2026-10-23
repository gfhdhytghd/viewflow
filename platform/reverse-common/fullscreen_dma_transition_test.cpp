#include "fullscreen_dma_transition.hpp"
#include <cassert>
#include <cstdio>
namespace vf = viewflow::reverse;
int main() {
    using Request = vf::FullscreenRequestResult;
    using Frame = vf::FullscreenFrameResult;
    vf::FullscreenDmaTransition state;
    vf::FullscreenRouteTarget window{vf::FullscreenTransport::window,42,{6144,3456}};
    assert(!state.pending() && !state.has_snapshot());
    assert(state.request(window)==Request::requested);
    const auto first=*state.desired();
    assert(first.epoch==1 && state.pending() && !state.has_snapshot());
    assert(state.frame(first,false)==Frame::incomplete && !state.active());
    assert(state.frame(first,true)==Frame::activate_requested);
    assert(state.has_snapshot() && !state.pending());
    for(int i=0;i<3;++i) assert(state.frame(first,true)==Frame::update_active);
    assert(state.request(window)==Request::unchanged && state.desired()==state.active());

    auto dma=window;dma.route=vf::FullscreenTransport::direct_dma;
    assert(state.request(dma)==Request::requested);
    const auto direct=*state.desired();
    assert(direct.epoch>first.epoch && state.active()==first && state.has_snapshot());
    assert(state.frame(first,true)==Frame::update_active && state.pending());
    assert(state.frame(direct,false)==Frame::incomplete && state.active()==first);
    auto mismatch=direct;
    mismatch.target.window=43;assert(state.frame(mismatch,true)==Frame::stale);
    mismatch=direct;mismatch.target.pixels.width=3072;assert(state.frame(mismatch,true)==Frame::stale);
    mismatch=direct;mismatch.epoch=0;assert(state.frame(mismatch,true)==Frame::stale);
    mismatch=direct;mismatch.target.route=vf::FullscreenTransport::window;assert(state.frame(mismatch,true)==Frame::stale);
    assert(state.active()==first);
    assert(state.frame(direct,true)==Frame::activate_requested && !state.pending());
    assert(state.frame(first,true)==Frame::stale);
    assert(state.frame(direct,true)==Frame::update_active);

    assert(state.dma_failed(direct)==Request::requested);
    const auto fallback=*state.desired();
    assert(fallback.target==window && fallback.epoch>direct.epoch);
    assert(state.active()==direct && state.has_snapshot());
    assert(state.dma_failed(direct)==Request::unchanged && state.desired()==fallback);
    assert(state.frame(fallback,false)==Frame::incomplete && state.active()==direct);
    assert(state.frame(fallback,true)==Frame::activate_requested);
    assert(state.frame(direct,true)==Frame::stale);
    assert(state.frame(fallback,true)==Frame::update_active);

    // Rapid fullscreen exit/re-entry cannot activate an earlier identical
    // route description: each change gets its own generation.
    assert(state.request(dma)==Request::requested);const auto attempt=*state.desired();
    assert(state.request(window)==Request::requested);const auto exit=*state.desired();
    assert(state.request(dma)==Request::requested);const auto latest=*state.desired();
    assert(state.frame(attempt,true)==Frame::stale);
    assert(state.frame(exit,true)==Frame::stale);
    assert(state.dma_failed(attempt)==Request::unchanged && state.desired()==latest);
    assert(state.frame(latest,true)==Frame::activate_requested);

    auto resized=dma;resized.pixels={3456,6144};
    assert(state.request(resized)==Request::requested);const auto resize=*state.desired();
    assert(state.frame(latest,true)==Frame::update_active && state.pending());
    assert(state.frame(resize,true)==Frame::activate_requested);
    auto other=resized;other.window=43;
    assert(state.request(other)==Request::requested);const auto retarget=*state.desired();
    assert(state.frame(resize,true)==Frame::stale && state.has_snapshot());
    assert(state.frame(retarget,true)==Frame::activate_requested);

    auto invalid=other;invalid.pixels.height=0;
    assert(state.request(invalid)==Request::invalid && state.desired()==retarget);
    invalid=other;invalid.window=0;assert(state.request(invalid)==Request::invalid);
    assert(state.frame(retarget,true)==Frame::update_active);
    std::puts("fullscreen DMA transition: completed-frame handoff, snapshot retention, stale epochs and local fallback passed");
}

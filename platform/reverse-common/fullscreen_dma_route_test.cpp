#include "fullscreen_dma_route.hpp"
#include <cassert>
#include <cstdio>
#include <initializer_list>
namespace vf = viewflow::reverse;
int main() {
    vf::FullscreenDmaRequest good;
    good.hypr_fullscreen_mode=2;
    good.target_window=good.frame_window=42;
    good.window_pixels=good.output_pixels=good.transport_pixels={6144,3456};
    good.route_window_count=1;
    good.gpu_dma_supported=true;
    assert(vf::fullscreen_dma_route(good).eligible());
    const auto reject=[&](auto change,vf::DmaFallback reason) {
        auto r=good;change(r);
        const auto decision=vf::fullscreen_dma_route(r);
        assert(!decision.eligible() && decision.reason==reason);
        assert(vf::dma_fallback_name(reason)!="unknown");
    };
    for(int mode: {0,1,3}) reject([&](auto& r){r.hypr_fullscreen_mode=mode;},vf::DmaFallback::not_fullscreen);
    reject([](auto& r){r.target_window=0;},vf::DmaFallback::invalid_target);
    reject([](auto& r){r.frame_window=43;},vf::DmaFallback::wrong_window);
    for(unsigned count: {0u,2u}) reject([&](auto& r){r.route_window_count=count;},vf::DmaFallback::multiple_windows);
    reject([](auto& r){r.gpu_dma_supported=false;},vf::DmaFallback::unsupported);
    reject([](auto& r){r.window_pixels.width=0;},vf::DmaFallback::invalid_extent);
    reject([](auto& r){r.output_pixels.height=16385;},vf::DmaFallback::invalid_extent);
    reject([](auto& r){r.transport_pixels.width=16385;},vf::DmaFallback::invalid_extent);
    reject([](auto& r){r.window_pixels={3072,1728};},vf::DmaFallback::window_output_mismatch);
    reject([](auto& r){r.transport_pixels={3456,6144};},vf::DmaFallback::transport_mismatch);
    // Full destination coverage alone must never select desktop capture.
    reject([](auto& r){r.capture=vf::DmaCapture::desktop_output;},vf::DmaFallback::source_not_exclusive);
    reject([](auto& r){r.capture=vf::DmaCapture::desktop_output;r.source_desktop_exclusive=true;},vf::DmaFallback::source_output_unbound);
    reject([](auto& r){r.capture=vf::DmaCapture::desktop_output;r.source_desktop_exclusive=true;r.bound_source_output=1;r.captured_source_output=2;},vf::DmaFallback::wrong_source_output);
    auto desktop=good;desktop.capture=vf::DmaCapture::desktop_output;
    desktop.source_desktop_exclusive=true;desktop.bound_source_output=desktop.captured_source_output=7;
    assert(vf::fullscreen_dma_route(desktop).eligible());
    // Losing desktop eligibility does not constrain direct per-window DMA.
    desktop.source_desktop_exclusive=false;
    assert(!vf::fullscreen_dma_route(desktop).eligible());
    desktop.capture=vf::DmaCapture::window;
    assert(vf::fullscreen_dma_route(desktop).eligible());
    good.window_pixels=good.output_pixels=good.transport_pixels={16384,16384};
    assert(vf::fullscreen_dma_route(good).eligible());
    good.window_pixels=good.output_pixels=good.transport_pixels={3456,6144};
    assert(vf::fullscreen_dma_route(good).eligible());
    std::puts("fullscreen DMA routing: physical extents, target identity, capabilities and desktop output binding passed");
}

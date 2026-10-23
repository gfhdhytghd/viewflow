#pragma once
#include <cstdint>
#include <string_view>

namespace viewflow::reverse {
// Pure candidate selection, not a connection gate. A rejected fast path keeps
// the ordinary per-window stream and last snapshot. No focus/time policy.
// Sizes are physical BGRA pixels after the destination output transform;
// callers must not compare Hyprland logical coordinates with capture pixels.
struct DmaExtent {
    std::uint32_t width{}, height{};
    bool operator==(const DmaExtent&) const = default;
};
enum class DmaCapture { window, desktop_output };
struct FullscreenDmaRequest {
    int hypr_fullscreen_mode{}; // Actual compositor state: 2, not maximized 1.
    std::uint64_t target_window{}, frame_window{};
    DmaExtent window_pixels{}, output_pixels{}, transport_pixels{};
    unsigned route_window_count{}; // Windows in this payload, not all proxies.
    bool gpu_dma_supported{}; // Both producer and receiver support this path.
    DmaCapture capture{DmaCapture::window};
    // Required only for desktop capture. Destination fullness never proves
    // that a Windows desktop contains this window alone. Binding must come
    // from the source output/capture owner, not a Linux monitor index.
    bool source_desktop_exclusive{};
    std::uint64_t bound_source_output{}, captured_source_output{};
};
enum class DmaFallback {
    none, not_fullscreen, invalid_target, wrong_window, multiple_windows,
    unsupported, invalid_extent, window_output_mismatch,
    transport_mismatch, source_not_exclusive, source_output_unbound,
    wrong_source_output
};
struct FullscreenDmaDecision {
    DmaFallback reason{};
    constexpr bool eligible() const { return reason == DmaFallback::none; }
};
constexpr bool valid_dma_extent(DmaExtent extent) {
    return extent.width && extent.height && extent.width <= 16384 && extent.height <= 16384;
}
constexpr FullscreenDmaDecision fullscreen_dma_route(const FullscreenDmaRequest& r) {
    if(r.hypr_fullscreen_mode != 2) return {DmaFallback::not_fullscreen};
    if(!r.target_window) return {DmaFallback::invalid_target};
    if(r.frame_window != r.target_window) return {DmaFallback::wrong_window};
    if(r.route_window_count != 1) return {DmaFallback::multiple_windows};
    if(!r.gpu_dma_supported) return {DmaFallback::unsupported};
    if(!valid_dma_extent(r.window_pixels) || !valid_dma_extent(r.output_pixels) ||
       !valid_dma_extent(r.transport_pixels)) return {DmaFallback::invalid_extent};
    if(r.window_pixels != r.output_pixels) return {DmaFallback::window_output_mismatch};
    if(r.transport_pixels != r.output_pixels) return {DmaFallback::transport_mismatch};
    if(r.capture == DmaCapture::desktop_output) {
        if(!r.source_desktop_exclusive) return {DmaFallback::source_not_exclusive};
        if(!r.bound_source_output || !r.captured_source_output) return {DmaFallback::source_output_unbound};
        if(r.bound_source_output != r.captured_source_output) return {DmaFallback::wrong_source_output};
    }
    return {};
}
constexpr std::string_view dma_fallback_name(DmaFallback reason) {
    switch(reason) {
    case DmaFallback::none: return "eligible";
    case DmaFallback::not_fullscreen: return "not-fullscreen";
    case DmaFallback::invalid_target: return "invalid-target";
    case DmaFallback::wrong_window: return "wrong-window";
    case DmaFallback::multiple_windows: return "multiple-windows";
    case DmaFallback::unsupported: return "unsupported";
    case DmaFallback::invalid_extent: return "invalid-extent";
    case DmaFallback::window_output_mismatch: return "window-output-mismatch";
    case DmaFallback::transport_mismatch: return "transport-mismatch";
    case DmaFallback::source_not_exclusive: return "source-not-exclusive";
    case DmaFallback::source_output_unbound: return "source-output-unbound";
    case DmaFallback::wrong_source_output: return "wrong-source-output";
    }
    return "unknown";
}
}

#pragma once
#include <algorithm>
#include <cmath>
namespace viewflow::reverse {
// Pointer regions of a Mac proxy, in proxy surface (logical point) units.
// Compositor edge resizing happens outside the proxy surface. Inside it, the
// top strip behaves like a macOS title/unified-toolbar area: dragging it moves
// the window, while a plain click still reaches the source application.
inline constexpr double titlebar_band_points=44;
// Source clicks never land closer to the window edge than this. macOS treats
// the outermost points of a window as its own resize zone, which would start a
// second, competing resize at the source.
inline constexpr double source_edge_inset_points=6;
// Movement beyond this distance turns a held press into a drag.
inline constexpr double drag_slop_points=4;
enum class PointerRegion { content, titlebar };
inline PointerRegion classify_pointer(double y,double window_height) {
    const double band=std::min(titlebar_band_points,std::max(0.,window_height/3));
    return y>=0 && y<band?PointerRegion::titlebar:PointerRegion::content;
}
// Keep a source coordinate inside the window, away from its resize zone.
inline double inset_source_point(double value,double extent) {
    const double inset=std::min(source_edge_inset_points,std::max(0.,extent/4));
    return std::clamp(value,inset,std::max(inset,extent-inset));
}
inline bool drag_exceeds_slop(double dx,double dy) {
    return std::hypot(dx,dy)>=drag_slop_points;
}
}

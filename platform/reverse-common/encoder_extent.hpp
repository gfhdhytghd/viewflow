// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <cstdint>
#include <stdexcept>
namespace viewflow::media {
struct Extent { unsigned width, height; bool operator==(const Extent& other) const { return width==other.width && height==other.height; } };
// Conservative interoperable ceilings. A driver's smaller limits take priority.
// These are codec resource limits, never limits on window or desktop geometry.
inline Extent encoderLimit(bool h264) { return h264 ? Extent{4096,4096} : Extent{8192,8192}; }
inline Extent fitExtent(Extent input, Extent limit) {
    if (!input.width || !input.height || limit.width < 2 || limit.height < 2)
        throw std::invalid_argument("invalid encoder extent");
    uint64_t w=input.width, h=input.height;
    if (w > limit.width || h > limit.height) {
        if (w*limit.height >= h*limit.width) { h=std::max<uint64_t>(2,h*limit.width/w);w=limit.width; }
        else { w=std::max<uint64_t>(2,w*limit.height/h);h=limit.height; }
    }
    return {unsigned(std::max<uint64_t>(2,w & ~1ULL)), unsigned(std::max<uint64_t>(2,h & ~1ULL))};
}
// Coded color can be smaller than the layout canvas. Alpha and input coordinates
// retain the canvas geometry. Receivers sample color in normalized coordinates.
inline bool reducedColor(Extent coded, Extent canvas) {
    return coded.width>=2 && coded.height>=2 && coded.width<=canvas.width && coded.height<=canvas.height;
}
}

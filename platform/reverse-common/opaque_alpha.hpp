#pragma once
#include "window_residency.hpp"
#include <array>
#include <cstdlib>
#include <cstring>

namespace viewflow::reverse {
inline bool transparency_enabled() {
    const auto* value=std::getenv("VIEWFLOW_TRANSPARENCY");
    return !value || std::strcmp(value,"0")!=0;
}
// Shared by native sources. Only geometry changes rebuild the mask; capture
// pixels (including animated shadows) never participate in the cache key.
class OpaqueAlphaCache {
    using Rect=std::array<unsigned,4>;
    unsigned width_{},height_{};
    std::vector<Rect> rectangles_;
    std::vector<std::uint8_t> alpha_;
public:
    const std::vector<std::uint8_t>& get(const Frame& frame) {
        return get(frame, [](const Tile&) { return true; });
    }
    template<class Included>
    const std::vector<std::uint8_t>& get(const Frame& frame, Included included) {
        std::vector<Rect> rectangles;
        for(const auto& t:frame.tiles) {
            if(!included(t))continue;
            const auto r=resident_rect(t);
            const auto bx=(t.flags&16)?t.body_x:0u, by=(t.flags&16)?t.body_y:0u;
            const auto bw=(t.flags&16)?t.body_width:t.width, bh=(t.flags&16)?t.body_height:t.height;
            const auto left=std::max(r.x,bx), top=std::max(r.y,by);
            const auto right=std::min(r.x+r.width,bx+bw), bottom=std::min(r.y+r.height,by+bh);
            if(left<right && top<bottom) rectangles.push_back({t.atlas_x+left-r.x,t.atlas_y+top-r.y,right-left,bottom-top});
        }
        if(alpha_.empty() || width_!=frame.width || height_!=frame.height || rectangles_!=rectangles) {
            alpha_.assign(size_t(frame.width)*frame.height,0);
            for(const auto& r:rectangles) {
                if(r[0]+r[2]>frame.width || r[1]+r[3]>frame.height)throw std::runtime_error("opaque mask outside atlas");
                for(unsigned y=r[1];y<r[1]+r[3];++y)
                    std::fill_n(alpha_.begin()+size_t(y)*frame.width+r[0],r[2],255);
            }
            width_=frame.width;height_=frame.height;rectangles_=std::move(rectangles);
        }
        return alpha_;
    }
};
}

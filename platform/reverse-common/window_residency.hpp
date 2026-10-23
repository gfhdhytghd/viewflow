#pragma once
#include "wire.hpp"
#include <algorithm>
#include <cmath>

namespace viewflow::reverse {
struct PixelRect {
    unsigned x{}, y{}, width{}, height{};
    bool operator==(const PixelRect&) const = default;
};
inline PixelRect resident_rect(const Tile& tile) {
    return tile.flags & resident_crop_flag ? PixelRect{tile.resident_x,tile.resident_y,tile.resident_width,tile.resident_height}
                                          : PixelRect{0,0,tile.width,tile.height};
}
inline void set_resident_rect(Tile& tile, PixelRect r) {
    tile.flags |= resident_crop_flag;
    tile.resident_x=r.x; tile.resident_y=r.y; tile.resident_width=r.width; tile.resident_height=r.height;
}
inline PixelRect clip_resident(unsigned width,unsigned height,int x,int y,int w,int h) {
    if(w<=0 || h<=0)return {};
    const auto left=std::clamp<int64_t>(x,0,width),top=std::clamp<int64_t>(y,0,height);
    const auto right=std::clamp<int64_t>(int64_t(x)+w,0,width),bottom=std::clamp<int64_t>(int64_t(y)+h,0,height);
    if(right<=left || bottom<=top)return {};
    return {unsigned(left),unsigned(top),unsigned(right-left),unsigned(bottom-top)};
}
inline PixelRect align_resident(PixelRect r,unsigned width,unsigned height,unsigned grid=128) {
    if(!r.width || !r.height)return {};
    const auto right=std::min(width,((r.x+r.width+grid-1)/grid)*grid);
    const auto bottom=std::min(height,((r.y+r.height+grid-1)/grid)*grid);
    r.x=r.x/grid*grid;r.y=r.y/grid*grid;r.width=right-r.x;r.height=bottom-r.y;return r;
}
// Viewport coordinates are local source pixels. Round outward and prefetch a
// bounded seam strip so an ordinary move can reveal pixels already in flight.
inline PixelRect viewport_resident(unsigned width,unsigned height,double left,double top,double right,double bottom,unsigned margin=256) {
    if(!std::isfinite(left)||!std::isfinite(top)||!std::isfinite(right)||!std::isfinite(bottom))return {0,0,width,height};
    if(right<=left || bottom<=top)return {};
    left=std::clamp(std::floor(left)-margin,0.,double(width));
    top=std::clamp(std::floor(top)-margin,0.,double(height));
    right=std::clamp(std::ceil(right)+margin,0.,double(width));
    bottom=std::clamp(std::ceil(bottom)+margin,0.,double(height));
    return clip_resident(width,height,int(left),int(top),int(right-left),int(bottom-top));
}
inline uint8_t tile_alpha(unsigned atlas_width,const Tile& tile,std::span<const uint8_t> alpha,unsigned x,unsigned y) {
    const auto r=resident_rect(tile);
    if(x<r.x || y<r.y || x-r.x>=r.width || y-r.y>=r.height)return 0;
    const auto offset=size_t(tile.atlas_y+y-r.y)*atlas_width+tile.atlas_x+x-r.x;
    return offset<alpha.size()?alpha[offset]:0;
}
inline uint8_t tile_alpha(const Frame& frame,const Tile& tile,std::span<const uint8_t> alpha,unsigned x,unsigned y) { return tile_alpha(frame.width,tile,alpha,x,y); }
}

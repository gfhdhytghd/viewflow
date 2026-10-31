#pragma once
#include "wire.hpp"
#include <cmath>
#include <algorithm>
namespace viewflow::reverse {
struct SurfaceGeometry {
    int width{},height{},x{},y{},body_width{},body_height{};
};
inline bool body_point(const SurfaceGeometry& s,double x,double y) {
    return x>=s.x && y>=s.y && x<s.x+s.body_width && y<s.y+s.body_height;
}
// Aspect-fit the currently displayed frame, not an unacknowledged resize.
inline SurfaceGeometry fitted_body(int width,int height,unsigned source_width,unsigned source_height) {
    if(width<=0 || height<=0 || !source_width || !source_height)return {};
    const double ratio=std::min(double(width)/source_width,double(height)/source_height);
    const int w=std::max(1,int(std::lround(source_width*ratio)));
    const int h=std::max(1,int(std::lround(source_height*ratio)));
    return {width,height,(width-w)/2,(height-h)/2,w,h};
}
// c=0 keeps legacy pixel coordinates. d optionally carries their body extent
// (two unsigned 16-bit dimensions), so a newer frame cannot change the ratio.
inline std::int32_t pointer_extent(unsigned width,unsigned height) {
    return std::bit_cast<std::int32_t>((height<<16)|width);
}
inline double local_pointer(double point,double extent,double native_extent,bool clamp) {
    const double value=point*native_extent/std::max(1.,extent);
    return clamp?std::clamp(value,0.,std::max(0.,native_extent-0.5)):value;
}
// Present the native body as a complete surface. Original shadow pixels use a
// separate non-interactive subsurface, outside the tiling rectangle.
inline Tile body_tile(Tile tile) {
    if(tile.flags&16) {
        tile.atlas_x+=tile.body_x;tile.atlas_y+=tile.body_y;
        tile.width=tile.body_width;tile.height=tile.body_height;
        tile.flags &= ~16u;
    }
    return tile;
}
inline SurfaceGeometry body_surface(int width,int height) { return {width,height,0,0,width,height}; }
inline int logical_width(const Tile& tile,unsigned scale) {
    return tile.flags&16?tile.logical_width:(tile.width+scale-1)/scale;
}
inline int logical_height(const Tile& tile,unsigned scale) {
    return tile.flags&16?tile.logical_height:(tile.height+scale-1)/scale;
}
inline SurfaceGeometry surface_geometry(const Tile& tile,int width,int height) {
    if(!(tile.flags&16))return {width,height,0,0,width,height};
    const double sx=double(width)/tile.body_width,sy=double(height)/tile.body_height;
    const int x=std::lround(tile.body_x*sx),y=std::lround(tile.body_y*sy);
    return {std::max(x+width,int(std::ceil(tile.width*sx))),
            std::max(y+height,int(std::ceil(tile.height*sy))),x,y,width,height};
}
// Convert a Wayland surface point to source-desktop pixels, including asymmetric
// native frame padding and any compositor resize of the displayed body.
inline double body_pointer(double point,int inset,int displayed_body,unsigned logical_body,
                           int desktop_origin,unsigned scale) {
    return desktop_origin+(point-inset)*logical_body/std::max(1,displayed_body)*scale;
}
// A held-pointer gesture keeps its initial source mapping. Video geometry and
// proxy movement may arrive later and must not feed back into pointer motion.
struct PointerAnchor {
    double desktop{},source{},scale{1};
    double at(double position) const { return source+(position-desktop)*scale; }
};
inline bool body_pixel(const Tile& tile,unsigned x,unsigned y) {
    return !(tile.flags&16) || (x>=tile.body_x && y>=tile.body_y &&
        x-tile.body_x<tile.body_width && y-tile.body_y<tile.body_height);
}
}

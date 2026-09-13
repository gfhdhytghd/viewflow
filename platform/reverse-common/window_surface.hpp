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

#pragma once
#include "../reverse-common/wire.hpp"
#include <algorithm>
#include <cmath>
namespace viewflow::portable {
struct Geometry {
    double body_x{},body_y{},body_width{},body_height{},width{},height{},pixel_x{},pixel_y{},padding{},image_x{},image_y{};
};
inline Geometry geometry(const reverse::Tile& t,double scale,bool maximized=false) {
    const bool native=(t.flags&16)!=0;
    const double unit=native?double(t.pixel_scale)/scale:1./scale;
    const double padding=native && !(t.flags&2)?108*unit:0;
    const double x=native?double(t.logical_width)*unit/t.body_width:1./scale;
    const double y=native?double(t.logical_height)*unit/t.body_height:1./scale;
    if(native && !(t.flags&2))return {0,0,t.logical_width*unit,t.logical_height*unit,
        t.logical_width*unit,t.logical_height*unit,x,y,maximized?0:padding,-double(t.body_x)*x,-double(t.body_y)*y};
    return {padding+(native?t.body_x*x:0),padding+(native?t.body_y*y:0),
        native?t.logical_width*unit:t.width/scale,native?t.logical_height*unit:t.height/scale,
        t.width*x+padding*2,t.height*y+padding*2,x,y,padding,padding,padding};
}
}

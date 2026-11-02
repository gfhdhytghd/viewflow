#pragma once
#include <algorithm>
#include <array>
namespace viewflow::reverse {
struct WorkRect { double x,y,width,height; };
// AppKit uses bottom-left coordinates. Insets are top/right/bottom/left.
inline std::array<double,4> visibleInsets(WorkRect frame,WorkRect visible,std::array<double,4> safe={}) {
    return {std::max({0.,frame.y+frame.height-visible.y-visible.height,safe[0]}),
        std::max({0.,frame.x+frame.width-visible.x-visible.width,safe[1]}),
        std::max({0.,visible.y-frame.y,safe[2]}),std::max({0.,visible.x-frame.x,safe[3]})};
}
inline WorkRect projectScreen(WorkRect frame,double desktopTop,double originX,double originY,double scale) {
    return {(frame.x-originX)*scale,(desktopTop-frame.y-frame.height-originY)*scale,frame.width*scale,frame.height*scale};
}
inline double overlap(WorkRect a,WorkRect b) {
    return std::max(0.,std::min(a.x+a.width,b.x+b.width)-std::max(a.x,b.x))*
        std::max(0.,std::min(a.y+a.height,b.y+b.height)-std::max(a.y,b.y));
}
}

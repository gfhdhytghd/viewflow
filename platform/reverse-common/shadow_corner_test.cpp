#include "shadow_corner.hpp"
#include <cassert>
#include <vector>
using namespace viewflow::reverse;
int main() {
    Tile t;t.flags=16;t.width=t.body_width=t.logical_width=160;t.height=t.body_height=t.logical_height=120;
    std::vector<uint8_t> alpha(t.width*t.height,255);
    const auto fill=[&](unsigned radius,bool bottomSquare=false) {
        std::fill(alpha.begin(),alpha.end(),255);
        for(unsigned y=0;y<t.height;++y)for(unsigned x=0;x<t.width;++x) {
            const double dx=double(radius)-std::min(x,t.width-1-x)-.5;
            const double dy=double(radius)-std::min(y,t.height-1-y)-.5;
            if((!bottomSquare || y<t.height/2) && dx>0 && dy>0 && dx*dx+dy*dy>radius*radius)alpha[y*t.width+x]=0;
        }
    };
    assert(shadow_corner(t.width,t,alpha,80,60)==0);
    fill(8);assert(shadow_corner(t.width,t,alpha,80,60)==40);
    fill(16);assert(shadow_corner(t.width,t,alpha,80,60)==80);
    fill(8,true);assert(!shadow_corner(t.width,t,alpha,80,60));
    fill(8);for(unsigned y=10;y<30;++y)alpha[y*t.width]=0;
    assert(!shadow_corner(t.width,t,alpha,80,60));
    fill(8);const auto original=alpha;auto clipped=t;set_resident_rect(clipped,{1,0,t.width-1,t.height});
    assert(!shadow_corner(t.width,clipped,alpha,80,60));
    assert(shadow_corner(t.width,t,alpha,80,60)==40 && alpha==original);
    assert(windows_shadow_radius("ViewflowReverse-WindowsNative-r40-12")==4.);
    assert(windows_shadow_radius("ViewflowReverse-WindowsNative-r0-12")==0.);
    assert(!windows_shadow_radius("ViewflowReverse-WindowsNative-rX-12"));
    assert(!windows_shadow_radius("ViewflowReverse-MacNative-12"));
}

#include "scroll_units.hpp"
#include <cassert>
#include <cmath>
using namespace viewflow::reverse;
int main() {
    for(int axis:{0,1})for(int amount:{-2500,-1000,-125,0,125,1000,2500}) {
        auto s=decode_scroll(axis,amount,1,0);assert(s && s->precise && !s->ended);
        assert(std::abs(s->distance-amount/1000.)<1e-12);
        auto end=decode_scroll(axis,amount,1,1);assert(end->ended && end->distance==s->distance);
    }
    for(int axis:{0,1})for(int amount:{-240,-120,-30,0,30,120,240}) {
        auto s=decode_scroll(axis,amount,0,0);assert(s && !s->precise && s->distance==amount/120.);
        // Daily Linux path: positive Wayland is negative on both AppKit axes.
        assert(decode_scroll(axis,scroll_from_wayland(amount),0,0)->distance==-amount/120.);
        auto windows=scroll_from_windows(axis!=0,amount);
        assert(decode_scroll(axis,windows,0,0)->distance==(axis?-amount:amount)/120.);
        assert(scroll_from_windows(axis!=0,windows)==amount);
    }
    ScrollPointAccumulator points;
    assert(points.phase(0,false)==1);assert(points.phase(0,false)==2);
    assert(points.phase(0,true)==4);assert(points.phase(0,false)==1);
    assert(points.phase(1,false)==1);
    for(int i=0;i<7;++i)assert(points.take(0,125)==0);
    assert(points.take(0,125)==1);
    assert(points.take(1,-500)==0);assert(points.take(1,0)==0);
    assert(points.take(1,-500)==-1);
    assert(points.take(0,2500)==2);assert(points.take(0,-500)==0);
    assert(decode_scroll(1,0,1,1)->ended);
    assert(!decode_scroll(2,1,0,0));assert(!decode_scroll(0,1,2,0));assert(!decode_scroll(0,1,1,2));
}

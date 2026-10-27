#include "quality_control.hpp"
#include <cassert>
int main() {
    viewflow::reverse::Writer w;for(auto v:{7u,1u,12000u,30u,750u})w.u32(v);
    const auto t=viewflow::quality::unpack(w.bytes);assert(t.kbps==12000 && t.max_fps==30 && t.scale_permille==750);
    for(unsigned field=0;field<5;++field){auto b=w.bytes;for(unsigned i=0;i<4;++i)b[field*4+i]=0;bool rejected=false;try{viewflow::quality::unpack(b);}catch(...){rejected=true;}assert(rejected);}
    auto b=w.bytes;b.push_back(0);bool rejected=false;try{viewflow::quality::unpack(b);}catch(...){rejected=true;}assert(rejected);
    assert(viewflow::quality::bitrate_bps(80000,24000)==24000000);
    assert(viewflow::quality::bitrate_bps(1200,24000)==1200000);
    assert(viewflow::quality::mac_ceiling_kbps(640,480,60)==24000);
    assert(viewflow::quality::mac_ceiling_kbps(3840,2160,60)==62208);
    assert(viewflow::quality::mac_ceiling_kbps(7680,4320,60)==80000);
}

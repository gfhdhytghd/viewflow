// SPDX-License-Identifier: GPL-3.0-only
// Derived from HyprCapture caa7657c5f13b5828f984357f7686c98375f2949; see ../NOTICE.
#include "window_gpu_wire.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>

using namespace viewflow_capture::gpuwire;

static Frame frame() {
    Frame f{}; f.sequence=9; f.captureMonotonicNs=1234; f.geometryEpoch=7; f.logicalX=-2.5; f.logicalY=3.25; f.logicalWidth=800; f.logicalHeight=600;
    f.imageWidth=1600; f.imageHeight=1200; f.stride=6400; f.modifier=0x3000; f.offset=64; f.cropX=4; f.cropY=8; f.cropWidth=1592; f.cropHeight=1184; f.flipY=true;
    f.shadowEnabled=true; f.shadow={1,2,800,600,8,9,784,584,24,12,10,2,3,{1,2,3,4},true}; return f;
}
int main(){
    std::array<std::uint8_t,HCGF_BYTES> wire{}; Error e{}; auto f=frame(); assert(encode(f,wire,&e)); assert(std::memcmp(wire.data(),"HCGF",4)==0); assert(wire[5]==1); assert(wire[6]==0&&wire[7]==232); assert(wire[72]==0x34&&wire[73]==0x32&&wire[74]==0x42&&wire[75]==0x41); assert(wire[216+3]==3); assert(wire[220]==1&&wire[223]==4); assert(wire[224+3]==1);
    Frame round{}; assert(decode(wire.data(),wire.size(),round,&e)); assert(round.sequence==f.sequence&&round.shadow.rgba==f.shadow.rgba&&round.shadow.sharp);
    for(std::size_t at=120;at<232;++at){auto bad=wire; bad[112]=1; bad[at]=1; Frame out{}; assert(!decode(bad.data(),bad.size(),out,&e));}
    auto disabled=f; disabled.shadowEnabled=false; disabled.shadow={}; assert(encode(disabled,wire,&e)); assert(std::memcmp(wire.data()+120,std::array<std::uint8_t,112>{}.data(),112)==0); assert(decode(wire.data(),wire.size(),round,&e));
    assert(!decode(wire.data(),231,round,&e)); auto extra=wire; assert(!decode(extra.data(),233,round,&e)); auto bad=wire; bad[112]=8; assert(!decode(bad.data(),bad.size(),round,&e)); bad=wire; bad[116]=1; assert(!decode(bad.data(),bad.size(),round,&e));
    auto enabled=f; enabled.logicalX=__builtin_nan("x"); assert(!encode(enabled,wire,&e)); enabled=f; enabled.cropX=0xffffffffU; assert(!encode(enabled,wire,&e)); enabled=f; enabled.imageHeight=0x80000000U; assert(!encode(enabled,wire,&e));
    std::array<std::uint8_t,HCGR_BYTES> release{}; Release r{9,7},r2{}; assert(encode(r,release,&e)); assert(std::memcmp(release.data(),"HCGR",4)==0&&release[7]==32); assert(decode(release.data(),release.size(),r2,&e)&&r2.sequence==9&&r2.geometryEpoch==7); release[24]=1; assert(!decode(release.data(),release.size(),r2,&e));
    std::puts("PASS window GPU HCGF/HCGR wire golden and strict mutations");
}

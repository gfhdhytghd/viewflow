// SPDX-License-Identifier: GPL-3.0-only
// Derived from HyprCapture caa7657c5f13b5828f984357f7686c98375f2949; see ../NOTICE.
#include "window_gpu_wire.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace viewflow_capture::gpuwire {
namespace {
constexpr std::uint32_t PREMULT = 1, FLIP = 2, SHADOW = 4, KNOWN = 7;
void err(Error* out, Error value) { if (out) *out = value; }
void u32(std::uint8_t* p, std::uint32_t v) { p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v; }
void u16(std::uint8_t* p, std::uint16_t v) { p[0]=v>>8; p[1]=v; }
void u64(std::uint8_t* p, std::uint64_t v) { for (int i=7;i>=0;--i) { p[i]=static_cast<std::uint8_t>(v); v>>=8; } }
void f64(std::uint8_t* p, double v) { std::uint64_t bits; std::memcpy(&bits,&v,8); u64(p,bits); }
std::uint32_t r32(const std::uint8_t* p) { return (std::uint32_t(p[0])<<24)|(std::uint32_t(p[1])<<16)|(std::uint32_t(p[2])<<8)|p[3]; }
std::uint16_t r16(const std::uint8_t* p) { return std::uint16_t(p[0]<<8|p[1]); }
std::uint64_t r64(const std::uint8_t* p) { std::uint64_t v=0; for(int i=0;i<8;++i)v=(v<<8)|p[i]; return v; }
double rf64(const std::uint8_t* p) { const auto bits=r64(p); double v; std::memcpy(&v,&bits,8); return v; }
bool finite(double v) { return std::isfinite(v); }
bool valid(const Frame& f, Error* e) {
    if (!f.sequence || !f.captureMonotonicNs || !f.geometryEpoch) { err(e,Error::ZeroLineage); return false; }
    if (!finite(f.logicalX)||!finite(f.logicalY)||!finite(f.logicalWidth)||!finite(f.logicalHeight)) { err(e,Error::NonFinite); return false; }
    if (f.logicalWidth<=0||f.logicalHeight<=0||!f.imageWidth||!f.imageHeight||f.imageWidth>INT32_MAX||f.imageHeight>INT32_MAX) { err(e,Error::Geometry); return false; }
    if (f.fourcc!=HCGF_ABGR8888) { err(e,Error::Format); return false; }
    if (f.imageWidth > UINT32_MAX/4 || f.stride < f.imageWidth*4 || f.stride > INT32_MAX) { err(e,Error::Stride); return false; }
    if (f.offset > INT32_MAX) { err(e,Error::Offset); return false; }
    if (!f.cropWidth || !f.cropHeight || f.cropX > f.imageWidth-f.cropWidth || f.cropY > f.imageHeight-f.cropHeight) { err(e,Error::Crop); return false; }
    if (!f.shadowEnabled) return true;
    const Shadow& s=f.shadow;
    for(double v:{s.left,s.top,s.width,s.height,s.cutoutLeft,s.cutoutTop,s.cutoutWidth,s.cutoutHeight,s.range,s.rounding,s.windowRounding,s.roundingPower}) if(!finite(v)){err(e,Error::Shadow);return false;}
    if(s.width<=0||s.height<=0||s.cutoutWidth<=0||s.cutoutHeight<=0||s.range<=0||s.rounding<0||s.windowRounding<0||s.roundingPower<1||s.roundingPower>10||s.power<1||s.power>4){err(e,Error::Shadow);return false;}
    return true;
}
}

bool encode(const Frame& f, std::array<std::uint8_t,HCGF_BYTES>& out, Error* e) {
    if (!valid(f, e))
        return false;
    out.fill(0); std::memcpy(out.data(), "HCGF", 4); u16(out.data()+4, 1); u16(out.data()+6, HCGF_BYTES);
    u64(out.data()+8,f.sequence);u64(out.data()+16,f.captureMonotonicNs);u64(out.data()+24,f.geometryEpoch);
    for(auto [at,v]:{std::pair{32,f.logicalX},std::pair{40,f.logicalY},std::pair{48,f.logicalWidth},std::pair{56,f.logicalHeight}})f64(out.data()+at,v);
    u32(out.data()+64,f.imageWidth);u32(out.data()+68,f.imageHeight);u32(out.data()+72,f.fourcc);u32(out.data()+76,f.stride);u64(out.data()+80,f.modifier);u64(out.data()+88,f.offset);
    u32(out.data()+96,f.cropX);u32(out.data()+100,f.cropY);u32(out.data()+104,f.cropWidth);u32(out.data()+108,f.cropHeight);u32(out.data()+112,PREMULT|(f.flipY?FLIP:0)|(f.shadowEnabled?SHADOW:0));
    if(f.shadowEnabled){const auto&s=f.shadow;for(auto [at,v]:{std::pair{120,s.left},std::pair{128,s.top},std::pair{136,s.width},std::pair{144,s.height},std::pair{152,s.cutoutLeft},std::pair{160,s.cutoutTop},std::pair{168,s.cutoutWidth},std::pair{176,s.cutoutHeight},std::pair{184,s.range},std::pair{192,s.rounding},std::pair{200,s.windowRounding},std::pair{208,s.roundingPower}})f64(out.data()+at,v);u32(out.data()+216,s.power);std::copy(s.rgba.begin(),s.rgba.end(),out.begin()+220);u32(out.data()+224,s.sharp?1:0);} return true;
}

bool decode(const std::uint8_t* b,std::size_t n,Frame& f,Error* e){if(n!=HCGF_BYTES){err(e,Error::Length);return false;}if(std::memcmp(b,"HCGF",4)){err(e,Error::Magic);return false;}if(r16(b+4)!=1){err(e,Error::Version);return false;}if(r16(b+6)!=HCGF_BYTES){err(e,Error::HeaderLength);return false;}if(r32(b+112)&~KNOWN||!(r32(b+112)&PREMULT)){err(e,Error::Flags);return false;}if(r32(b+116)||r32(b+228)){err(e,Error::Reserved);return false;}const bool enabled=r32(b+112)&SHADOW;if(!enabled){for(std::size_t i=120;i<232;++i)if(b[i]){err(e,Error::Shadow);return false;}}f={};f.sequence=r64(b+8);f.captureMonotonicNs=r64(b+16);f.geometryEpoch=r64(b+24);f.logicalX=rf64(b+32);f.logicalY=rf64(b+40);f.logicalWidth=rf64(b+48);f.logicalHeight=rf64(b+56);f.imageWidth=r32(b+64);f.imageHeight=r32(b+68);f.fourcc=r32(b+72);f.stride=r32(b+76);f.modifier=r64(b+80);f.offset=r64(b+88);f.cropX=r32(b+96);f.cropY=r32(b+100);f.cropWidth=r32(b+104);f.cropHeight=r32(b+108);f.flipY=r32(b+112)&FLIP;f.shadowEnabled=enabled;if(enabled){auto&s=f.shadow;s.left=rf64(b+120);s.top=rf64(b+128);s.width=rf64(b+136);s.height=rf64(b+144);s.cutoutLeft=rf64(b+152);s.cutoutTop=rf64(b+160);s.cutoutWidth=rf64(b+168);s.cutoutHeight=rf64(b+176);s.range=rf64(b+184);s.rounding=rf64(b+192);s.windowRounding=rf64(b+200);s.roundingPower=rf64(b+208);s.power=r32(b+216);std::copy(b+220,b+224,s.rgba.begin());if(r32(b+224)>1){err(e,Error::Shadow);return false;}s.sharp=r32(b+224); } return valid(f,e);}

bool encode(const Release& r,std::array<std::uint8_t,HCGR_BYTES>& out,Error*e){if(!r.sequence||!r.geometryEpoch){err(e,Error::ZeroLineage);return false;}out.fill(0);std::memcpy(out.data(),"HCGR",4);u16(out.data()+4,1);u16(out.data()+6,HCGR_BYTES);u64(out.data()+8,r.sequence);u64(out.data()+16,r.geometryEpoch);return true;}
bool decode(const std::uint8_t*b,std::size_t n,Release&r,Error*e){if(n!=HCGR_BYTES){err(e,Error::Length);return false;}if(std::memcmp(b,"HCGR",4)){err(e,Error::Magic);return false;}if(r16(b+4)!=1){err(e,Error::Version);return false;}if(r16(b+6)!=HCGR_BYTES){err(e,Error::HeaderLength);return false;}if(r32(b+24)||r64(b+8)==0||r64(b+16)==0){err(e,r32(b+24)?Error::Reserved:Error::ZeroLineage);return false;}r={r64(b+8),r64(b+16)};return true;}
} // namespace viewflow_capture::gpuwire

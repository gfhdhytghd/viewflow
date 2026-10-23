#pragma once
#include <array>
#include <cstdint>
#include <optional>
#include <span>
namespace viewflow::reverse::fixture_stamp {
// Diagnostic pixels only: premultiplied alpha=1/255, no input-region effect.
// Redundant channels detect changes; checksum rejects mixed frame identities.
constexpr unsigned width=192;
struct Stamp {std::uint64_t sequence,qpc100ns;};
inline std::uint32_t checksum(Stamp s) {
    std::uint32_t h=2166136261u;
    for(auto v:{s.sequence,s.qpc100ns})for(unsigned i=0;i<8;++i){h^=std::uint8_t(v>>(8*i));h*=16777619u;}
    return h;
}
inline std::array<std::uint8_t,width*4> encode(Stamp s) {
    const std::array<std::uint64_t,3> words{0x56465354ull|(std::uint64_t(checksum(s))<<32),s.sequence,s.qpc100ns};
    std::array<std::uint8_t,width*4> pixels{};
    for(unsigned x=0;x<width;++x){const auto b=(words[x/64]>>(x%64))&1;pixels[x*4]=b;pixels[x*4+1]=1-b;pixels[x*4+2]=b;pixels[x*4+3]=1;}
    return pixels;
}
inline std::optional<Stamp> decode(std::span<const std::uint8_t> pixels) {
    if(pixels.size()<width*4)return {};
    std::array<std::uint64_t,3> words{};
    for(unsigned x=0;x<width;++x){const auto* p=pixels.data()+x*4;if(p[0]>1 || p[1]!=1-p[0] || p[2]!=p[0] || p[3]!=1)return {};words[x/64]|=std::uint64_t(p[0])<<(x%64);}
    Stamp s{words[1],words[2]};
    if(std::uint32_t(words[0])!=0x56465354u || std::uint32_t(words[0]>>32)!=checksum(s))return {};
    return s;
}
}

#pragma once
#include "wire.hpp"
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <chrono>

namespace viewflow::quality {
// Local child pipe only. Tag 7, version 1, five little-endian u32 fields.
struct Target { unsigned kbps{}, max_fps{60}, scale_permille{1000}; };
inline Target unpack(std::span<const std::uint8_t> bytes) {
    if(bytes.size()!=20)throw std::runtime_error("quality record size");
    reverse::Reader r{bytes};
    if(r.u32()!=7 || r.u32()!=1)throw std::runtime_error("quality record version");
    Target t{r.u32(),r.u32(),r.u32()};
    if(!t.kbps || t.kbps>80000 || !t.max_fps || t.max_fps>240 || !t.scale_permille || t.scale_permille>1000)
        throw std::runtime_error("quality record range");
    return t;
}
inline unsigned bitrate_bps(unsigned kbps,unsigned ceiling_kbps) {
    return std::clamp(kbps,1u,ceiling_kbps)*1000u;
}
inline unsigned mac_ceiling_kbps(unsigned width,unsigned height,unsigned fps) {
    return static_cast<unsigned>(std::clamp(std::uint64_t(width)*height*fps/8, std::uint64_t(24000000),std::uint64_t(80000000))/1000);
}
// Atomics avoid adding a lock to the capture/encode path. Resolution scaling
// is carried for forward compatibility but deliberately not applied yet.
struct State {
    std::atomic<unsigned> kbps{0}, fps{240};
    unsigned last_kbps{}, last_fps{}, last_scale{};
    std::chrono::steady_clock::time_point report{};
    void accept(Target t) {
        kbps.store(t.kbps);fps.store(t.max_fps);
        const auto now=std::chrono::steady_clock::now();
        const bool changed=t.kbps!=last_kbps || t.max_fps!=last_fps || t.scale_permille!=last_scale;
        if(changed) {
            std::fprintf(stderr,"native-quality %s kbps=%u max_fps=%u scale_permille=%u scale_applied=0\n","target",t.kbps,t.max_fps,t.scale_permille);
            last_kbps=t.kbps;last_fps=t.max_fps;last_scale=t.scale_permille;
        }
        if(now-report>=std::chrono::seconds(5)) {
            std::fprintf(stderr,"native-quality summary kbps=%u max_fps=%u scale_permille=%u scale_applied=0\n",t.kbps,t.max_fps,t.scale_permille);
            report=now;
        }
    }
};
}

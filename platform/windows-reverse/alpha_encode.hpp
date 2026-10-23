#pragma once
#include "../reverse-common/wire.hpp"
#include <cstring>
namespace viewflow::reverse {
inline std::vector<std::uint8_t> encode_windows_opaque_alpha(std::size_t pixels) {
    if(!pixels || pixels>max_pixels)throw std::runtime_error("invalid alpha plane");
    // Match the shared codec's raw fallback for planes smaller than one run.
    if(pixels<6){std::vector<std::uint8_t> bytes(pixels+1,255);bytes[0]=0;return bytes;}
    Writer w;w.bytes.reserve(6);w.bytes.push_back(1);
    w.u32(static_cast<std::uint32_t>(pixels));w.bytes.push_back(255);
    return std::move(w.bytes);
}
inline std::vector<std::uint8_t> encode_windows_alpha(std::span<const std::uint8_t> alpha) {
    if(alpha.empty() || alpha.size()>max_pixels)throw std::runtime_error("invalid alpha plane");
    Writer w;w.bytes.push_back(1);
    unsigned recent_runs=0;std::size_t recent_bytes=0;
    for(std::size_t start=0;start<alpha.size();) {
        auto end=start+1;const auto value=alpha[start];
        const std::uint64_t repeated=std::uint64_t(value)*0x0101010101010101ULL;
        while(alpha.size()-end>=sizeof(repeated)){
            std::uint64_t word{};std::memcpy(&word,alpha.data()+end,sizeof(word));
            if(word!=repeated)break;
            end+=sizeof(word);
        }
        while(end<alpha.size() && alpha[end]==value)++end;
        recent_bytes+=end-start;++recent_runs;
        w.u32(static_cast<std::uint32_t>(end-start));w.bytes.push_back(value);start=end;
        if(w.bytes.size()>alpha.size()){w.bytes.assign(1,0);w.bytes.insert(w.bytes.end(),alpha.begin(),alpha.end());break;}
        // Keep the original encoder for dense changes; free partial output
        // before retrying so fallback does not retain two large allocations.
        if(recent_runs==32){if(recent_bytes<256){std::vector<std::uint8_t>{}.swap(w.bytes);return encode_alpha(alpha);}recent_runs=0;recent_bytes=0;}
    }
    return std::move(w.bytes);
}
}

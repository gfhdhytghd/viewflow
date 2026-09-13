#pragma once
#include "wire.hpp"
namespace viewflow::reverse {
inline constexpr uint32_t backdrop_capability = 128;
inline constexpr uint32_t max_backdrop_record = 64u * 1024u * 1024u;
struct Backdrop {
    uint64_t id{}, sequence{};
    // Native source logical coordinates, fixed-point millipoints.
    int32_t x{}, y{}, width{}, height{};
    uint32_t pixel_width{}, pixel_height{};
    std::vector<uint8_t> png;
};
inline void validate(const Backdrop& b) {
    if (!b.id || !b.sequence || b.width <= 0 || b.height <= 0 ||
        !b.pixel_width || !b.pixel_height || b.pixel_width > 8192 || b.pixel_height > 8192 || uint64_t(b.pixel_width) * b.pixel_height > 32u * 1024u * 1024u ||
        b.png.empty() || b.png.size() > max_backdrop_record - 52)
        throw std::runtime_error("invalid popup backdrop");
}
inline std::vector<uint8_t> pack_backdrop(const Backdrop& b) {
    validate(b); Writer w; w.u32(3); w.u64(b.id); w.u64(b.sequence);
    w.i32(b.x); w.i32(b.y); w.i32(b.width); w.i32(b.height);
    w.u32(b.pixel_width); w.u32(b.pixel_height); w.blob(b.png); return std::move(w.bytes);
}
inline Backdrop unpack_backdrop(std::span<const uint8_t> bytes) {
    if (bytes.size() > max_backdrop_record) throw std::runtime_error("popup backdrop too large");
    Reader r{bytes}; if (r.u32() != 3) throw std::runtime_error("unexpected backdrop record");
    Backdrop b; b.id=r.u64(); b.sequence=r.u64(); b.x=r.i32(); b.y=r.i32(); b.width=r.i32(); b.height=r.i32();
    b.pixel_width=r.u32(); b.pixel_height=r.u32(); auto png=r.blob(max_backdrop_record - 52); b.png.assign(png.begin(),png.end());
    r.finish(); validate(b); return b;
}
}

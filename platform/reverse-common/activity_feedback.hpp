#pragma once
#include "wire.hpp"
namespace viewflow::activity {
struct Feedback {
    unsigned lane{};
    bool keyframe{},saturated{},single_lane{};
    std::uint64_t queue_us{};
    unsigned stage{}; // 0 sender, 1 decoder, 2 presentation.
};
inline std::vector<std::uint8_t> pack_feedback(const Feedback& value) {
    if(value.lane>1)throw std::runtime_error("activity feedback lane");
    reverse::Writer writer;writer.u32(5);writer.u32(value.lane);
    writer.u32(unsigned(value.keyframe)|(unsigned(value.saturated)<<1)|(unsigned(value.single_lane)<<2));
    writer.u32(value.stage);writer.u64(value.queue_us);return std::move(writer.bytes);
}
inline Feedback unpack_feedback(std::span<const std::uint8_t> bytes) {
    if(bytes.size()!=24)throw std::runtime_error("activity feedback size");
    reverse::Reader reader{bytes};if(reader.u32()!=5)throw std::runtime_error("activity feedback tag");
    Feedback result;result.lane=reader.u32();const auto flags=reader.u32(),reserved=reader.u32();result.queue_us=reader.u64();
    if(result.lane>1 || flags>7 || reserved>2)throw std::runtime_error("activity feedback header");
    result.stage=reserved;result.keyframe=flags&1;result.saturated=flags&2;result.single_lane=flags&4;return result;
}
}

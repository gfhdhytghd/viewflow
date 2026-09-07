#pragma once
#include <span>
#include <vector>
#include <cstdint>
#include <stdexcept>

namespace viewflow::reverse {
// Access units in the shared window channel use Annex B. VideoToolbox uses
// four-byte big-endian lengths; parameter sets remain attached to each IDR.
inline std::vector<std::span<const std::uint8_t>> annex_b_units(std::span<const std::uint8_t> bytes) {
    const auto prefix = [&](std::size_t at) -> std::size_t {
        if (at + 3 <= bytes.size() && bytes[at] == 0 && bytes[at + 1] == 0) {
            if (bytes[at + 2] == 1) return 3;
            if (at + 4 <= bytes.size() && bytes[at + 2] == 0 && bytes[at + 3] == 1) return 4;
        }
        return 0;
    };
    std::vector<std::span<const std::uint8_t>> result;
    std::size_t at = 0;
    // Annex B permits leading_zero_8bits before the first start code.
    while (at < bytes.size() && !prefix(at) && bytes[at] == 0) ++at;
    if (!prefix(at)) throw std::runtime_error("missing Annex B start code");
    while (at < bytes.size()) {
        const auto start = at + prefix(at);
        auto end = start;
        while (end < bytes.size() && !prefix(end)) ++end;
        auto payload_end = end;
        while (payload_end > start && bytes[payload_end - 1] == 0) --payload_end;
        if (payload_end == start) throw std::runtime_error("empty Annex B NAL unit");
        result.push_back(bytes.subspan(start, payload_end - start));
        if (result.size() > 4096) throw std::runtime_error("too many NAL units");
        at = end;
    }
    return result;
}
inline void append_annex_b(std::vector<std::uint8_t>& out, std::span<const std::uint8_t> unit) {
    out.insert(out.end(), {0, 0, 0, 1});
    out.insert(out.end(), unit.begin(), unit.end());
}
inline std::vector<std::uint8_t> length_prefixed_to_annex_b(std::span<const std::uint8_t> bytes, unsigned length_size) {
    if (length_size < 1 || length_size > 4) throw std::runtime_error("invalid NAL length size");
    std::vector<std::uint8_t> result;
    while (!bytes.empty()) {
        if (bytes.size() < length_size) throw std::runtime_error("truncated NAL length");
        std::uint32_t count = 0;
        for (unsigned i = 0; i < length_size; ++i) count = (count << 8) | bytes[i];
        bytes = bytes.subspan(length_size);
        if (!count || count > bytes.size()) throw std::runtime_error("invalid NAL payload length");
        append_annex_b(result, bytes.first(count));
        bytes = bytes.subspan(count);
    }
    return result;
}
}

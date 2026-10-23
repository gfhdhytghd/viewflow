#pragma once
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <algorithm>
namespace viewflow::reverse {
// Each command's footprint is tightly packed; destination byte offsets remain
// identical to the old contiguous BGRA image, even when a segment bisects a row.
struct SegmentedBgraCopy {
    unsigned segment, source_x, source_y, width, height, row_pitch;
    std::uint64_t destination_offset, bytes;
};
inline std::vector<SegmentedBgraCopy> plan_segmented_bgra(unsigned width, unsigned height,
                                                        std::uint64_t segment_bytes = 64ull << 20) {
    const std::uint64_t row = std::uint64_t(width) * 4;
    // Tight SHM layout has no room for footprint padding. These conditions make
    // every row/segment intersection a valid 512-byte placed-footprint offset.
    if (!width || !height || width > 16384 || height > 16384 || row % 512 ||
        !segment_bytes || segment_bytes % 512 || segment_bytes < row)
        throw std::invalid_argument("segmented BGRA tight footprint alignment/extent");
    std::vector<SegmentedBgraCopy> plan;
    const auto total = row * height;
    for (std::uint64_t start = 0; start < total; start += segment_bytes) {
        const auto end = std::min(total, start + segment_bytes);
        std::uint64_t cursor = start;
        const auto add = [&](std::uint64_t position, unsigned x, unsigned y, unsigned w, unsigned h) {
            const auto pitch = w * 4;
            plan.push_back({static_cast<unsigned>(start / segment_bytes), x, y, w, h, pitch,
                            position - start, std::uint64_t(pitch) * h});
        };
        if (cursor % row) {
            const auto part = std::min(end - cursor, row - cursor % row);
            add(cursor, static_cast<unsigned>((cursor % row) / 4), static_cast<unsigned>(cursor / row),
                static_cast<unsigned>(part / 4), 1);
            cursor += part;
        }
        const auto full_rows = (end - cursor) / row;
        if (full_rows) {
            add(cursor, 0, static_cast<unsigned>(cursor / row), width, static_cast<unsigned>(full_rows));
            cursor += full_rows * row;
        }
        if (cursor < end) add(cursor, 0, static_cast<unsigned>(cursor / row), static_cast<unsigned>((end - cursor) / 4), 1);
    }
    return plan;
}
} // namespace viewflow::reverse

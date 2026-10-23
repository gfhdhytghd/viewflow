// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>

namespace viewflow_capture {
// Align equal-rate streams to a common monotonic grid. Scheduling one period
// after each render lets independent streams drift by their rendering costs,
// forcing an atlas consumer to hold one window while waiting for another.
// Skip missed ticks; never request a zero-delay catch-up loop.
constexpr std::uint64_t captureTickDelayNs(std::uint64_t now, unsigned fps) noexcept {
    if (fps < 1 || fps > 1000) return 0;
    const auto period = 1000000000ULL / fps;
    return period - now % period;
}
}

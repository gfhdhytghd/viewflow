// SPDX-License-Identifier: GPL-3.0-only
#include "capture_cadence.hpp"
#include <cassert>
#include <initializer_list>
#include <limits>
using viewflow_capture::captureTickDelayNs;
int main() {
    assert(captureTickDelayNs(1, 0) == 0);
    assert(captureTickDelayNs(1, 1001) == 0);
    for (unsigned fps : {1U, 30U, 60U, 1000U}) {
        const auto period = 1000000000ULL / fps;
        const auto first = period * 10 + period / 8;
        const auto second = period * 10 + period / 2;
        assert(first + captureTickDelayNs(first, fps) == second + captureTickDelayNs(second, fps));
        assert(captureTickDelayNs(period * 10, fps) == period);
        assert(captureTickDelayNs(period * 100 + 1, fps) == period - 1);
        assert(captureTickDelayNs(std::numeric_limits<std::uint64_t>::max(), fps) > 0);
        assert(captureTickDelayNs(std::numeric_limits<std::uint64_t>::max(), fps) <= period);
    }
}

// SPDX-License-Identifier: GPL-3.0-only
#include "capture_commit_schedule.hpp"
#include <cassert>
#include <initializer_list>
#include <limits>
#include <vector>
using viewflow_capture::CaptureCommitSchedule;
int main() {
    assert(CaptureCommitSchedule(0).delay(10) == 0);
    assert(CaptureCommitSchedule(1001).delay(10) == 0);
    for (unsigned fps : {1U, 30U, 60U, 1000U}) {
        CaptureCommitSchedule s(fps);
        const std::uint64_t first = 123456789000ULL, period = s.period(), grace = s.grace();
        s.committed(first); assert(s.due(first)); s.attempted(first);
        // Idle fallback stays on its nominal grid despite a late timer.
        const auto firstFallback = first + period + grace;
        assert(s.deadline() == firstFallback);
        for (unsigned n = 0; n < 1000; ++n) {
            const auto expected = firstFallback + n * period;
            assert(s.deadline() == expected);
            s.attempted(expected + grace / 3);
        }
        // Resume establishes phase once; multiple notifications coalesce.
        const auto resumed = first + period * 2000;
        s.committed(resumed); assert(s.due(resumed)); s.attempted(resumed);
        s.committed(resumed + period - grace / 2);
        const auto deadline = s.deadline();
        for (unsigned n = 0; n < 8; ++n) s.committed(resumed + period - grace / 2);
        assert(s.deadline() == deadline);
        assert(s.due(resumed + period - grace / 2));
        s.attempted(resumed + period - grace / 2);
        // A long stall only schedules a future attempt.
        const auto stalled = resumed + period * 500;
        s.attempted(stalled); assert(!s.due(stalled));
        assert(s.deadline() == stalled + period + grace);
        s.attempted(std::numeric_limits<std::uint64_t>::max() - 1);
        assert(s.deadline() == std::numeric_limits<std::uint64_t>::max());
    }
    // 600 real-time commit intervals with bounded +/-0.35 ms jitter should
    // remain immediately eligible, including early commits after late ones.
    CaptureCommitSchedule s(60); const auto p = s.period();
    for (unsigned n = 0; n < 600; ++n) {
        const std::uint64_t now = 1000000000ULL + n * p + (n % 2 ? 350000 : 0);
        s.committed(now); assert(s.due(now)); s.attempted(now + 25000);
    }
}

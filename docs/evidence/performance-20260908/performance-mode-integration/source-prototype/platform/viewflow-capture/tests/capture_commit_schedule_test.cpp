// SPDX-License-Identifier: GPL-3.0-only
#include "capture_commit_schedule.hpp"
#include <cassert>
#include <initializer_list>
#include <limits>
using viewflow_capture::CaptureCommitSchedule;
int main() {
    assert(CaptureCommitSchedule(0).delay(10) == 0);
    assert(CaptureCommitSchedule(1001).delay(10) == 0);
    for (unsigned fps : {1U, 30U, 60U, 1000U}) {
        CaptureCommitSchedule s(fps);
        const std::uint64_t first = 123456789000ULL, period = s.period();
        s.committed(first); assert(s.due(first)); s.attempted(first);
        // Late idle timers do not cumulatively drift or burst to catch up.
        for (unsigned n = 1; n <= 1000; ++n) {
            const auto expected = first + s.fallbackGrace() + n * period;
            assert(s.deadline() == expected);
            s.attempted(expected + period / 10);
        }
        // A commit immediately after fallback is retained until the rate cap.
        const auto last = first + s.fallbackGrace() + 1000 * period + period / 10;
        s.committed(last + 1); assert(!s.due(last + 1));
        const auto eligible = last + s.minimumGap();
        for (unsigned n = 1; n <= 100; ++n) s.committed(last + n);
        assert(s.deadline() == eligible); // a hot producer cannot postpone it
        s.attempted(eligible); assert(!s.pending());
        // Long idle/resume and a long stalled timer never replay old attempts.
        const auto resumed = first + 2000 * period;
        s.committed(resumed); assert(s.due(resumed)); s.attempted(resumed);
        assert(s.deadline() == resumed + period + s.fallbackGrace());
        s.attempted(resumed + 500 * period);
        assert(s.deadline() == resumed + 501 * period + s.fallbackGrace());
        s.attempted(std::numeric_limits<std::uint64_t>::max() - 1);
        assert(s.deadline() == std::numeric_limits<std::uint64_t>::max());
    }
    // Early/late producer commits all remain eligible without a phase lock.
    CaptureCommitSchedule s(60); const auto p = s.period();
    for (unsigned n = 0; n < 600; ++n) {
        const std::uint64_t now = 1000000000ULL + n * p + (n % 2 ? p / 4 : 0);
        s.committed(now); assert(s.due(now)); s.attempted(now + 25000);
    }
    // Every ordinary jittered commit replaces fallback before it is due.
    CaptureCommitSchedule normal(60);
    for (unsigned n = 0; n < 600; ++n) {
        const std::uint64_t now = 3000000000ULL + n * p + (n % 2 ? p / 8 : 0);
        if (n) assert(!normal.due(now));
        normal.committed(now); assert(normal.due(now)); normal.attempted(now + 25000);
    }
    // At an excessive producer rate, notifications collapse to <= 2x fps.
    CaptureCommitSchedule flood(60); std::uint64_t attempts = 0, previous = 0;
    for (std::uint64_t now = 1000000000ULL; now < 2000000000ULL; now += 100000) {
        flood.committed(now);
        if (flood.due(now)) {
            if (attempts) assert(now - previous >= flood.minimumGap());
            previous = now; ++attempts; flood.attempted(now);
        }
    }
    assert(attempts >= 118 && attempts <= 121);
}

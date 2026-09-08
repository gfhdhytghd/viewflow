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
        CaptureCommitSchedule schedule(fps);
        const auto first = 123456789000ULL;
        schedule.attempted(first);
        const auto eligible = first + schedule.period();
        const auto fallback = eligible + schedule.grace();
        assert(schedule.deadline() == fallback);
        assert(!schedule.due(eligible));
        schedule.committed();
        assert(schedule.deadline() == eligible);
        assert(!schedule.due(eligible - 1));
        assert(schedule.due(eligible));
        // Many source commits before a tick coalesce into the same deadline.
        for (unsigned n = 0; n < 8; ++n) schedule.committed();
        assert(schedule.deadline() == eligible);
        schedule.attempted(eligible);
        assert(!schedule.pending());
        assert(schedule.deadline() == eligible + schedule.period() + schedule.grace());
        // A commit just after the rate budget gets immediate service instead
        // of waiting for the next fixed global capture grid point.
        schedule.committed();
        const auto late = eligible + schedule.period() + schedule.grace() / 2;
        assert(schedule.due(late) && schedule.delay(late) == 1);
        schedule.attempted(late);
        // Idle content still gets periodic attempts, even with no commits.
        assert(schedule.due(late + schedule.period() + schedule.grace()));
        const auto stalled = late + schedule.period() * 50;
        schedule.attempted(stalled);
        assert(!schedule.due(stalled));
        assert(schedule.delay(stalled) == schedule.period() + schedule.grace());
        schedule.attempted(std::numeric_limits<std::uint64_t>::max() - 1);
        assert(schedule.deadline() == std::numeric_limits<std::uint64_t>::max());
    }
}

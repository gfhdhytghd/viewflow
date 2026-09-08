// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <cstdint>
#include <limits>

namespace viewflow_capture {
// Experimental cohort pacing. Nominal deadlines advance from the schedule,
// not from delayed timer execution. A commit may borrow up to 1 ms of phase;
// its timing gently corrects the nominal phase. No catch-up work is queued.
// These are pacing choices, never admission or connection-expiry rules.
class CaptureCommitSchedule {
  public:
    explicit constexpr CaptureCommitSchedule(unsigned fps)
        : period_(fps >= 1 && fps <= 1000 ? 1000000000ULL / fps : 0),
          grace_(std::min<std::uint64_t>(1000000, period_ / 8)) {}

    constexpr void committed(std::uint64_t now) noexcept {
        // First activity and resumption after idle can establish a fresh phase.
        // The existing renderer still owns pending-frame/HCGR backpressure.
        if (!seenCommit_ || (now >= lastCommit_ && now - lastCommit_ > add(period_, period_)))
            nominal_ = now;
        pending_ = seenCommit_ = true;
        lastCommit_ = now;
    }
    [[nodiscard]] constexpr bool pending() const noexcept { return pending_; }
    [[nodiscard]] constexpr std::uint64_t period() const noexcept { return period_; }
    [[nodiscard]] constexpr std::uint64_t grace() const noexcept { return grace_; }
    [[nodiscard]] constexpr std::uint64_t deadline() const noexcept {
        return pending_ ? subtract(nominal_, grace_) : add(nominal_, grace_);
    }
    [[nodiscard]] constexpr bool due(std::uint64_t now) const noexcept {
        return period_ && now >= deadline();
    }
    [[nodiscard]] constexpr std::uint64_t delay(std::uint64_t now) const noexcept {
        if (!period_) return 0;
        return deadline() > now ? deadline() - now : 1;
    }
    constexpr void attempted(std::uint64_t now) noexcept {
        if (!started_ || now > add(nominal_, period_)) {
            nominal_ = add(now, period_);
        } else {
            // At most grace/8 correction per attempt, applied only to content
            // driven attempts; fallback lateness does not accumulate drift.
            auto phase = nominal_;
            if (pending_) {
                if (now > phase) phase = add(phase, std::min(now - phase, grace_) / 8);
                else phase = subtract(phase, std::min(phase - now, grace_) / 8);
            }
            nominal_ = add(phase, period_);
            // One future deadline after a stall; never replay obsolete slots.
            if (subtract(nominal_, grace_) <= now) nominal_ = add(now, period_);
        }
        pending_ = false;
        started_ = true;
    }
  private:
    static constexpr std::uint64_t add(std::uint64_t a, std::uint64_t b) noexcept {
        return a > std::numeric_limits<std::uint64_t>::max() - b
            ? std::numeric_limits<std::uint64_t>::max() : a + b;
    }
    static constexpr std::uint64_t subtract(std::uint64_t a, std::uint64_t b) noexcept {
        return a > b ? a - b : 0;
    }
    std::uint64_t period_, grace_, nominal_ = 0, lastCommit_ = 0;
    bool pending_ = false, seenCommit_ = false, started_ = false;
};
}

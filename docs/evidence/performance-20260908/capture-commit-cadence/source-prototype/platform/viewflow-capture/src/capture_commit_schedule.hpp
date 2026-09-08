// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <cstdint>
#include <limits>

namespace viewflow_capture {
// One schedule is shared by all streams of an equal frame rate. Commits may
// bring a capture forward to the rate budget; they never create catch-up work.
// A short grace period leaves room for a late application commit before the
// periodic fallback captures decorations/popups or otherwise idle content.
class CaptureCommitSchedule {
  public:
    explicit constexpr CaptureCommitSchedule(unsigned fps)
        : period_(fps >= 1 && fps <= 1000 ? 1000000000ULL / fps : 0),
          grace_(std::min<std::uint64_t>(1000000, period_ / 8)) {}

    constexpr void committed() noexcept { pending_ = true; }
    [[nodiscard]] constexpr bool pending() const noexcept { return pending_; }
    [[nodiscard]] constexpr std::uint64_t period() const noexcept { return period_; }
    [[nodiscard]] constexpr std::uint64_t grace() const noexcept { return grace_; }
    [[nodiscard]] constexpr std::uint64_t deadline() const noexcept {
        return pending_ ? eligible_ : add(eligible_, grace_);
    }
    [[nodiscard]] constexpr bool due(std::uint64_t now) const noexcept {
        return period_ && now >= deadline();
    }
    [[nodiscard]] constexpr std::uint64_t delay(std::uint64_t now) const noexcept {
        if (!period_) return 0;
        return deadline() > now ? deadline() - now : 1;
    }
    // Called at the start of a cohort attempt, so sequential render costs do
    // not cause separate windows' capture clocks to drift apart.
    constexpr void attempted(std::uint64_t now) noexcept {
        pending_ = false;
        eligible_ = add(now, period_);
    }
  private:
    static constexpr std::uint64_t add(std::uint64_t a, std::uint64_t b) noexcept {
        return a > std::numeric_limits<std::uint64_t>::max() - b
            ? std::numeric_limits<std::uint64_t>::max() : a + b;
    }
    std::uint64_t period_, grace_, eligible_ = 0;
    bool pending_ = false;
};
}

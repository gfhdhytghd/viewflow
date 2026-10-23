// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
#include <limits>

namespace viewflow_capture {
// Optional content-driven cohort: commit notifications schedule one
// deferred capture of the latest surface. There is no per-commit work queue.
// Allow early frames across the nominal rate boundary while limiting dense
// notifications to twice the requested rate. Idle fallback still covers
// popups/decoration changes that do not commit the main surface.
// After new content, defer the first static fallback by a quarter-period.
// This avoids racing an ordinary next commit whose arrival jitters around
// the period boundary; subsequent idle ticks retain the requested period.
// These deadlines only pace capture; they never expire a connection or input.
class CaptureCommitSchedule {
  public:
    explicit constexpr CaptureCommitSchedule(unsigned fps)
        : period_(fps >= 1 && fps <= 1000 ? 1000000000ULL / fps : 0),
          minimumGap_(period_ / 2), fallbackGrace_(period_ / 4) {}
    constexpr void committed(std::uint64_t now) noexcept {
        if (!pending_) {
            const auto earliest = started_ ? add(lastAttempt_, minimumGap_) : now;
            commitDeadline_ = now > earliest ? now : earliest;
        }
        pending_ = true;
    }
    [[nodiscard]] constexpr bool pending() const noexcept { return pending_; }
    [[nodiscard]] constexpr std::uint64_t period() const noexcept { return period_; }
    [[nodiscard]] constexpr std::uint64_t minimumGap() const noexcept { return minimumGap_; }
    [[nodiscard]] constexpr std::uint64_t fallbackGrace() const noexcept { return fallbackGrace_; }
    [[nodiscard]] constexpr std::uint64_t deadline() const noexcept {
        // A pending commit replaces an idle fallback, so they cannot create
        // adjacent attempts or an obsolete static capture ahead of new content.
        return pending_ ? commitDeadline_ : fallbackDeadline_;
    }
    [[nodiscard]] constexpr bool due(std::uint64_t now) const noexcept {
        return period_ && now >= deadline();
    }
    [[nodiscard]] constexpr std::uint64_t delay(std::uint64_t now) const noexcept {
        if (!period_) return 0;
        return deadline() > now ? deadline() - now : 1;
    }
    constexpr void attempted(std::uint64_t now) noexcept {
        if (!started_ || pending_ || now >= add(fallbackDeadline_, period_))
            fallbackDeadline_ = add(now, add(period_, fallbackGrace_));
        else
            fallbackDeadline_ = add(fallbackDeadline_, period_);
        lastAttempt_ = now;
        started_ = true;
        pending_ = false;
    }
  private:
    static constexpr std::uint64_t add(std::uint64_t a, std::uint64_t b) noexcept {
        return a > std::numeric_limits<std::uint64_t>::max() - b
            ? std::numeric_limits<std::uint64_t>::max() : a + b;
    }
    std::uint64_t period_, minimumGap_, fallbackGrace_, lastAttempt_ = 0;
    std::uint64_t fallbackDeadline_ = 0, commitDeadline_ = 0;
    bool pending_ = false, started_ = false;
};
}

#pragma once

#include "qpc_deadline.h"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace viewflow::windows_preview {

// MSG.time/GetMessageTime use the GetTickCount clock. If a sampled tick is
// strictly older than a message's tick, the message was created AFTER that
// sample. QPC taken before that tick read is therefore a lower bound on the
// original creation time, not a dequeue-time replacement timestamp.
// Keep the most recent sample for each distinct tick; no polling timer needed.
class KeyboardClockBounds {
 public:
  static constexpr uint64_t budget_ns = 33'333'334;
  void reset() { size_ = 0; frequency_ = 0; last_after_ = 0; }
  void observe(uint64_t before, uint32_t tick, uint64_t after, uint64_t frequency) {
    if (before <= 1 || after < before || !frequency) { reset(); return; }
    if (frequency_ != frequency || (last_after_ && before < last_after_)) reset();
    if (size_ && uint32_t(tick - samples_[size_ - 1].tick) >= 0x80000000u) reset();
    frequency_ = frequency;
    last_after_ = after;
    Sample sample{tick, before - 1}; // Also charge the one-QPC-tick ordering ambiguity.
    if (size_ && samples_[size_ - 1].tick == tick) {
      samples_[size_ - 1] = sample;
      return;
    }
    if (size_ == samples_.size()) {
      for (size_t i = 1; i < size_; ++i) samples_[i - 1] = samples_[i];
      --size_;
    }
    samples_[size_++] = sample;
  }
  std::optional<uint64_t> deadline(uint32_t message_tick, uint32_t current_tick,
                                   uint64_t now, uint64_t frequency) const {
    // Reject future/ambiguous wrapping timestamps, stale observations and a
    // changed counter domain. Same-tick observations are NEVER evidence that
    // predates this message: the message may already have been queued then.
    if (!size_ || !now || frequency != frequency_ || now < last_after_ ||
        uint32_t(current_tick - message_tick) >= 0x80000000u) return std::nullopt;
    for (size_t i = size_; i-- > 0;) {
      const auto& sample = samples_[i];
      const auto delta = uint32_t(message_tick - sample.tick);
      if (!delta || delta >= 0x80000000u) continue;
      const auto result = qpc_deadline::deadline_from_sender_remaining(
          sample.before, now, frequency, budget_ns);
      if (result.status == qpc_deadline::Status::Ok) return result.deadline_ticks;
      // Earlier samples cannot improve an expired lower bound.
      return std::nullopt;
    }
    return std::nullopt;
  }
 private:
  struct Sample { uint32_t tick; uint64_t before; };
  std::array<Sample, 32> samples_{};
  size_t size_{};
  uint64_t frequency_{}, last_after_{};
};

} // namespace viewflow::windows_preview

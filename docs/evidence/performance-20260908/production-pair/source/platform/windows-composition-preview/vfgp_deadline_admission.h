#pragma once

#include <cstdint>
#include <optional>

#include "vfgp_parser.h"

namespace viewflow::windows_preview::vfgp_deadline {

enum class Status {
  Ok,
  Missing,
  InvalidLocalFrequency,
  FrequencyMismatch,
  Expired,
};

// This is deliberately pure: callers sample QPC themselves immediately before
// every admission point, so no check can accidentally refresh a VFGP v4
// absolute deadline. Decode-only v3 is outside live deadline admission.
constexpr Status admit_live(bool required, bool decode_only,
                            std::optional<viewflow::vfgp::DeadlineQpc> deadline,
                            std::uint64_t local_frequency,
                            std::uint64_t now_ticks) {
  if (decode_only || !required)
    return Status::Ok;
  if (!deadline)
    return Status::Missing;
  if (local_frequency == 0)
    return Status::InvalidLocalFrequency;
  if (deadline->frequency != local_frequency)
    return Status::FrequencyMismatch;
  if (deadline->deadline == 0 || now_ticks >= deadline->deadline)
    return Status::Expired;
  return Status::Ok;
}

}  // namespace viewflow::windows_preview::vfgp_deadline

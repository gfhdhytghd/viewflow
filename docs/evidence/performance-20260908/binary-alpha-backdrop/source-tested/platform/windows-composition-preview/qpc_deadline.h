#pragma once

#include <cstdint>
#include <limits>

namespace viewflow::windows_preview::qpc_deadline {

// This helper is intentionally only for a sender and receiver on the same
// Windows host: QPC ticks share a counter domain there. It is not a cross-host
// clock-sync or wall-clock conversion API.
constexpr std::uint64_t kNanosecondsPerSecond = 1'000'000'000ULL;

enum class Status {
  Ok,
  InvalidFrequency,
  ZeroBudget,
  Overflow,
  Expired,
};

struct ValueResult {
  Status status{Status::Overflow};
  std::uint64_t value{};
};

struct DeadlineResult {
  Status status{Status::Overflow};
  std::uint64_t deadline_ticks{};
  std::uint64_t budget_ticks{};
};

// A receiver must never gain budget due to a fractional QPC tick, so this is
// deliberately floor(remaining_ns * frequency / 1e9). Zero ticks is rejected.
constexpr ValueResult budget_ticks_from_remaining_ns(std::uint64_t remaining_ns,
                                                      std::uint64_t frequency) {
  if (frequency == 0)
    return {Status::InvalidFrequency, 0};
  if (remaining_ns == 0)
    return {Status::ZeroBudget, 0};
  if (remaining_ns > std::numeric_limits<std::uint64_t>::max() / frequency)
    return {Status::Overflow, 0};
  const std::uint64_t ticks = remaining_ns * frequency / kNanosecondsPerSecond;
  return ticks == 0 ? ValueResult{Status::ZeroBudget, 0}
                    : ValueResult{Status::Ok, ticks};
}

// The inverse duration is rounded up for diagnostics or pre-admission elapsed
// accounting: a fractional tick is never reported as less elapsed time.
constexpr ValueResult elapsed_ns_from_ticks_ceil(std::uint64_t ticks,
                                                  std::uint64_t frequency) {
  if (frequency == 0)
    return {Status::InvalidFrequency, 0};
  if (ticks == 0)
    return {Status::Ok, 0};
  if (ticks > std::numeric_limits<std::uint64_t>::max() / kNanosecondsPerSecond)
    return {Status::Overflow, 0};
  const std::uint64_t product = ticks * kNanosecondsPerSecond;
  return {Status::Ok, product / frequency + (product % frequency != 0)};
}

// `sender_ticks` is sampled by the sender when it serializes `remaining_ns`.
// Because QPC is a same-host absolute domain, transit time is charged by
// comparing the derived absolute deadline against `receiver_now_ticks`.
// Future VFGP live admission must call this before decode/presentation; a
// decode-only warmup must not use this as a route around live admission.
constexpr DeadlineResult deadline_from_sender_remaining(
    std::uint64_t sender_ticks, std::uint64_t receiver_now_ticks,
    std::uint64_t frequency, std::uint64_t remaining_ns) {
  const ValueResult budget = budget_ticks_from_remaining_ns(remaining_ns, frequency);
  if (budget.status != Status::Ok)
    return {budget.status, 0, 0};
  if (sender_ticks > std::numeric_limits<std::uint64_t>::max() - budget.value)
    return {Status::Overflow, 0, 0};
  const std::uint64_t deadline = sender_ticks + budget.value;
  if (receiver_now_ticks >= deadline)
    return {Status::Expired, deadline, budget.value};
  return {Status::Ok, deadline, budget.value};
}

}  // namespace viewflow::windows_preview::qpc_deadline

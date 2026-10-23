#include "qpc_deadline.h"

#include <cstdint>
#include <cstdio>
#include <limits>

namespace {
using namespace viewflow::windows_preview::qpc_deadline;

bool check(bool condition, const char* text) {
  if (!condition)
    std::fprintf(stderr, "FAIL %s\n", text);
  return condition;
}
}  // namespace

int main() {
  constexpr std::uint64_t frequency = 10'000'000;
  const auto budget = budget_ticks_from_remaining_ns(33'333'333, frequency);
  if (!check(budget.status == Status::Ok && budget.value == 333'333,
             "budget conversion floors fractional QPC ticks"))
    return 1;
  const auto deadline = deadline_from_sender_remaining(1'000, 334'332, frequency,
                                                       33'333'333);
  if (!check(deadline.status == Status::Ok && deadline.deadline_ticks == 334'333 &&
                 deadline.budget_ticks == 333'333,
             "same-host sender QPC produces an absolute receiver deadline"))
    return 1;
  if (!check(deadline_from_sender_remaining(1'000, 334'333, frequency, 33'333'333).status ==
                 Status::Expired &&
                 deadline_from_sender_remaining(1'000, 400'000, frequency, 33'333'333).status ==
                     Status::Expired,
             "now equal to or beyond deadline is rejected"))
    return 1;
  if (!check(budget_ticks_from_remaining_ns(0, frequency).status == Status::ZeroBudget &&
                 budget_ticks_from_remaining_ns(1, frequency).status == Status::ZeroBudget &&
                 budget_ticks_from_remaining_ns(1, 0).status == Status::InvalidFrequency,
             "zero and sub-tick budgets are rejected"))
    return 1;
  if (!check(elapsed_ns_from_ticks_ceil(1, 3).status == Status::Ok &&
                 elapsed_ns_from_ticks_ceil(1, 3).value == 333'333'334,
             "elapsed conversion ceils fractional nanoseconds"))
    return 1;
  if (!check(budget_ticks_from_remaining_ns(std::numeric_limits<std::uint64_t>::max(), 2).status ==
                 Status::Overflow &&
                 elapsed_ns_from_ticks_ceil(std::numeric_limits<std::uint64_t>::max(), 1).status ==
                     Status::Overflow &&
                 deadline_from_sender_remaining(std::numeric_limits<std::uint64_t>::max(), 0,
                                                frequency, 100).status == Status::Overflow,
             "conversion and absolute-deadline overflow are rejected"))
    return 1;
  std::puts("PASS same-host QPC deadline conversion");
  return 0;
}

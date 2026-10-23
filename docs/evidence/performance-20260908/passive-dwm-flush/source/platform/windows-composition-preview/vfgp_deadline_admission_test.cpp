#include "vfgp_deadline_admission.h"

#include <cstdio>

namespace {
using viewflow::vfgp::DeadlineQpc;
using viewflow::windows_preview::vfgp_deadline::Status;
using viewflow::windows_preview::vfgp_deadline::admit_live;

bool check(bool condition, const char* text) {
  if (!condition)
    std::fprintf(stderr, "FAIL %s\n", text);
  return condition;
}
}  // namespace

int main() {
  constexpr auto frequency = 10'000'000ULL;
  const DeadlineQpc future{101, frequency};
  if (!check(admit_live(false, false, std::nullopt, frequency, 1) == Status::Ok,
             "default mode retains v2 behavior") ||
      !check(admit_live(true, true, std::nullopt, frequency, 1) == Status::Ok,
             "decode-only v3 needs no v4 deadline") ||
      !check(admit_live(true, false, std::nullopt, frequency, 1) == Status::Missing,
             "required live v4 cannot fall back") ||
      !check(admit_live(true, false, future, 0, 1) == Status::InvalidLocalFrequency,
             "zero local frequency") ||
      !check(admit_live(true, false, DeadlineQpc{101, frequency + 1}, frequency, 1) ==
                 Status::FrequencyMismatch,
             "frequency must be exact") ||
      !check(admit_live(true, false, DeadlineQpc{0, frequency}, frequency, 1) ==
                 Status::Expired,
             "zero deadline") ||
      !check(admit_live(true, false, future, frequency, 100) == Status::Ok,
             "strictly future deadline") ||
      !check(admit_live(true, false, future, frequency, 101) == Status::Expired,
             "equal deadline expires") ||
      !check(admit_live(true, false, future, frequency, 102) == Status::Expired,
             "past deadline expires"))
    return 1;
  std::puts("PASS VFGP v4 deadline live admission");
  return 0;
}

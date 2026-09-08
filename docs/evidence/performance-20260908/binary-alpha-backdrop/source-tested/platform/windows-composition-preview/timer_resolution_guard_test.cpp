#include "timer_resolution_guard.h"

#include <cstdio>

namespace {
int begins = 0;
int ends = 0;

MMRESULT WINAPI begin_success(UINT period) {
  if (period != 1)
    return TIMERR_NOCANDO;
  ++begins;
  return TIMERR_NOERROR;
}
MMRESULT WINAPI begin_failure(UINT period) {
  if (period != 1)
    return TIMERR_NOERROR;
  ++begins;
  return TIMERR_NOCANDO;
}
MMRESULT WINAPI end(UINT period) {
  if (period != 1)
    return TIMERR_NOCANDO;
  ++ends;
  return TIMERR_NOERROR;
}
}  // namespace

bool check(bool condition, const char *message) {
  if (!condition)
    std::fprintf(stderr, "FAIL %s\n", message);
  return condition;
}

int return_after_acquiring() {
  viewflow::windows_preview::TimerResolutionGuard guard(begin_success, end);
  return guard.active() ? 0 : 1;
}

int main() {
  begins = ends = 0;
  {
    viewflow::windows_preview::TimerResolutionGuard guard(begin_success, end);
    if (!check(guard.active(), "successful request active") ||
        !check(guard.result() == TIMERR_NOERROR, "successful result") ||
        !check(begins == 1 && ends == 0, "successful request count"))
      return 1;
  }
  if (!check(begins == 1 && ends == 1, "successful release count"))
    return 1;

  {
    viewflow::windows_preview::TimerResolutionGuard guard(begin_failure, end);
    if (!check(!guard.active(), "failed request inactive") ||
        !check(guard.result() == TIMERR_NOCANDO, "failed result") ||
        !check(begins == 2 && ends == 1, "failed request count"))
      return 1;
  }
  if (!check(begins == 2 && ends == 1, "failed request has no release"))
    return 1;

  begins = ends = 0;
  if (!check(return_after_acquiring() == 0, "early return result") ||
      !check(begins == 1 && ends == 1, "early return releases request"))
    return 1;

  begins = ends = 0;
  try {
    viewflow::windows_preview::TimerResolutionGuard guard(begin_success, end);
    throw 1;
  } catch (int) {
  }
  if (!check(begins == 1 && ends == 1, "exception release count"))
    return 1;
  return 0;
}

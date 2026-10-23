#pragma once

#include <windows.h>
#include <mmsystem.h>

namespace viewflow::windows_preview {

// Modern Windows applies timeBeginPeriod requests per process. Keep the request
// owned by this presenter process and pair every successful begin with an end.
class TimerResolutionGuard {
 public:
  using PeriodFn = MMRESULT(WINAPI *)(UINT);

  explicit TimerResolutionGuard(PeriodFn begin = timeBeginPeriod,
                                PeriodFn end = timeEndPeriod)
      : end_(end), result_(begin(1)), active_(result_ == TIMERR_NOERROR) {}

  ~TimerResolutionGuard() {
    if (active_)
      end_(1);
  }

  TimerResolutionGuard(const TimerResolutionGuard &) = delete;
  TimerResolutionGuard &operator=(const TimerResolutionGuard &) = delete;

  [[nodiscard]] bool active() const { return active_; }
  [[nodiscard]] MMRESULT result() const { return result_; }

 private:
  PeriodFn end_;
  MMRESULT result_;
  bool active_;
};

}  // namespace viewflow::windows_preview

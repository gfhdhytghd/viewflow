#pragma once
#include "../platform/windows-composition-preview/timer_resolution_guard.h"
#include <cstdio>
#include <optional>

// The receiver's timer request does not belong to this observer process.
// Measure the actual wait behavior as well as the API's return value.
class ObserverTimer {
 public:
  ObserverTimer(bool requested, FILE* log) {
    if(requested)guard_.emplace();
    LARGE_INTEGER frequency{};QueryPerformanceFrequency(&frequency);
    HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr);
    std::fprintf(log,"observer-timer requested=%u active=%u result=%ld\n",unsigned(requested),
        unsigned(guard_ && guard_->active()),guard_?long(guard_->result()):-1L);
    if(!event){std::fprintf(log,"observer-timer-calibration error=%lu\n",GetLastError());return;}
    for(unsigned i=0;i<8;++i) {
      LARGE_INTEGER before{},after{};QueryPerformanceCounter(&before);
      const DWORD result=WaitForSingleObject(event,1);QueryPerformanceCounter(&after);
      std::fprintf(log,"observer-timer-wait sample=%u requested_ms=1 result=%lu elapsed_us=%lld\n",
          i,result,(after.QuadPart-before.QuadPart)*1000000/frequency.QuadPart);
    }
    CloseHandle(event);
  }
 private:
  std::optional<viewflow::windows_preview::TimerResolutionGuard> guard_;
};

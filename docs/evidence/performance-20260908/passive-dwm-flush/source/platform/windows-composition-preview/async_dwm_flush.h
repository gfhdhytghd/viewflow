#pragma once
#include <condition_variable>
#include <mutex>
#include <thread>
#include <string>
#include <utility>
#include <windows.h>
#include <dwmapi.h>

// Diagnostic only. Never wait for DWM from the presenter/input thread.
// One latest request replaces earlier requests while the worker is busy.
class AsyncDwmFlush {
 public:
  AsyncDwmFlush() {
    wchar_t value[2]{};
    enabled_ = GetEnvironmentVariableW(L"VIEWFLOW_ATLAS_ASYNC_DWM_FLUSH", value, 2)==1 && value[0]==L'1';
    if(enabled_) worker_=std::thread([this]{Run();});
  }
  ~AsyncDwmFlush(){Stop();}
  void Stop() {
    if(!worker_.joinable())return;
    {std::lock_guard lock(mutex_);stop_=true;}
    changed_.notify_one();worker_.join();
  }
  void Request(uint64_t frame, uint64_t committed) {
    if(!enabled_)return;
    {std::lock_guard lock(mutex_);
      if(pending_)++coalesced_;
      frame_=frame;committed_=committed;pending_=true;++requested_;
    }
    changed_.notify_one();
  }
  std::string TakeLog() {
    std::lock_guard lock(mutex_);
    return std::exchange(log_,{});
  }
  std::string Summary() {
    std::lock_guard lock(mutex_);
    return "atlas-dwm-flush-summary enabled="+std::to_string(enabled_)+
      " requested="+std::to_string(requested_)+" completed="+std::to_string(completed_)+
      " coalesced="+std::to_string(coalesced_)+" abandoned="+std::to_string(pending_)+"\n";
  }
 private:
  void Run() {
    for(;;) {
      uint64_t frame,committed;
      {std::unique_lock lock(mutex_);changed_.wait(lock,[this]{return stop_||pending_;});
        if(stop_)return;
        frame=frame_;committed=committed_;pending_=false;
      }
      LARGE_INTEGER begin{},end{};
      QueryPerformanceCounter(&begin);
      const HRESULT hr=DwmFlush();
      QueryPerformanceCounter(&end);
      // This interval is the API call, not a first-present receipt for frame.
      const std::string line="atlas-dwm-flush frame="+std::to_string(frame)+
        " committed="+std::to_string(committed)+" begin="+std::to_string(begin.QuadPart)+
        " end="+std::to_string(end.QuadPart)+" hr="+std::to_string(int64_t(hr))+"\n";
      {std::lock_guard lock(mutex_);++completed_;log_+=line;}
    }
  }
  bool enabled_{},stop_{},pending_{};
  uint64_t frame_{},committed_{},requested_{},completed_{},coalesced_{};
  std::mutex mutex_;
  std::condition_variable changed_;
  std::thread worker_;
  std::string log_;
};

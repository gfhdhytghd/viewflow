#pragma once
#include "video_compositor.h"
#include "signalled_task.h"
#include <mfapi.h>
#include <condition_variable>
#include <functional>
#include <future>
#include <mutex>
#include <thread>
#include <stdexcept>
#include <optional>

namespace viewflow::windows_preview {
// Single caller. Legacy Invoke keeps spans alive synchronously; atlas Submit
// owns one asynchronous input and stops pipe consumption until it completes.
// No frame queue or deadline renewal. All decoder COM objects die on the MTA.
class MtaVideoCompositor {
 public:
  MtaVideoCompositor() = default;
  MtaVideoCompositor(const MtaVideoCompositor&) = delete;
  MtaVideoCompositor& operator=(const MtaVideoCompositor&) = delete;
  ~MtaVideoCompositor() {
    if (!worker_.joinable()) return;
    { std::lock_guard lock(mutex_); stopping_ = true; }
    wake_.notify_one();
    worker_.join();
  }
  HRESULT Initialize(uint32_t color_codec = 2) {
    if (worker_.joinable()) return E_UNEXPECTED;
    // Explicit diagnostic opt-in only, inherited by the isolated trial child.
    // Reject malformed values rather than silently changing thread policy.
    wchar_t workers_text[2]{};
    const DWORD workers_length = GetEnvironmentVariableW(
        L"VIEWFLOW_DIAGNOSTIC_DECODER_WORKERS", workers_text, 2);
    if (workers_length && (workers_length != 1 || workers_text[0] != L'2'))
      return E_INVALIDARG;
    const uint32_t workers = workers_length ? 2 : 0;
    std::promise<HRESULT> ready;
    auto result = ready.get_future();
    worker_ = std::thread([this, workers, color_codec, ready = std::move(ready)]() mutable {
      HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      if (FAILED(hr)) { ready.set_value(hr); return; }
      hr = MFStartup(MF_VERSION);
      if (FAILED(hr)) { ready.set_value(hr); CoUninitialize(); return; }
      {
        windows::GpuVideoCompositor decoder;
        hr = windows::GpuVideoCompositor::Create(&decoder, workers, color_codec);
        ready.set_value(hr);
        if (SUCCEEDED(hr)) {
          for (;;) {
            std::function<void(windows::GpuVideoCompositor&)> job;
            {
              std::unique_lock lock(mutex_);
              wake_.wait(lock, [this] { return stopping_ || bool(job_); });
              if (stopping_) break;
              job = std::move(job_);
              job_ = {};
            }
            job(decoder);
          }
        }
      }
      MFShutdown();
      CoUninitialize();
    });
    const HRESULT initialized = result.get();
    initialized_ = SUCCEEDED(initialized);
    return initialized;
  }
  template<class F> auto Invoke(F&& fn) {
    using R = std::invoke_result_t<F, windows::GpuVideoCompositor&>;
    auto task = std::make_shared<std::packaged_task<R(windows::GpuVideoCompositor&)>>(std::forward<F>(fn));
    auto result = task->get_future();
    {
      std::lock_guard lock(mutex_);
      if (!initialized_ || stopping_ || job_ || pending_) throw std::logic_error("invalid MTA handoff");
      job_ = [task](windows::GpuVideoCompositor& d) { (*task)(d); };
    }
    wake_.notify_one();
    return result.get();
  }
  ID3D11Device* device() { return Invoke([](auto& d) { return d.device(); }); }
  auto last_submit_host_durations() { return Invoke([](auto& d) { return d.last_submit_host_durations(); }); }
  HRESULT Submit(uint64_t id, std::span<const uint8_t> bytes,
                 const windows::RawGray8Alpha& alpha,
                 std::vector<windows::CompositedFrame>* completed) {
    return Invoke([&](auto& d) { return d.Submit(id, bytes, alpha, completed); });
  }
  struct Submission {
    HRESULT status{};
    std::vector<windows::CompositedFrame> frames;
  };
  void BeginSubmit(uint64_t id, uint32_t width, uint32_t height,
                   std::vector<uint8_t> bytes, std::vector<uint8_t> alpha) {
    std::lock_guard lock(mutex_);
    if (!initialized_ || stopping_ || job_ || pending_)
      throw std::logic_error("invalid asynchronous MTA handoff");
    pending_.emplace([id, width, height, bytes = std::move(bytes), alpha = std::move(alpha)](auto& d) {
      Submission result;
      result.status = d.Submit(id, bytes, {id, width, height, alpha}, &result.frames);
      return result;
    });
    job_ = pending_->runner();
    wake_.notify_one();
  }
  HANDLE submit_ready_event() const { return pending_ ? pending_->ready_event() : nullptr; }
  bool submit_ready() const { return pending_ && pending_->ready(); }
  Submission TakeSubmit() {
    if (!pending_) throw std::logic_error("missing asynchronous MTA submission");
    auto result = pending_->take();
    pending_.reset();
    return result;
  }
  HRESULT Finish(std::vector<windows::CompositedFrame>* completed) {
    return Invoke([&](auto& d) { return d.Finish(completed); });
  }
 private:
  std::mutex mutex_;
  std::condition_variable wake_;
  std::function<void(windows::GpuVideoCompositor&)> job_;
  bool stopping_{};
  bool initialized_{};
  std::thread worker_;
  std::optional<SignalledTask<Submission, windows::GpuVideoCompositor>> pending_;
};
}

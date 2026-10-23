#pragma once

#include <windows.h>
#include <winrt/base.h>

#include <array>
#include <cstdint>
#include <exception>
#include <mutex>

namespace viewflow::windows_preview {

// One fixed-size handoff gives the producer ordinary pipe backpressure.  The
// worker never accesses parser, decoder, composition, or window state.
class CompressedPipeReader {
public:
  static constexpr DWORD chunk_bytes = 64 * 1024;

  explicit CompressedPipeReader(
      HANDLE pipe
#if defined(VIEWFLOW_COMPRESSED_PIPE_READER_TESTING)
      , bool pause_before_read_for_test = false
#endif
      ) : pipe_(pipe)
#if defined(VIEWFLOW_COMPRESSED_PIPE_READER_TESTING)
      , pause_before_read_(pause_before_read_for_test)
#endif
      {
    ready_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    empty_ = CreateEventW(nullptr, TRUE, TRUE, nullptr);
    stop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    read_started_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
#if defined(VIEWFLOW_COMPRESSED_PIPE_READER_TESTING)
    if (pause_before_read_) {
      before_read_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
      permit_read_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    }
#endif
    if (!ready_ || !empty_ || !stop_ || !read_started_
#if defined(VIEWFLOW_COMPRESSED_PIPE_READER_TESTING)
        || (pause_before_read_ && (!before_read_ || !permit_read_))
#endif
        )
      fail_constructor();
    thread_ = CreateThread(nullptr, 0, &CompressedPipeReader::run, this, 0, nullptr);
    if (!thread_)
      fail_constructor();
  }
  ~CompressedPipeReader() { stop(); }
  CompressedPipeReader(CompressedPipeReader const &) = delete;
  CompressedPipeReader &operator=(CompressedPipeReader const &) = delete;

  HANDLE ready_event() const { return ready_; }
  // Exposed for native behavioral testing of the synchronous-read shutdown
  // path; the UI loop never waits on this event.
  HANDLE read_started_event() const { return read_started_; }
#if defined(VIEWFLOW_COMPRESSED_PIPE_READER_TESTING)
  HANDLE before_read_event_for_test() const { return before_read_; }
  HANDLE stop_event_for_test() const { return stop_; }
  HANDLE permit_read_event_for_test() const { return permit_read_; }
  HANDLE worker_thread_for_test() const { return thread_; }
#endif
  bool take(std::array<uint8_t, chunk_bytes> *out, DWORD *count,
            uint64_t *read_completed_qpc = nullptr) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!full_)
      return false;
    *out = bytes_;
    *count = count_;
    if (read_completed_qpc) *read_completed_qpc = read_completed_qpc_;
    full_ = false;
    ResetEvent(ready_);
    SetEvent(empty_);
    return true;
  }
  bool terminal(DWORD *error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!terminal_)
      return false;
    *error = error_;
    return true;
  }

private:
  [[noreturn]] void fail_constructor() {
    DWORD error = GetLastError();
    stop();
    SetLastError(error);
    winrt::throw_last_error();
  }
  static DWORD WINAPI run(void *context) {
    static_cast<CompressedPipeReader *>(context)->read_loop();
    return 0;
  }
  void publish_terminal(DWORD error) {
    std::lock_guard<std::mutex> lock(mutex_);
    terminal_ = true;
    error_ = error;
    SetEvent(ready_);
  }
  void read_loop() {
    HANDLE waits[] = {stop_, empty_};
    for (;;) {
      DWORD wait = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
      if (wait == WAIT_OBJECT_0)
        return;
      if (wait != WAIT_OBJECT_0 + 1) {
        if (WaitForSingleObject(stop_, 0) != WAIT_OBJECT_0)
          publish_terminal(GetLastError());
        return;
      }
      if (WaitForSingleObject(stop_, 0) == WAIT_OBJECT_0)
        return;
      ResetEvent(empty_); // reserve the one slot before the blocking read
#if defined(VIEWFLOW_COMPRESSED_PIPE_READER_TESTING)
      if (pause_before_read_) {
        SetEvent(before_read_);
        WaitForSingleObject(permit_read_, INFINITE);
      }
#endif
      DWORD read{};
      SetEvent(read_started_);
      if (!ReadFile(pipe_, bytes_.data(), chunk_bytes, &read, nullptr)) {
        DWORD error = GetLastError();
        if (WaitForSingleObject(stop_, 0) == WAIT_OBJECT_0)
          return;
        publish_terminal(error == ERROR_BROKEN_PIPE ? ERROR_SUCCESS : error);
        return;
      }
      LARGE_INTEGER read_completed{};
      const uint64_t completed_qpc = QueryPerformanceCounter(&read_completed) && read_completed.QuadPart > 0
          ? static_cast<uint64_t>(read_completed.QuadPart) : 0;
      if (WaitForSingleObject(stop_, 0) == WAIT_OBJECT_0)
        return;
      if (!read) {
        publish_terminal(ERROR_SUCCESS);
        return;
      }
      {
        std::lock_guard<std::mutex> lock(mutex_);
        count_ = read;
        read_completed_qpc_ = completed_qpc;
        full_ = true;
        SetEvent(ready_);
      }
    }
  }
  void stop() noexcept {
    if (stop_)
      SetEvent(stop_);
    if (thread_) {
      // A cancellation can land immediately before ReadFile begins.  Reissue
      // it while joining so that narrow race cannot strand the worker forever.
      for (;;) {
        DWORD wait = WaitForSingleObject(thread_, 10);
        if (wait == WAIT_OBJECT_0)
          break;
        if (wait == WAIT_FAILED)
          std::terminate(); // never free state while an unknown worker may run
        CancelSynchronousIo(thread_);
      }
      CloseHandle(thread_);
      thread_ = nullptr;
    }
    if (ready_) CloseHandle(ready_);
    if (empty_) CloseHandle(empty_);
    if (stop_) CloseHandle(stop_);
    if (read_started_) CloseHandle(read_started_);
#if defined(VIEWFLOW_COMPRESSED_PIPE_READER_TESTING)
    if (before_read_) CloseHandle(before_read_);
    if (permit_read_) CloseHandle(permit_read_);
#endif
    ready_ = empty_ = stop_ = read_started_ = nullptr;
  }

  HANDLE pipe_{};
  HANDLE ready_{}, empty_{}, stop_{}, read_started_{}, thread_{};
#if defined(VIEWFLOW_COMPRESSED_PIPE_READER_TESTING)
  bool pause_before_read_ = false;
  HANDLE before_read_{}, permit_read_{};
#endif
  std::mutex mutex_;
  std::array<uint8_t, chunk_bytes> bytes_{};
  DWORD count_{};
  uint64_t read_completed_qpc_{};
  bool full_ = false;
  bool terminal_ = false;
  DWORD error_ = ERROR_SUCCESS;
};

} // namespace viewflow::windows_preview

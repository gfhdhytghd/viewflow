#pragma once

#include <windows.h>
#include <future>
#include <memory>
#include <stdexcept>
#include <system_error>
#include <utility>

namespace viewflow::windows_preview {

// One result and one completion event, not a queue. The worker retains the
// event and callable until it finishes, even if the UI abandons its result.
template<class Result, class Argument> class SignalledTask {
  struct Event {
    HANDLE value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    Event() {
      if (!value) throw std::system_error(int(GetLastError()), std::system_category());
    }
    ~Event() { CloseHandle(value); }
  };
 public:
  template<class F> explicit SignalledTask(F&& fn)
      : event_(std::make_shared<Event>()),
        task_(std::make_shared<std::packaged_task<Result(Argument&)>>(std::forward<F>(fn))),
        result_(task_->get_future()) {}
  SignalledTask(SignalledTask&&) = default;
  SignalledTask& operator=(SignalledTask&&) = default;
  SignalledTask(const SignalledTask&) = delete;
  SignalledTask& operator=(const SignalledTask&) = delete;
  HANDLE ready_event() const { return event_->value; }
  bool ready() const {
    const auto wait = WaitForSingleObject(ready_event(), 0);
    if (wait == WAIT_FAILED)
      throw std::system_error(int(GetLastError()), std::system_category());
    return wait == WAIT_OBJECT_0;
  }
  Result take() {
    if (!ready()) throw std::logic_error("unfinished asynchronous task");
    return result_.get();
  }
  auto runner() const {
    return [task = task_, event = event_](Argument& argument) {
      // packaged_task publishes either the value or the exception before the
      // manual-reset event wakes the UI. No UI/COM window work occurs here.
      (*task)(argument);
      if (!SetEvent(event->value)) std::terminate(); // owned valid handle invariant
    };
  }
 private:
  std::shared_ptr<Event> event_;
  std::shared_ptr<std::packaged_task<Result(Argument&)>> task_;
  std::future<Result> result_;
};

} // namespace viewflow::windows_preview

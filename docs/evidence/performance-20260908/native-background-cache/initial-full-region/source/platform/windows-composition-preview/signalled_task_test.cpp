#include "signalled_task.h"
#include <cassert>
#include <functional>
#include <thread>

using viewflow::windows_preview::SignalledTask;

int main() {
  int argument = 7;
  std::promise<void> release;
  auto gate = release.get_future();
  SignalledTask<int, int> task([&](int& value) { gate.wait(); return value + 2; });
  auto runner = task.runner();
  std::thread worker([&] { runner(argument); });
  assert(!task.ready());
  bool rejected = false;
  try { (void)task.take(); } catch (const std::logic_error&) { rejected = true; }
  assert(rejected); // Never block the UI in take().
  // The same outer wait used by the atlas accepts a thread message while the
  // worker is deliberately blocked. No nested pump or deadline renewal.
  MSG message{};
  PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
  assert(PostThreadMessageW(GetCurrentThreadId(), WM_APP + 17, 0, 0));
  HANDLE event = task.ready_event();
  assert(MsgWaitForMultipleObjectsEx(1, &event, 2000, QS_ALLINPUT,
                                    MWMO_INPUTAVAILABLE) == WAIT_OBJECT_0 + 1);
  assert(PeekMessageW(&message, nullptr, WM_APP + 17, WM_APP + 17, PM_REMOVE));
  assert(message.message == WM_APP + 17 && !task.ready());
  release.set_value();
  assert(WaitForSingleObject(task.ready_event(), 2000) == WAIT_OBJECT_0);
  assert(task.take() == 9);
  worker.join();

  SignalledTask<int, int> failed([](int&) -> int { throw std::runtime_error("decode failed"); });
  failed.runner()(argument);
  assert(failed.ready()); // Exceptions also wake the UI.
  rejected = false;
  try { (void)failed.take(); } catch (const std::runtime_error&) { rejected = true; }
  assert(rejected);

  std::function<void(int&)> abandoned;
  {
    auto owned = std::make_unique<int>(13);
    SignalledTask<int, int> original([payload = std::move(owned)](int& value) {
      value = *payload;
      return value;
    });
    auto moved = std::move(original);
    abandoned = moved.runner();
  }
  abandoned(argument); // UI result/event owner can disappear before execution.
  assert(argument == 13);
}

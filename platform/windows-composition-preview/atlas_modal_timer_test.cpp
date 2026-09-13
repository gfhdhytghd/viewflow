// Exercise the production window procedure using a message-only HWND.
// No visible window, focus change, or mouse/keyboard input is involved.
#define wmain viewflow_unused_preview_entry
#include "main.cpp"
#undef wmain
#include <cassert>

namespace {
LRESULT CALLBACK timer_probe_proc(HWND hwnd, UINT message, WPARAM w, LPARAM l) {
  return message == WM_TIMER ? atlas_proc(hwnd, message, w, l)
                             : DefWindowProcW(hwnd, message, w, l);
}

void dispatch_timers_for(DWORD milliseconds) {
  const auto until = GetTickCount64() + milliseconds;
  do {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
    Sleep(1);
  } while (GetTickCount64() < until);
}
}

int main() {
  WNDCLASSW type{};
  type.lpfnWndProc = timer_probe_proc;
  type.hInstance = GetModuleHandleW(nullptr);
  type.lpszClassName = L"ViewflowModalTimerTest";
  assert(RegisterClassW(&type));
  const auto hwnd = CreateWindowExW(0, type.lpszClassName, L"", 0, 0, 0, 0, 0,
                                  HWND_MESSAGE, nullptr, type.hInstance, nullptr);
  assert(hwnd);
  AtlasInputContext context{};
  unsigned backgrounds = 0, pumps = 0;
  context.update_background = [&] { ++backgrounds; };
  atlas_modal_pump = [&] { ++pumps; };
  SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(&context));

  // The cached backdrop must not consume the shell's media-pump message.
  SendMessageW(hwnd, WM_TIMER, atlas_modal_timer, 0);
  assert(pumps == 1 && backgrounds == 0);
  SendMessageW(hwnd, WM_TIMER, atlas_background_timer, 0);
  assert(pumps == 1 && backgrounds == 1);

  // Entering and leaving resize must preserve the independent background timer.
  assert(SetTimer(hwnd, atlas_background_timer, 16, nullptr));
  assert(SetTimer(hwnd, atlas_modal_timer, 10, nullptr));
  dispatch_timers_for(100);
  assert(pumps > 1 && backgrounds > 1);
  assert(KillTimer(hwnd, atlas_modal_timer));
  dispatch_timers_for(30); // Drain any already-posted modal message.
  const auto old_pumps = pumps, old_backgrounds = backgrounds;
  dispatch_timers_for(100);
  assert(pumps == old_pumps && backgrounds > old_backgrounds);
  KillTimer(hwnd, atlas_background_timer);
  // A shell-loop exit (including lease-release return) must not retain the
  // edge-aligned preview after source geometry has resumed on the other screen.
  context.desktop.enabled = true;
  context.wm_moving = true;
  context.wm_pending_until = GetTickCount64() + 2000;
  atlas_proc(hwnd, WM_EXITSIZEMOVE, 0, 0);
  assert(!context.wm_moving && context.wm_pending_until == 0);
  atlas_modal_pump = {};
  DestroyWindow(hwnd);
  UnregisterClassW(type.lpszClassName, type.hInstance);
}

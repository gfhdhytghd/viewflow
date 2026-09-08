#pragma once

#include <windows.h>
#include <imm.h>

namespace viewflow::windows_preview {

// Call before this dedicated proxy UI thread creates any top-level window.
// Physical-key forwarding leaves text composition with the source application;
// a destination proxy must not start a second local IME composition session.
// Do not use process-wide (-1) or implicit (0) scope here.
inline bool configure_remote_input_ime(
    bool remote_input,
    BOOL(WINAPI* disable)(DWORD) = ImmDisableIME,
    DWORD(WINAPI* current_thread)() = GetCurrentThreadId) {
  if (!remote_input) return true;
  const DWORD thread = current_thread();
  return thread != 0 && thread != DWORD(-1) && disable(thread) != FALSE;
}

} // namespace viewflow::windows_preview

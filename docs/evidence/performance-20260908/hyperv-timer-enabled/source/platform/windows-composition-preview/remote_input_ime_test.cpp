#include "remote_input_ime.h"
#include <cassert>

namespace {
DWORD selected_thread{}, reported_thread = 73;
unsigned calls{}, thread_calls{};
BOOL result = TRUE;
BOOL WINAPI disable(DWORD thread) { ++calls; selected_thread = thread; return result; }
DWORD WINAPI current_thread() { ++thread_calls; return reported_thread; }
}

int main() {
  using viewflow::windows_preview::configure_remote_input_ime;
  assert(configure_remote_input_ime(false, disable, current_thread));
  assert(calls == 0 && thread_calls == 0);
  assert(configure_remote_input_ime(true, disable, current_thread));
  assert(calls == 1 && thread_calls == 1 && selected_thread == 73);
  result = FALSE;
  assert(!configure_remote_input_ime(true, disable, current_thread));
  assert(calls == 2);
  reported_thread = 0;
  assert(!configure_remote_input_ime(true, disable, current_thread));
  reported_thread = DWORD(-1);
  assert(!configure_remote_input_ime(true, disable, current_thread));
  assert(calls == 2); // Never silently broaden disable scope.
}

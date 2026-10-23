#pragma once
#include <windows.h>
#include <avrt.h>
#include <cstdio>
#pragma comment(lib, "avrt.lib")
namespace viewflow::windows_preview {
// Calling-thread lifetime only. Failed registration leaves ordinary scheduling.
// The application never edits the MMCSS registry or other processes.
class MmcssScope {
 public:
  explicit MmcssScope(const char* role) : role_(role) {
    wchar_t flag[2]{};
    const DWORD length = GetEnvironmentVariableW(L"VIEWFLOW_MMCS_PLAYBACK", flag, 2);
    const bool requested = length == 1 && flag[0] == L'1';
    DWORD index = 0, error = 0;
    bool priority = false;
    if (requested) {
      handle_ = AvSetMmThreadCharacteristicsW(L"Playback", &index);
      if (!handle_) error = GetLastError();
      else {
        priority = AvSetMmThreadPriority(handle_, AVRT_PRIORITY_HIGH) != FALSE;
        if (!priority) error = GetLastError();
      }
    }
    std::fprintf(stderr, "atlas-mmcss role=%s thread=%lu requested=%u registered=%u priority_set=%u task_index=%lu error=%lu\n",
                 role_, GetCurrentThreadId(), unsigned(requested), unsigned(handle_ != nullptr), unsigned(priority), index, error);
  }
  ~MmcssScope() {
    if (!handle_) return;
    const bool reverted = AvRevertMmThreadCharacteristics(handle_) != FALSE;
    const DWORD error = reverted ? 0 : GetLastError();
    std::fprintf(stderr, "atlas-mmcss-revert role=%s thread=%lu reverted=%u error=%lu\n",
                 role_, GetCurrentThreadId(), unsigned(reverted), error);
  }
  MmcssScope(const MmcssScope&) = delete;
  MmcssScope& operator=(const MmcssScope&) = delete;
 private:
  const char* role_;
  HANDLE handle_{};
};
}

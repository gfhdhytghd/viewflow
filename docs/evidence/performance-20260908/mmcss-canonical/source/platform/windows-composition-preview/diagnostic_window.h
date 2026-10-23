#pragma once
#include <windows.h>
#include <winrt/base.h>

namespace viewflow::windows_preview {
// Opt-in for passive measurements. NOACTIVATE alone still intercepts mouse
// hit testing; a transparent layered window passes it to windows underneath.
inline bool DiagnosticMousePassthrough() {
  static const bool enabled = [] {
    wchar_t value[2]{};
    return GetEnvironmentVariableW(L"VIEWFLOW_ATLAS_DIAGNOSTIC_MOUSE_PASSTHROUGH",
                                   value, 2) == 1 && value[0] == L'1';
  }();
  return enabled;
}
// Keep passive measurement windows visible when the shell desktop is in front.
// Apply this at creation; input-enabled proxies never use this diagnostic mode.
inline constexpr DWORD kDiagnosticMouseStyles =
    WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOPMOST;

// Call before the first show. This preserves composition alpha; the constant
// window alpha is fully opaque and is used only to configure layered routing.
inline void ConfigureDiagnosticMousePassthrough(HWND window) {
  const auto styles = GetWindowLongPtrW(window, GWL_EXSTYLE);
  if ((styles & kDiagnosticMouseStyles) != kDiagnosticMouseStyles)
    winrt::throw_hresult(E_INVALIDARG);
  winrt::check_bool(SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA));
}
} // namespace viewflow::windows_preview

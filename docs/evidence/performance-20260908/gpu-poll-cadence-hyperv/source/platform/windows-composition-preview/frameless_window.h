#pragma once
#include <windows.h>
#include <optional>
namespace viewflow::windows_preview {
inline std::optional<LRESULT> FramelessMessage(HWND hwnd, UINT message, WPARAM w, LPARAM l) {
  if (message == WM_NCCALCSIZE) {
    if (w && IsZoomed(hwnd)) {
      MONITORINFO monitor{sizeof(monitor)};
      if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor))
        reinterpret_cast<NCCALCSIZE_PARAMS*>(l)->rgrc[0] = monitor.rcWork;
    }
    return 0;
  }
  if (message == WM_NCPAINT) return 0;
  if (message == WM_NCACTIVATE) return DefWindowProcW(hwnd, message, w, -1);
  return {};
}
inline int FramelessHit(const RECT& r, int x, int y, bool maximized) {
  if (maximized) return HTCLIENT;
  const bool left = x < r.left + 6, right = x >= r.right - 6;
  const bool top = y < r.top + 6, bottom = y >= r.bottom - 6;
  if (top) return left ? HTTOPLEFT : right ? HTTOPRIGHT : HTTOP;
  if (bottom) return left ? HTBOTTOMLEFT : right ? HTBOTTOMRIGHT : HTBOTTOM;
  return left ? HTLEFT : right ? HTRIGHT : HTCLIENT;
}
}

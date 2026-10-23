#include "frameless_window.h"
#include <cassert>
using namespace viewflow::windows_preview;
LRESULT CALLBACK test_proc(HWND h,UINT m,WPARAM w,LPARAM l) {
  if (auto result = FramelessMessage(h,m,w,l)) return *result;
  return DefWindowProcW(h,m,w,l);
}
int main() {
  const HWND focus = GetForegroundWindow();
  WNDCLASSW cls{}; cls.lpfnWndProc = test_proc; cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = L"ViewflowHiddenFramelessTest";
  assert(RegisterClassW(&cls));
  HWND hwnd = CreateWindowExW(WS_EX_NOACTIVATE,cls.lpszClassName,L"",WS_OVERLAPPEDWINDOW,100,100,800,600,nullptr,nullptr,cls.hInstance,nullptr);
  assert(hwnd && !IsWindowVisible(hwnd));
  RECT outer{}, client{};
  assert(GetWindowRect(hwnd,&outer) && GetClientRect(hwnd,&client));
  assert(outer.right-outer.left == client.right && outer.bottom-outer.top == client.bottom);
  assert((GetWindowLongPtrW(hwnd,GWL_STYLE) & (WS_CAPTION|WS_THICKFRAME)) == (WS_CAPTION|WS_THICKFRAME));
  assert(FramelessHit(outer,outer.left+10,outer.top+15,false)==HTCLIENT);
  assert(FramelessHit(outer,outer.left,outer.top,false)==HTTOPLEFT);
  assert(FramelessHit(outer,outer.right-1,outer.bottom-1,false)==HTBOTTOMRIGHT);
  assert(FramelessHit(outer,outer.left,outer.top,true)==HTCLIENT);
  assert(GetForegroundWindow()==focus);
  DestroyWindow(hwnd);
}

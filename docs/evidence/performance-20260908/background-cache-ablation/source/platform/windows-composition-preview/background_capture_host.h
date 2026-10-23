#pragma once

// A full-size HostBackdrop sampling window. Its physical bounds are the cache
// bounds, because a larger child visual cannot enlarge DWM's backdrop texture.
// Construct, pump and destroy on the cache worker that owns this HWND.
class BackgroundCaptureHost {
  struct OwnedWindow {
    HWND value{};
    ~OwnedWindow() {
      if (value)
        DestroyWindow(value);
    }
  } window_;
  HWND proxy_{};
  DesktopWindowTarget target_{nullptr};
  std::atomic<bool> enabled_{}, ready_{};
  std::atomic<bool> failed_{};
  static LRESULT CALLBACK Procedure(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_NCHITTEST)
      return HTTRANSPARENT;
    if (m == WM_MOUSEACTIVATE)
      return MA_NOACTIVATE;
    return DefWindowProcW(h, m, w, l);
  }

public:
  BackgroundCaptureHost(Compositor const &c, HWND proxy,
                        viewflow::background::Rect bounds, ContainerVisual root)
      : proxy_(proxy) {
    static std::once_flag registered;
    std::call_once(registered, [] {
      WNDCLASSW cls{};
      cls.hInstance = GetModuleHandleW(nullptr);
      cls.lpfnWndProc = Procedure;
      cls.lpszClassName = L"ViewflowBackgroundCapture";
      if (!RegisterClassW(&cls))
        winrt::throw_last_error();
    });
    // WS_EX_LAYERED + WS_EX_TRANSPARENT routes mouse events through the whole
    // helper, including the area outside the proxy. No activation or task
    // entry.
    window_.value = CreateWindowExW(
        WS_EX_NOREDIRECTIONBITMAP | WS_EX_LAYERED | WS_EX_TRANSPARENT |
            WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
        L"ViewflowBackgroundCapture", L"Viewflow background cache", WS_POPUP,
        int(bounds.left), int(bounds.top), int(bounds.width()),
        int(bounds.height()), nullptr, nullptr, GetModuleHandleW(nullptr),
        nullptr);
    if (!window_.value)
      winrt::throw_last_error();
    winrt::check_bool(
        SetLayeredWindowAttributes(window_.value, 0, 255, LWA_ALPHA));
    const BOOL yes = TRUE;
    winrt::check_hresult(DwmSetWindowAttribute(
        window_.value, DWMWA_USE_HOSTBACKDROPBRUSH, &yes, sizeof(yes)));
    DwmSetWindowAttribute(window_.value, DWMWA_TRANSITIONS_FORCEDISABLED, &yes,
                          sizeof(yes));
    auto desktop = c.as<
        ABI::Windows::UI::Composition::Desktop::ICompositorDesktopInterop>();
    winrt::check_hresult(desktop->CreateDesktopWindowTarget(
        window_.value, true,
        reinterpret_cast<
            ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget **>(
            put_abi(target_))));
    target_.Root(root);
  }
  void Enable(bool value) { enabled_ = value; }
  bool Ready() const { return ready_.load(); }
  bool Failed() const { return failed_.load(); }
  void Pump() {
    if (!IsWindow(window_.value)) {
      ready_ = false;
      failed_ = true;
      return;
    }
    if (!enabled_ || !IsWindow(proxy_) || !IsWindowVisible(proxy_) ||
        IsIconic(proxy_)) {
      ready_ = false;
      if (IsWindowVisible(window_.value))
        ShowWindow(window_.value, SW_HIDE);
      return;
    }
    if (!IsWindowVisible(window_.value) ||
        GetWindow(window_.value, GW_HWNDPREV) != proxy_) {
      ready_ = SetWindowPos(window_.value, proxy_, 0, 0, 0, 0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
                                SWP_SHOWWINDOW) != FALSE;
    } else
      ready_ = true;
  }
};

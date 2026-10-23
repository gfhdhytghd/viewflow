// Manual hardware oracle. Owns three nonactivating windows, never sends input.
#define wmain viewflow_preview_entry_for_background_test
#define VIEWFLOW_BACKGROUND_CACHE_TESTING
#include "main.cpp"
#undef wmain
#include <io.h>

namespace {
LRESULT CALLBACK cache_test_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
  if (m == WM_MOUSEACTIVATE)
    return MA_NOACTIVATE;
  return DefWindowProcW(h, m, w, l);
}
void require_cache(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
std::array<int, 3> read_sample(int x, int y) {
  const HDC screen = GetDC(nullptr);
  require_cache(screen != nullptr, "screen DC");
  std::array<int, 3> sum{};
  for (int j = 0; j < 8; ++j)
    for (int i = 0; i < 8; ++i) {
      const auto color = GetPixel(screen, x + i, y + j);
      if (color == CLR_INVALID) {
        ReleaseDC(nullptr, screen);
        throw std::runtime_error("pixel read");
      }
      sum[0] += GetRValue(color);
      sum[1] += GetGValue(color);
      sum[2] += GetBValue(color);
    }
  ReleaseDC(nullptr, screen);
  for (auto &n : sum)
    n = (n + 32) / 64;
  return sum;
}
void dump_visual(ID3D11Device *device, Visual visual, int width, int height,
                 const char *name) {
  using namespace winrt::Windows::Graphics::Capture;
  using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
  auto dxgi = winrt::com_ptr<ID3D11Device>{};
  dxgi.copy_from(device);
  auto adapter = dxgi.as<IDXGIDevice>();
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice runtime{
      nullptr};
  check_hresult(CreateDirect3D11DeviceFromDXGIDevice(
      adapter.get(), reinterpret_cast<::IInspectable **>(put_abi(runtime))));
  auto pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
      runtime, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, {width, height});
  auto session =
      pool.CreateCaptureSession(GraphicsCaptureItem::CreateFromVisual(visual));
  session.StartCapture();
  auto until = GetTickCount64() + 2000;
  bool saved = false;
  while (GetTickCount64() < until) {
    MSG m{};
    while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&m);
      DispatchMessageW(&m);
    }
    auto frame = pool.TryGetNextFrame();
    if (!frame) {
      Sleep(5);
      continue;
    }
    auto access = frame.Surface()
                      .as<::Windows::Graphics::DirectX::Direct3D11::
                              IDirect3DDxgiInterfaceAccess>();
    winrt::com_ptr<ID3D11Texture2D> texture;
    check_hresult(
        access->GetInterface(guid_of<ID3D11Texture2D>(), texture.put_void()));
    D3D11_TEXTURE2D_DESC d{};
    texture->GetDesc(&d);
    d.Usage = D3D11_USAGE_STAGING;
    d.BindFlags = 0;
    d.MiscFlags = 0;
    d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    winrt::com_ptr<ID3D11Texture2D> readback;
    check_hresult(device->CreateTexture2D(&d, nullptr, readback.put()));
    winrt::com_ptr<ID3D11DeviceContext> context;
    device->GetImmediateContext(context.put());
    context->CopyResource(readback.get(), texture.get());
    D3D11_MAPPED_SUBRESOURCE map{};
    check_hresult(context->Map(readback.get(), 0, D3D11_MAP_READ, 0, &map));
    std::ofstream out(name, std::ios::binary);
    out.write(reinterpret_cast<char *>(&d.Width), 4);
    out.write(reinterpret_cast<char *>(&d.Height), 4);
    for (UINT y = 0; y < d.Height; ++y)
      out.write(static_cast<char *>(map.pData) + size_t(y) * map.RowPitch,
                size_t(d.Width) * 4);
    context->Unmap(readback.get(), 0);
    frame.Close();
    saved = true;
    break;
  }
  session.Close();
  pool.Close();
  require_cache(saved, "diagnostic capture missing");
}
int cache_oracle() {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  init_apartment(apartment_type::single_threaded);
  viewflow::windows_preview::TimerResolutionGuard timer_resolution;
  require_cache(timer_resolution.active(), "native timer resolution");
  const auto initial_foreground = GetForegroundWindow();
  MONITORINFO monitor{sizeof(monitor)};
  require_cache(GetMonitorInfoW(MonitorFromWindow(initial_foreground,
                                                  MONITOR_DEFAULTTOPRIMARY),
                                &monitor),
                "monitor");
  if (monitor.rcWork.right - monitor.rcWork.left < 2000 ||
      monitor.rcWork.bottom - monitor.rcWork.top < 1400)
    EnumDisplayMonitors(
        nullptr, nullptr,
        [](HMONITOR h, HDC, LPRECT, LPARAM p) -> BOOL {
          MONITORINFO m{sizeof(m)};
          if (GetMonitorInfoW(h, &m) &&
              m.rcWork.right - m.rcWork.left >= 2000 &&
              m.rcWork.bottom - m.rcWork.top >= 1400) {
            *reinterpret_cast<MONITORINFO *>(p) = m;
            return FALSE;
          }
          return TRUE;
        },
        reinterpret_cast<LPARAM>(&monitor));
  std::printf("background-test work=%ld,%ld,%ld,%ld\n", monitor.rcWork.left,
              monitor.rcWork.top, monitor.rcWork.right, monitor.rcWork.bottom);
  require_cache(monitor.rcWork.right - monitor.rcWork.left >= 2000 &&
                    monitor.rcWork.bottom - monitor.rcWork.top >= 1400,
                "oracle display size");
  const int bx = monitor.rcWork.right - 2000, by = monitor.rcWork.top + 32;
  int x = bx + 400, y = by + 400, w = 512, h = 512;
  stage = "dispatcher";
  DispatcherQueueOptions options{sizeof(options), DQTYPE_THREAD_CURRENT,
                                 DQTAT_COM_STA};
  com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;
  check_hresult(CreateDispatcherQueueController(options, queue.put()));
  stage = "compositor";
  Compositor c;
  stage = "foreground";
  auto fg = foreground(c, 512, 512);
  stage = "windows";
  WNDCLASSW cls{};
  cls.lpfnWndProc = cache_test_proc;
  cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = L"ViewflowBackgroundCacheOracle";
  require_cache(RegisterClassW(&cls) != 0, "register class");
  constexpr DWORD ex =
      WS_EX_NOREDIRECTIONBITMAP | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
  WindowOwner back{CreateWindowExW(
      ex, cls.lpszClassName, L"Viewflow cache test background", WS_POPUP, bx,
      by, 2000, 1344, nullptr, nullptr, cls.hInstance, nullptr)};
  WindowOwner front{CreateWindowExW(
      ex, cls.lpszClassName, L"Viewflow cache test foreground", WS_POPUP, x, y,
      w, h, back.value, nullptr, cls.hInstance, nullptr)};
  require_cache(back.value && front.value, "owned windows");
  stage = "host-attribute";
  BOOL yes = TRUE;
  check_hresult(DwmSetWindowAttribute(front.value, DWMWA_USE_HOSTBACKDROPBRUSH,
                                      &yes, sizeof(yes)));
  stage = "transitions";
  for (HWND window : {back.value, front.value})
    check_hresult(DwmSetWindowAttribute(window, DWMWA_TRANSITIONS_FORCEDISABLED,
                                        &yes, sizeof(yes)));
  stage = "desktop-target";
  auto desktop =
      c.as<ABI::Windows::UI::Composition::Desktop::ICompositorDesktopInterop>();
  auto attach = [&](HWND window, ContainerVisual root) {
    DesktopWindowTarget target{nullptr};
    check_hresult(desktop->CreateDesktopWindowTarget(
        window, true,
        reinterpret_cast<
            ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget **>(
            put_abi(target))));
    target.Root(root);
    return target;
  };
  stage = "background-visual";
  auto background = c.CreateContainerVisual();
  background.Size({2000, 1344});
  auto color = c.CreateColorBrush(winrt::Windows::UI::Color{255, 220, 30, 50});
  auto fill = c.CreateSpriteVisual();
  fill.Size({2000, 1344});
  fill.Brush(color);
  background.Children().InsertAtTop(fill);
  auto back_target = attach(back.value, background);
  stage = "foreground-root";
  auto root = c.CreateContainerVisual();
  root.Children().InsertAtTop(fg.visual);
  auto target = attach(front.value, root);
  auto raw = c.CreateHostBackdropBrush();
  stage = "cache-constructor";
  NativeBackgroundCache cache(c, fg.d3d.get(), front.value);
  std::vector<viewflow::vfgp::AtlasPatch> patches{
      {0, 0, 0, 0, 0, 512, 128},
      {0, 0, 128, 0, 128, 128, 256},
      {0, 128, 128, 128, 128, 256, 256},
      {0, 384, 128, 384, 128, 128, 256},
      {0, 0, 384, 0, 384, 512, 128}};
  uint64_t identity = 0;
  auto bind = [&](bool opaque) {
    std::vector<uint8_t> bytes(512 * 512 * 4);
    for (unsigned py = 0; py < 512; ++py)
      for (unsigned px = 0; px < 512; ++px) {
        const auto i = (py * 512 + px) * 4;
        bytes[i + 3] = 128;
        if (px >= 128 && px < 384 && py >= 128 && py < 384) {
          bytes[i] = 30;
          bytes[i + 1] = 80;
          bytes[i + 2] = 120;
          bytes[i + 3] = 255;
          if (!opaque) {
            bytes[i] = bytes[i + 1] = bytes[i + 2] = bytes[i + 3] = 0;
          }
        }
      }
    D3D11_TEXTURE2D_DESC d{};
    d.Width = d.Height = 512;
    d.MipLevels = d.ArraySize = d.SampleDesc.Count = 1;
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    d.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    D3D11_SUBRESOURCE_DATA data{bytes.data(), 512 * 4, 0};
    viewflow::windows::CompositedFrame f;
    f.frame_identity = ++identity;
    f.width = f.height = 512;
    check_hresult(fg.d3d->CreateTexture2D(&d, &data,
                                          f.premultiplied_bgra.GetAddressOf()));
    auto surface = stage_gpu_surface(fg, c, f);
    std::array<uint8_t, 5> flags{0, 0, uint8_t(opaque), 0, 0};
    commit_sparse_visuals(fg,
                          stage_sparse_visuals(fg, c, surface.surface, patches,
                                               0, 512, 512, raw, 12, flags),
                          float(w), float(h));
    fg.visual.Size({float(w), float(h)});
  };
  stage = "initial-bind";
  bind(true);
  ShowWindow(back.value, SW_SHOWNOACTIVATE);
  ShowWindow(front.value, SW_SHOWNOACTIVATE);

  auto cached_nodes = [&] {
    unsigned count = 0;
    for (auto const &[key, node] : fg.shared_sparse->nodes)
      if (node.background && node.background_cached)
        ++count;
    return count;
  };
  auto pump = [&](unsigned milliseconds) {
    const auto end = GetTickCount64() + milliseconds;
    while (GetTickCount64() < end) {
      MSG msg{};
      while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
      }
      cache.Update(front.value, fg);
      Sleep(8);
    }
  };
  pump(3000);
  cache.Report(stdout);
  require_cache(cached_nodes() == 4, "initial cache not bound");
  const auto red = read_sample(x + 256, y + 40);
  color.Color(winrt::Windows::UI::Color{255, 30, 210, 90});
  pump(1000);
  const auto green = read_sample(x + 256, y + 40);
  cache.Report(stdout);
  RECT actual{};
  GetWindowRect(front.value, &actual);
  std::printf("background-test front-visible=%d iconic=%d rect=%ld,%ld,%ld,%ld "
              "foreground-unchanged=%d\n",
              IsWindowVisible(front.value), IsIconic(front.value), actual.left,
              actual.top, actual.right, actual.bottom,
              GetForegroundWindow() == initial_foreground);
  std::printf("background-test red=%d,%d,%d green=%d,%d,%d cached=%u\n", red[0],
              red[1], red[2], green[0], green[1], green[2], cached_nodes());
  require_cache(red[0] > green[0] + 30 && green[1] > red[1] + 30,
                "other local window did not update cache");
  for (unsigned i = 0; i < 24; ++i) {
    auto stripe = c.CreateSpriteVisual();
    stripe.Size({64, 1344});
    stripe.Offset({float(i * 64), 0, 0});
    stripe.Brush(c.CreateColorBrush(
        i % 2 ? winrt::Windows::UI::Color{255, 220, 180, 20}
              : winrt::Windows::UI::Color{255, 20, 50, 220}));
    background.Children().InsertAtTop(stripe);
  }
  pump(1000);
  const int sample_x = x + 256, sample_y = y + 40;
  const auto anchored = read_sample(sample_x, sample_y);
  std::printf("background-test anchored=%d,%d,%d world=%d,%d\n", anchored[0],
              anchored[1], anchored[2], sample_x, sample_y);
  auto dump = [&](const char *raw_name, const char *cache_name) {
    const auto region = cache.RegionForTest();
    auto source = cache.SourceForTest();
    auto pos = source.Offset();
    std::printf(
        "background-test region=%lld,%lld,%lld,%lld source_offset=%.2f,%.2f\n",
        region.bounds.left, region.bounds.top, region.bounds.right,
        region.bounds.bottom, pos.x, pos.y);
    auto visual = c.CreateSpriteVisual();
    visual.Size({float(region.bounds.width()), float(region.bounds.height())});
    auto brush = c.CreateSurfaceBrush(cache.SurfaceForTest());
    brush.Stretch(CompositionStretch::None);
    brush.HorizontalAlignmentRatio(0);
    brush.VerticalAlignmentRatio(0);
    visual.Brush(brush);
    dump_visual(fg.d3d.get(), source, int(region.bounds.width()),
                int(region.bounds.height()), raw_name);
    dump_visual(fg.d3d.get(), visual, int(region.bounds.width()),
                int(region.bounds.height()), cache_name);
  };
  dump("raw-before.bgra", "cache-before.bgra");
  // Translate within the reserve, then resize beyond it to force a generation.
  for (auto size : std::array<std::array<int, 4>, 3>{
           {{x + 64, y, 512, 512}, {x + 192, y, 700, 600}, {x, y, 512, 512}}}) {
    x = size[0];
    y = size[1];
    w = size[2];
    h = size[3];
    check_bool(SetWindowPos(front.value, nullptr, x, y, w, h,
                            SWP_NOACTIVATE | SWP_NOZORDER));
    fg.sparse_root.Scale({float(w) / 512, float(h) / 512, 1});
    fg.visual.Size({float(w), float(h)});
    pump(2000);
    const auto sample = read_sample(sample_x, sample_y);
    std::printf("background-test moved-sample=%d,%d,%d geometry=%d,%d,%d,%d\n",
                sample[0], sample[1], sample[2], x, y, w, h);
    dump("raw-after.bgra", "cache-after.bgra");
    require_cache(cached_nodes() == 4, "moved/resized cache not bound");
    require_cache(abs(sample[0] - anchored[0]) <= 5 &&
                      abs(sample[1] - anchored[1]) <= 5 &&
                      abs(sample[2] - anchored[2]) <= 5,
                  "background moved or stretched with the foreground");
    std::printf(
        "background-test geometry=%d,%d,%d,%d sample=%d,%d,%d cached=%u\n", x,
        y, w, h, sample[0], sample[1], sample[2], cached_nodes());
  }
  background.Children().RemoveAll();
  background.Children().InsertAtTop(fill);
  pump(1000);
  bind(false);
  pump(300);
  std::printf("background-test no-opaque cached=%u nodes=%zu\n", cached_nodes(),
              fg.shared_sparse->nodes.size());
  require_cache(cached_nodes() > 0,
                "background cache lost fully translucent content");
  const auto hole = read_sample(x + w / 2, y + h / 2);
  require_cache(abs(hole[0] - 30) <= 2 && abs(hole[1] - 210) <= 2 &&
                    abs(hole[2] - 90) <= 2,
                "transparent hole changed background");
  bind(true);
  pump(1500);
  require_cache(cached_nodes() == 4,
                "cache did not recover after opaque content returned");
  // Fast programmatic movement of our own window exercises the temporary
  // velocity reserve. No mouse, keyboard or focus event is synthesized.
  for (int step = 0; step < 6; ++step) {
    x += 64;
    check_bool(SetWindowPos(front.value, nullptr, x, y, w, h,
                            SWP_NOACTIVATE | SWP_NOZORDER));
    pump(8);
  }
  pump(2000);
  const auto idle = cache.RegionForTest();
  std::printf("background-test idle-reserve=%lld,%lld cached=%u\n",
              idle.motion_x, idle.motion_y, cached_nodes());
  require_cache(idle.motion_x == 128 && idle.motion_y == 128 &&
                    cached_nodes() == 4,
                "stationary cache retained a transient motion reserve");
  // The right edge extends four pixels beyond this display. The cache itself
  // must stop at the monitor; outside strips keep the ordinary brush.
  x = monitor.rcMonitor.right - 508;
  check_bool(SetWindowPos(front.value, nullptr, x, y, w, h,
                          SWP_NOACTIVATE | SWP_NOZORDER));
  pump(2000);
  const auto edge_region = cache.RegionForTest();
  const viewflow::background::Rect display{
      monitor.rcMonitor.left, monitor.rcMonitor.top, monitor.rcMonitor.right,
      monitor.rcMonitor.bottom};
  require_cache(display.contains(edge_region.bounds),
                "cache escaped display bounds");
  require_cache(edge_region.bounds.right == display.right &&
                    cached_nodes() == 4,
                "display edge cache not bound");
  const auto edge_pixel = read_sample(x + 256, y + 40);
  require_cache(abs(edge_pixel[0] - green[0]) <= 2 &&
                    abs(edge_pixel[1] - green[1]) <= 2 &&
                    abs(edge_pixel[2] - green[2]) <= 2,
                "display edge clipping changed background");
  std::printf(
      "background-test display-edge=%lld,%lld,%lld,%lld sample=%d,%d,%d\n",
      edge_region.bounds.left, edge_region.bounds.top, edge_region.bounds.right,
      edge_region.bounds.bottom, edge_pixel[0], edge_pixel[1], edge_pixel[2]);
  cache.Report(stdout);
  require_cache(GetForegroundWindow() == initial_foreground,
                "foreground changed during owned-window test");
  std::puts("PASS native background cache: worker helper full region, local "
            "update, resize, "
            "move, opaque-content "
            "loss/recovery; foreground_unchanged=1 input_injected=0");
  return 0;
}
} // namespace
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  FILE *log{};
  if (_wfreopen_s(&log, L"native-background-result.log", L"w", stdout))
    return 2;
  _dup2(_fileno(stdout), _fileno(stderr));
  setvbuf(stdout, nullptr, _IONBF, 0);
  try {
    return cache_oracle();
  } catch (winrt::hresult_error const &e) {
    std::fprintf(stdout, "stage=%s HRESULT=%08x %ls\n", stage,
                 unsigned(e.code()), e.message().c_str());
    return 1;
  } catch (std::exception const &e) {
    std::fprintf(stdout, "error=%s\n", e.what());
    return 1;
  }
}

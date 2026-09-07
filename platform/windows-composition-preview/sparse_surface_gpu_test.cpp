// Manual interactive-session GPU oracle. Only nonactivating tool windows;
// no keyboard/mouse injection or focus changes. Not registered as a CTest.
#define wmain viewflow_preview_entry_for_sparse_test
#include "main.cpp"
#undef wmain

static void require_sparse_test(bool condition,const char* reason) {
  if(!condition) throw std::runtime_error(reason);
}
static void pump_sparse_test() {
  for(unsigned i=0;i<50;++i) {
    MSG msg{};
    while(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)) { TranslateMessage(&msg);DispatchMessageW(&msg); }
    Sleep(10);
  }
  DwmFlush();
}
int wmain(int argc,wchar_t** argv) try {
  if(argc!=3) throw std::runtime_error("pass physical x y on an unused display");
  const int x=_wtoi(argv[1]),y=_wtoi(argv[2]);
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  init_apartment(apartment_type::single_threaded);
  DispatcherQueueOptions dq{sizeof(dq),DQTYPE_THREAD_CURRENT,DQTAT_COM_STA};
  com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;
  check_hresult(CreateDispatcherQueueController(dq,queue.put()));
  Compositor compositor;
  auto owner=foreground(compositor,512,256);
  auto first=foreground_on_device(owner,compositor,256,256);
  auto second=foreground_on_device(owner,compositor,256,256);
  WNDCLASSW cls{};cls.lpfnWndProc=DefWindowProcW;cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=L"ViewflowSparseSurfaceTest";
  require_sparse_test(RegisterClassW(&cls)!=0,"register test window");
  const HWND hwnd=CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW,
    cls.lpszClassName,L"ViewflowSparseSurfaceTest",WS_POPUP,x,y,512,256,nullptr,nullptr,cls.hInstance,nullptr);
  require_sparse_test(hwnd!=nullptr,"create nonactivating test window");
  auto interop=compositor.as<ABI::Windows::UI::Composition::Desktop::ICompositorDesktopInterop>();
  winrt::Windows::UI::Composition::Desktop::DesktopWindowTarget target{nullptr};
  check_hresult(interop->CreateDesktopWindowTarget(hwnd,true,
    reinterpret_cast<ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(put_abi(target))));
  auto root=compositor.CreateContainerVisual();
  auto background=compositor.CreateSpriteVisual();background.Size({512,256});
  background.Brush(compositor.CreateColorBrush(winrt::Windows::UI::Color{255,16,16,16}));
  root.Children().InsertAtBottom(background);root.Children().InsertAtTop(first.visual);
  second.visual.Offset({256,0,0});root.Children().InsertAtTop(second.visual);target.Root(root);
  const std::array<std::array<uint8_t,3>,8> colors={{{255,0,0},{0,255,0},{0,0,255},{255,255,255},
    {255,255,0},{0,255,255},{255,0,255},{128,128,128}}};
  std::vector<uint8_t> pixels(512*256*4);
  for(unsigned py=0;py<256;++py)for(unsigned px=0;px<512;++px) {
    const auto& c=colors[(py/128)*4+px/128];const auto i=(py*512+px)*4;
    pixels[i]=c[2];pixels[i+1]=c[1];pixels[i+2]=c[0];pixels[i+3]=255;
  }
  D3D11_TEXTURE2D_DESC desc{};desc.Width=512;desc.Height=256;desc.MipLevels=1;desc.ArraySize=1;
  desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_DEFAULT;
  desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
  D3D11_SUBRESOURCE_DATA data{pixels.data(),512*4,0};
  viewflow::windows::CompositedFrame frame;frame.frame_identity=1;frame.width=512;frame.height=256;
  check_hresult(owner.d3d->CreateTexture2D(&desc,&data,frame.premultiplied_bgra.GetAddressOf()));
  auto shared=stage_gpu_surface(owner,compositor,frame);
  std::vector<viewflow::vfgp::AtlasPatch> patches;
  for(unsigned tile=0;tile<2;++tile)for(unsigned cell=0;cell<4;++cell)
    patches.push_back({tile,(cell%2)*128,(cell/2)*128,cell*128,tile*128,128,128});
  auto a=stage_sparse_visuals(first,compositor,shared.surface,patches,0,256,256,nullptr);
  auto b=stage_sparse_visuals(second,compositor,shared.surface,patches,1,256,256,nullptr);
  commit_sparse_visuals(first,std::move(a),256,256);commit_sparse_visuals(second,std::move(b),256,256);
  require_sparse_test(!first.surface && !second.surface && !first.spare_surface && !second.spare_surface,
    "sparse proxy unexpectedly allocated a per-window pixel backing");
  ShowWindow(hwnd,SW_SHOWNOACTIVATE);
  pump_sparse_test();
  auto verify=[&](bool hidden) {
    HDC screen=GetDC(nullptr);require_sparse_test(screen!=nullptr,"screen readback");bool ok=true;
    for(unsigned tile=0;tile<2;++tile)for(unsigned cell=0;cell<4;++cell) {
      const auto got=GetPixel(screen,x+int(tile*256+(cell%2)*128+64),y+int((cell/2)*128+64));
      const auto want=hidden && tile==0 ? std::array<uint8_t,3>{16,16,16}:colors[tile*4+cell];
      const bool matched=got!=CLR_INVALID && abs(int(GetRValue(got))-want[0])<=8 &&
        abs(int(GetGValue(got))-want[1])<=8 && abs(int(GetBValue(got))-want[2])<=8;
      if(!matched)std::fprintf(stderr,"tile=%u cell=%u RGB=%u,%u,%u expected=%u,%u,%u\n",tile,cell,
        unsigned(GetRValue(got)),unsigned(GetGValue(got)),unsigned(GetBValue(got)),unsigned(want[0]),unsigned(want[1]),unsigned(want[2]));
      ok=ok&&matched;
    }
    ReleaseDC(nullptr,screen);return ok;
  };
  require_sparse_test(verify(false),"shared surface crop/placement did not match displayed pixels");
  patches.erase(patches.begin(),patches.begin()+4);
  auto hidden=stage_sparse_visuals(first,compositor,shared.surface,patches,0,256,256,nullptr);
  auto retained=stage_sparse_visuals(second,compositor,shared.surface,patches,1,256,256,nullptr);
  require_sparse_test(retained.reuse,"unchanged mapping did not reuse visual descriptors");
  commit_sparse_visuals(first,std::move(hidden),256,256);commit_sparse_visuals(second,std::move(retained),256,256);
  pump_sparse_test();require_sparse_test(verify(true),"hidden source retained stale pixels or altered its neighbor");
  DestroyWindow(hwnd);
  std::puts("PASS shared atlas display pixels, hidden/reveal mapping, independent visuals and zero per-window pixel backings");
  return 0;
} catch(const std::exception& e) { std::fprintf(stderr,"FAIL sparse surface: %s\n",e.what());return 1; }
  catch(const winrt::hresult_error& e) { std::fprintf(stderr,"FAIL sparse surface HRESULT=%08x\n",unsigned(e.code()));return 1; }

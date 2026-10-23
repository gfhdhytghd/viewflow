// Retained-alpha mask oracle using only owned, nonactivating test windows.
// Candidate retains alpha only; HostBackdrop remains live throughout.
// No mouse/keyboard injection and no focus-changing APIs. Not an automatic CTest.
#define wmain viewflow_preview_entry_for_host_test
#include "main.cpp"
#undef wmain
#include <io.h>
#include "sparse_visual_reference.h"

static LRESULT CALLBACK host_test_proc(HWND window,UINT message,WPARAM w,LPARAM l) {
  if(message==WM_MOUSEACTIVATE)return MA_NOACTIVATE;
  return DefWindowProcW(window,message,w,l);
}
static void host_require(bool value,const char* message) {if(!value)throw std::runtime_error(message);}
static void host_pump() {
  MSG m{};while(PeekMessageW(&m,nullptr,0,0,PM_REMOVE)){TranslateMessage(&m);DispatchMessageW(&m);}
  DwmFlush();Sleep(30);
}
static std::vector<uint8_t> host_read(int x,int y,int width,int height) {
  HDC screen=GetDC(nullptr),memory=screen?CreateCompatibleDC(screen):nullptr;
  BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth=width;info.bmiHeader.biHeight=-height;
  info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
  void* pixels=nullptr;
  HBITMAP bitmap=memory?CreateDIBSection(screen,&info,DIB_RGB_COLORS,&pixels,nullptr,0):nullptr;
  auto previous=bitmap?SelectObject(memory,bitmap):nullptr;
  const bool copied=bitmap && BitBlt(memory,0,0,width,height,screen,x,y,SRCCOPY|CAPTUREBLT);
  std::vector<uint8_t> result;
  if(copied)result.assign(static_cast<uint8_t*>(pixels),static_cast<uint8_t*>(pixels)+size_t(width)*height*4);
  if(previous)SelectObject(memory,previous);
  if(bitmap)DeleteObject(bitmap);
  if(memory)DeleteDC(memory);
  if(screen)ReleaseDC(nullptr,screen);
  host_require(copied,"owned rectangle readback failed");return result;
}
int wmain(int argc,wchar_t** argv) try {
  const bool calibrate=argc>1 && !wcscmp(argv[1],L"stale-mask");
  const bool baseline=argc>1 && !wcscmp(argv[1],L"baseline");
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  init_apartment(apartment_type::single_threaded);
  const HWND original_foreground=GetForegroundWindow();
  const auto active_monitor=MonitorFromWindow(original_foreground,MONITOR_DEFAULTTOPRIMARY);
  struct Display { HMONITOR monitor;RECT work;bool primary; };
  std::vector<Display> displays;
  EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR monitor,HDC,LPRECT,LPARAM context)->BOOL {
    MONITORINFO info{sizeof(info)};
    if(GetMonitorInfoW(monitor,&info))reinterpret_cast<std::vector<Display>*>(context)->push_back({monitor,info.rcWork,bool(info.dwFlags&MONITORINFOF_PRIMARY)});
    return TRUE;
  },reinterpret_cast<LPARAM>(&displays));
  auto selected=std::find_if(displays.begin(),displays.end(),[&](auto const& d){return d.monitor!=active_monitor && d.work.right-d.work.left>=1568 && d.work.bottom-d.work.top>=544;});
  if(selected==displays.end())selected=std::find_if(displays.begin(),displays.end(),[](auto const& d){return d.work.right-d.work.left>=1568 && d.work.bottom-d.work.top>=544;});
  host_require(selected!=displays.end(),"no display fits owned test rectangle");
  const int bx=selected->work.right-1552,by=selected->work.top+16,x=bx+128,y=by+128;
  std::printf("host-test placement=%d,%d panels=3x256x256 gap=256 nonactive_monitor=%u\n",x,y,unsigned(selected->monitor!=active_monitor));std::fflush(stdout);
  DispatcherQueueOptions options{sizeof(options),DQTYPE_THREAD_CURRENT,DQTAT_COM_STA};
  com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;
  check_hresult(CreateDispatcherQueueController(options,queue.put()));
  Compositor compositor;auto owner=foreground(compositor,512,256);
  auto reference=foreground_on_device(owner,compositor,256,256);
  auto candidate=foreground_on_device(owner,compositor,256,256);
  auto control=foreground_on_device(owner,compositor,256,256);
  WNDCLASSW cls{};cls.lpfnWndProc=host_test_proc;cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=L"ViewflowAlphaMaskOracle";
  host_require(RegisterClassW(&cls)!=0,"register owned test class");
  constexpr DWORD extended=WS_EX_NOREDIRECTIONBITMAP|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW;
  WindowOwner background{CreateWindowExW(extended,cls.lpszClassName,L"Viewflow owned test background",WS_POPUP,bx,by,1536,512,nullptr,nullptr,cls.hInstance,nullptr)};
  host_require(background.value!=nullptr,"create test background");
  WindowOwner overlay{CreateWindowExW(extended,cls.lpszClassName,L"Viewflow owned backdrop comparison",WS_POPUP,x,y,256,256,background.value,nullptr,cls.hInstance,nullptr)};
  host_require(overlay.value!=nullptr,"create test overlay");
  WindowOwner candidate_window{CreateWindowExW(extended,cls.lpszClassName,L"Viewflow owned candidate",WS_POPUP,x+512,y,256,256,background.value,nullptr,cls.hInstance,nullptr)};
  WindowOwner control_window{CreateWindowExW(extended,cls.lpszClassName,L"Viewflow owned control",WS_POPUP,x+1024,y,256,256,background.value,nullptr,cls.hInstance,nullptr)};
  host_require(candidate_window.value && control_window.value,"create comparison hosts");
  BOOL yes=TRUE;
  check_hresult(DwmSetWindowAttribute(overlay.value,DWMWA_USE_HOSTBACKDROPBRUSH,&yes,sizeof(yes)));
  check_hresult(DwmSetWindowAttribute(candidate_window.value,DWMWA_USE_HOSTBACKDROPBRUSH,&yes,sizeof(yes)));
  check_hresult(DwmSetWindowAttribute(control_window.value,DWMWA_USE_HOSTBACKDROPBRUSH,&yes,sizeof(yes)));
  DwmSetWindowAttribute(candidate_window.value,DWMWA_TRANSITIONS_FORCEDISABLED,&yes,sizeof(yes));
  DwmSetWindowAttribute(control_window.value,DWMWA_TRANSITIONS_FORCEDISABLED,&yes,sizeof(yes));
  DwmSetWindowAttribute(background.value,DWMWA_TRANSITIONS_FORCEDISABLED,&yes,sizeof(yes));
  DwmSetWindowAttribute(overlay.value,DWMWA_TRANSITIONS_FORCEDISABLED,&yes,sizeof(yes));
  auto interop=compositor.as<ABI::Windows::UI::Composition::Desktop::ICompositorDesktopInterop>();
  auto attach=[&](HWND window,ContainerVisual const& root) {
    winrt::Windows::UI::Composition::Desktop::DesktopWindowTarget target{nullptr};
    check_hresult(interop->CreateDesktopWindowTarget(window,true,reinterpret_cast<ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(put_abi(target))));
    target.Root(root);return target;
  };
  auto backdrop_root=compositor.CreateContainerVisual();backdrop_root.Size({1536,512});
  std::vector<CompositionColorBrush> stripes;
  for(unsigned i=0;i<48;++i) {
    auto brush=compositor.CreateColorBrush(winrt::Windows::UI::Color{255,40,90,200});stripes.push_back(brush);
    auto stripe=compositor.CreateSpriteVisual();stripe.Size({32,512});stripe.Offset({float(i*32),0,0});stripe.Brush(brush);backdrop_root.Children().InsertAtTop(stripe);
  }
  auto backdrop_target=attach(background.value,backdrop_root);
  auto root=compositor.CreateContainerVisual();root.Size({256,256});root.Children().InsertAtTop(reference.visual);
  auto candidate_root=compositor.CreateContainerVisual();candidate_root.Size({256,256});candidate_root.Children().InsertAtTop(candidate.visual);
  auto control_root=compositor.CreateContainerVisual();control_root.Size({256,256});control_root.Children().InsertAtTop(control.visual);
  auto target=attach(overlay.value,root);
  auto candidate_target=attach(candidate_window.value,candidate_root);
  auto control_target=attach(control_window.value,control_root);
  CompositionBrush raw=compositor.CreateHostBackdropBrush(),candidate_raw=compositor.CreateHostBackdropBrush();
  auto host_effect=[&](CompositionBrush const& source) {
    Blur blur;blur.sigma=12;blur.Source(CompositionEffectSourceParameter(L"backdrop"));
    auto brush=compositor.CreateEffectFactory(blur).CreateBrush();brush.SetSourceParameter(L"backdrop",source);return brush;
  };
  auto blurred=host_effect(raw),control_blurred=host_effect(compositor.CreateHostBackdropBrush());
  std::vector<viewflow::vfgp::AtlasPatch> patches{{0,0,0,0,0,128,128},{0,128,0,128,0,128,128},{0,0,128,256,0,128,128},{0,128,128,384,0,128,128}};
  std::vector<uint8_t> bytes(512*256*4);
  D3D11_TEXTURE2D_DESC desc{};desc.Width=512;desc.Height=256;desc.MipLevels=1;desc.ArraySize=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
  std::array<std::array<int,3>,2> reference_samples{},control_samples{};
  size_t blurred_difference=0,mask_updates=0;
  CompositionSurfaceBrush retained_mask{nullptr};
  std::vector<uint8_t> previous_alpha;
  for(unsigned phase=0;phase<12;++phase) {
    for(size_t i=0;i<stripes.size();++i) {
      auto color=phase==0?winrt::Windows::UI::Color{255,40,90,200}:winrt::Windows::UI::Color{255,200,70,40};
      if(phase>=2)color=i%2?winrt::Windows::UI::Color{255,20,60,210}:winrt::Windows::UI::Color{255,230,180,30};
      stripes[i].Color(color);
    }
    const uint8_t alpha=phase==4||phase==5?64:phase==6?192:128;
    for(size_t i=0;i<bytes.size();i+=4){bytes[i]=bytes[i+1]=bytes[i+2]=0;bytes[i+3]=alpha;}
    const std::array<uint8_t,3> marker{uint8_t(60+phase*10),30,uint8_t(210-phase*10)};
    for(unsigned py=0;py<16;++py)for(unsigned px=0;px<16;++px){auto i=(py*512+px)*4;std::copy(marker.begin(),marker.end(),bytes.begin()+i);bytes[i+3]=255;}
    if(phase==3){patches.erase(patches.begin()+1);for(size_t i=0;i<patches.size();++i){patches[i].x=uint32_t(i)*128;patches[i].y=0;}}
    D3D11_SUBRESOURCE_DATA data{bytes.data(),512*4,0};
    viewflow::windows::CompositedFrame frame;frame.frame_identity=phase+1;frame.width=512;frame.height=256;
    check_hresult(owner.d3d->CreateTexture2D(&desc,&data,frame.premultiplied_bgra.GetAddressOf()));
    auto surface=stage_gpu_surface(owner,compositor,frame);
    const float target_size=phase==8?192:phase==9||phase==10?128:256;
    const float shift=phase==10?0.25f:0;
    if(baseline)reference_commit_sparse_visuals(reference,reference_stage_sparse_visuals(reference,compositor,surface.surface,patches,0,256,256,blurred),target_size,target_size);
    else commit_sparse_visuals(reference,stage_sparse_visuals(reference,compositor,surface.surface,patches,0,256,256,raw,12),target_size,target_size);
    commit_sparse_visuals(candidate,stage_sparse_visuals(candidate,compositor,surface.surface,patches,0,256,256,candidate_raw,12),target_size,target_size);
    reference_commit_sparse_visuals(control,reference_stage_sparse_visuals(control,compositor,surface.surface,patches,0,256,256,control_blurred),target_size,target_size);
    std::vector<uint8_t> alpha_key(bytes.size()/4);
    for(size_t i=0;i<alpha_key.size();++i)alpha_key[i]=bytes[i*4+3];
    if(!retained_mask || baseline || (alpha_key!=previous_alpha && !(calibrate && phase>=4))) {
      retained_mask=compositor.CreateSurfaceBrush(surface.surface);
      retained_mask.Stretch(CompositionStretch::None);retained_mask.HorizontalAlignmentRatio(0);retained_mask.VerticalAlignmentRatio(0);
      previous_alpha=alpha_key;++mask_updates;
    }
    host_require(candidate.shared_sparse.has_value(),"candidate sparse scene missing");
    for(auto& [key,node]:candidate.shared_sparse->nodes)if(node.masked && !baseline)
      node.masked.SetSourceParameter(L"atlas",retained_mask);
    reference.sparse_root.Offset({shift,shift,0});candidate.shared_sparse->root.Offset({shift,shift,0});control.sparse_root.Offset({shift,shift,0});
    if(phase==0){ShowWindow(background.value,SW_SHOWNOACTIVATE);ShowWindow(overlay.value,SW_SHOWNOACTIVATE);ShowWindow(candidate_window.value,SW_SHOWNOACTIVATE);ShowWindow(control_window.value,SW_SHOWNOACTIVATE);}
    bool valid=false;size_t mismatches=0;
    std::array<int,3> last_reference{},last_candidate{},last_control{};
    auto until=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    while(std::chrono::steady_clock::now()<until) {
      host_pump();std::vector<uint8_t> pixels(768*256*4);
      for(unsigned panel=0;panel<3;++panel) {
        auto readback=host_read(x+int(panel*512),y,256,256);
        for(unsigned row=0;row<256;++row)std::copy_n(readback.data()+row*256*4,256*4,pixels.data()+(row*768+panel*256)*4);
      }
      auto sample=[&](unsigned panel,unsigned px,unsigned py,unsigned c){return int(pixels[(py*768+panel*256+px)*4+c]);};
      bool fresh=true;for(unsigned panel=0;panel<3;++panel)for(unsigned c=0;c<3;++c)if(abs(sample(panel,unsigned(8*target_size/256+shift),unsigned(8*target_size/256+shift),c)-marker[c])>2)fresh=false;
      // Third panel is also fully blurred; it is a fresh reference witness.
      for(unsigned c=0;c<3;++c){last_reference[c]=sample(0,64,64,c);last_candidate[c]=sample(1,64,64,c);last_control[c]=sample(2,64,64,c);}
      if(!fresh)continue;
      mismatches=0;for(unsigned py=0;py<256;++py)for(unsigned px=0;px<256;++px)for(unsigned c=0;c<3;++c)if(abs(sample(0,px,py,c)-sample(1,px,py,c))>2)++mismatches;
      if(mismatches)continue;
      if(phase<2)for(unsigned c=0;c<3;++c){reference_samples[phase][c]=sample(0,64,64,c);control_samples[phase][c]=sample(2,64,64,c);}
      if(phase==2)for(unsigned py=100;py<224;++py)for(unsigned px=32;px<224;++px) {
        const std::array<int,3> raw=((128+px)/32)%2?std::array<int,3>{210,60,20}:std::array<int,3>{30,180,230};
        for(unsigned c=0;c<3;++c)if(abs(sample(0,px,py,c)-raw[c]*127/255)>5)++blurred_difference;
      }
      valid=true;break;
    }
    std::printf("alpha-mask phase=%u alpha=%u mask_updates=%zu size=%.1f offset=%.2f\n",phase,unsigned(alpha),mask_updates,target_size,shift);
    std::printf("alpha-mask comparison current_reference=%u mask_reuse_enabled=%u\n",unsigned(!baseline),unsigned(!baseline));
    std::printf("host-test phase=%u verified=%u mismatched_channels=%zu foreground_unchanged=%u\n",phase,unsigned(valid),mismatches,unsigned(GetForegroundWindow()==original_foreground));std::fflush(stdout);
    std::printf("host-test calibration=%u sample_ref=%d,%d,%d sample_candidate=%d,%d,%d sample_control=%d,%d,%d\n",unsigned(calibrate),last_reference[0],last_reference[1],last_reference[2],last_candidate[0],last_candidate[1],last_candidate[2],last_control[0],last_control[1],last_control[2]);std::fflush(stdout);
    host_require(GetForegroundWindow()!=background.value && GetForegroundWindow()!=overlay.value && GetForegroundWindow()!=candidate_window.value && GetForegroundWindow()!=control_window.value,"owned test window acquired focus");
    host_require(valid,"physical HostBackdrop panels differ or are not visible");
  }
  int response=0;
  for(unsigned c=0;c<3;++c) {
    const int dr=reference_samples[1][c]-reference_samples[0][c],dc=control_samples[1][c]-control_samples[0][c];
    response=(std::max)(response,abs(2*dr-dc));
  }
  std::printf("host-test background_response=%d blurred_difference_channels=%zu\n",response,blurred_difference);
  host_require(response>20,"HostBackdrop did not track the owned background colors");
  host_require(blurred_difference>1000,"blurred host result did not differ from analytic unblurred colors");
  host_require(mask_updates==4,"unexpected mask refresh count");
  std::puts("PASS retained-alpha mask, live HostBackdrop reference/candidate equality, changing owned background, repacking; no input injection");
  return 0;
} catch(winrt::hresult_error const& e) {std::fprintf(stdout,"host-test HRESULT=%08x\n",unsigned(e.code()));return 1;}
  catch(std::exception const& e) {std::fprintf(stdout,"host-test error=%s\n",e.what());return 1;}

// GUI subsystem: the scheduled probe never needs a console window.
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
  FILE* log=nullptr;
  if(_wfreopen_s(&log,L"alpha-mask-result.log",L"w",stdout)!=0)return 2;
  _dup2(_fileno(stdout),_fileno(stderr));setvbuf(stdout,nullptr,_IONBF,0);
  int argc=0;auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);
  if(!argv)return 2;
  const int result=wmain(argc,argv);LocalFree(argv);std::printf("oracle-exit=%d\n",result);std::fflush(stdout);return result;
}

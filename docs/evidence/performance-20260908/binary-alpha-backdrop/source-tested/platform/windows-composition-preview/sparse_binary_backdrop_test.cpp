// Physical compositor oracle using only owned, nonactivating test windows.
// No mouse/keyboard injection and no focus-changing APIs. Not an automatic CTest.
#define wmain viewflow_preview_entry_for_binary_test
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
int wmain(int argc,wchar_t**) try {
  (void)argc;
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
  WNDCLASSW cls{};cls.lpfnWndProc=host_test_proc;cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=L"ViewflowBinaryBackdropOracle";
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
  auto raw=compositor.CreateHostBackdropBrush(),candidate_raw=compositor.CreateHostBackdropBrush();
  auto control_raw=compositor.CreateHostBackdropBrush();
  std::vector<viewflow::vfgp::AtlasPatch> patches{{0,0,0,0,0,128,128},{0,128,0,128,0,128,128},{0,0,128,256,0,128,128},{0,128,128,384,0,128,128}};
  struct Case { const char* name;uint8_t partial_alpha;float scale,offset;bool mute,negative_control; };
  const Case cases[]={
    {"binary-identity",0,1,0,true,false},
    {"binary-disjoint",0,1,0,true,false},
    {"binary-repacked",0,1,0,true,false},
    {"binary-scale075",0,.75f,0,false,true},
    {"binary-scale05",0,.5f,0,false,true},
    {"binary-offset025",0,1,.25f,false,true},
    {"alpha128-identity",128,1,0,false,true},
    {"alpha254-identity",254,1,0,false,true},
    {"alpha1-identity",1,1,0,false,true},
    {"binary-restored",0,1,0,true,false},
    {"preview-without-frame",0,.75f,0,false,true},
    {"preview-return-without-frame",0,1,0,true,false}
  };
  auto set_backdrops=[](Foreground& fg,bool mute){
    host_require(fg.shared_sparse.has_value(),"missing retained sparse scene");
    for(auto& [key,node]:fg.shared_sparse->nodes)if(node.background)node.background.Opacity(mute?0.0f:1.0f);
  };
  unsigned phase=0;
  std::array<uint8_t,3> marker{};
  std::vector<uint8_t> identity_snapshot;
  for(const auto& test:cases) {
    for(size_t i=0;i<stripes.size();++i)
      stripes[i].Color(i%2?winrt::Windows::UI::Color{255,20,60,210}:winrt::Windows::UI::Color{255,230,180,30});
    const bool preview_only=std::strstr(test.name,"without-frame")!=nullptr;
    if(!preview_only){
    patches={{0,0,0,0,0,128,128},{0,128,0,128,0,128,128},{0,0,128,256,0,128,128},{0,128,128,384,0,128,128}};
    if(std::strcmp(test.name,"binary-disjoint")==0)patches.erase(patches.begin()+2);
    if(std::strcmp(test.name,"binary-repacked")==0)for(auto& p:patches)p.x=384-p.x;
    std::vector<uint8_t> bytes(512*256*4);
    marker={uint8_t(80+phase*11),30,uint8_t(170-phase*11)};
    for(const auto& p:patches)for(unsigned py=0;py<p.height;++py)for(unsigned px=0;px<p.width;++px){
      const unsigned sx=p.source_x+px,sy=p.source_y+py;
      const bool hole=sx<3||sy<3||sx>=253||sy>=253||sx==101||sy==119||((sx/31+sy/27)%3==0);
      uint8_t alpha=hole?0:(test.partial_alpha?test.partial_alpha:255);
      std::array<uint8_t,3> rgb{70,150,110};
      if(sx>=8&&sx<40&&sy>=8&&sy<40){alpha=255;rgb=marker;}
      const auto i=((p.y+py)*512+p.x+px)*4;
      for(unsigned c=0;c<3;++c)bytes[i+c]=uint8_t((unsigned(rgb[c])*alpha+127)/255);
      bytes[i+3]=alpha;
    }
    D3D11_TEXTURE2D_DESC desc{};desc.Width=512;desc.Height=256;desc.MipLevels=1;desc.ArraySize=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
    D3D11_SUBRESOURCE_DATA data{bytes.data(),512*4,0};
    viewflow::windows::CompositedFrame frame;frame.frame_identity=phase+1;frame.width=512;frame.height=256;
    check_hresult(owner.d3d->CreateTexture2D(&desc,&data,frame.premultiplied_bgra.GetAddressOf()));
    auto surface=stage_gpu_surface(owner,compositor,frame);
    std::vector<uint8_t> alpha(bytes.size()/4);
    for(size_t i=0;i<alpha.size();++i)alpha[i]=bytes[i*4+3];
    const auto binary=viewflow::windows_preview::BinarySparseTiles(alpha,512,256,patches,1);
    host_require(binary.size()==1,"binary tile classification missing");
    // Reference keeps the complete production effect. Candidate uses the same
    // classifier and resize function as the receiver, including cached plans.
    for(auto* fg:{&reference,&candidate,&control}){
      fg->visual.Offset({test.offset,test.offset,0});
      auto backdrop=fg==&reference?raw:(fg==&candidate?candidate_raw:control_raw);
      const bool eligible=fg!=&reference && binary[0];
      commit_sparse_visuals(*fg,stage_sparse_visuals(*fg,compositor,surface.surface,patches,0,256,256,backdrop,12,{},eligible),256*test.scale,256*test.scale);
    }
    }else{
      for(auto* fg:{&reference,&candidate,&control})resize_sparse_preview(*fg,256*test.scale,256*test.scale);
    }
    // Deliberately wrong for negative cases, so equality cannot pass just
    // because the owned backdrop is absent or visually inactive.
    set_backdrops(control,true);
    host_require(candidate.sparse_backdrop_muted==test.mute,"production eligibility disagrees with case");
    if(phase==0){ShowWindow(background.value,SW_SHOWNOACTIVATE);ShowWindow(overlay.value,SW_SHOWNOACTIVATE);ShowWindow(candidate_window.value,SW_SHOWNOACTIVATE);ShowWindow(control_window.value,SW_SHOWNOACTIVATE);}
    bool valid=false;size_t mismatch=0,control_difference=0;int max_difference=0,control_max=0;
    std::vector<uint8_t> last;
    auto until=std::chrono::steady_clock::now()+std::chrono::seconds(4);
    while(std::chrono::steady_clock::now()<until){
      host_pump();std::vector<uint8_t> pixels(768*256*4);
      for(unsigned panel=0;panel<3;++panel){
        auto readback=host_read(x+int(panel*512),y,256,256);
        for(unsigned row=0;row<256;++row)std::copy_n(readback.data()+row*256*4,256*4,pixels.data()+(row*768+panel*256)*4);
      }
      auto sample=[&](unsigned panel,unsigned px,unsigned py,unsigned c){return int(pixels[(py*768+panel*256+px)*4+c]);};
      const unsigned center=unsigned(20*test.scale+test.offset);
      bool fresh=true;for(unsigned panel=0;panel<3;++panel)for(unsigned c=0;c<3;++c)
        if(abs(sample(panel,center,center,c)-marker[c])>2)fresh=false;
      if(!fresh)continue;
      mismatch=control_difference=0;max_difference=control_max=0;
      for(unsigned py=0;py<256;++py)for(unsigned px=0;px<256;++px)for(unsigned c=0;c<3;++c){
        const auto diff=abs(sample(0,px,py,c)-sample(1,px,py,c));
        const auto cd=abs(sample(0,px,py,c)-sample(2,px,py,c));
        if(diff>2)++mismatch;max_difference=std::max(max_difference,diff);
        if(cd>0)++control_difference;control_max=std::max(control_max,cd);
      }
      last=std::move(pixels);
      if(mismatch || (test.negative_control && control_difference<32))continue;
      if(!test.negative_control && control_difference!=0)continue;
      if(std::strcmp(test.name,"preview-return-without-frame")==0 && last!=identity_snapshot)continue;
      valid=true;break;
    }
    if(valid && std::strcmp(test.name,"binary-restored")==0)identity_snapshot=last;
    std::printf("binary-backdrop phase=%u case=%s mute=%u verified=%u mismatched_channels=%zu max_difference=%d control_differing_channels=%zu control_max=%d foreground_unchanged=%u\n",phase,test.name,unsigned(test.mute),unsigned(valid),mismatch,max_difference,control_difference,control_max,unsigned(GetForegroundWindow()==original_foreground));std::fflush(stdout);
    if(!last.empty()){
      char name[128]{};std::snprintf(name,sizeof(name),"binary-backdrop-%02u.ppm",phase);FILE* dump=nullptr;fopen_s(&dump,name,"wb");
      if(dump){std::fprintf(dump,"P6\n768 256\n255\n");for(size_t i=0;i<last.size();i+=4){const uint8_t rgb[]{last[i+2],last[i+1],last[i]};std::fwrite(rgb,1,3,dump);}std::fclose(dump);}
    }
    host_require(GetForegroundWindow()==original_foreground,"foreground changed");
    host_require(valid,"binary backdrop equality/control failed");++phase;
  }
  std::puts("PASS production binary alpha elision, topology/repacking, fractional fallbacks and resize without new frame; no input injection");
  return 0;
} catch(winrt::hresult_error const& e){std::fprintf(stderr,"binary-test HRESULT=%08x\n",unsigned(e.code()));return 1;}
  catch(std::exception const& e){std::fprintf(stderr,"binary-test error=%s\n",e.what());return 1;}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int){
  FILE* log=nullptr;if(_wfreopen_s(&log,L"binary-backdrop-result.log",L"w",stdout)!=0)return 2;
  _dup2(_fileno(stdout),_fileno(stderr));setvbuf(stdout,nullptr,_IONBF,0);
  return wmain(1,nullptr);
}

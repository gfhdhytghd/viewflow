// Independent presentation probe. Owns one nonactivating 4K-content window.
// This is not a Viewflow backend or an input-to-photon acceptance test.
#include <windows.h>
#include <shellapi.h>
#include <DispatcherQueue.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#define INITGUID
#include <initguid.h>
#include <d2d1_3.h>
#include <dcomp.h>
#include <dwmapi.h>
#include <windows.graphics.effects.interop.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.Effects.h>
#include <dxgi1_2.h>
#include <windows.ui.composition.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.UI.Composition.h>
#include <winrt/Windows.UI.Composition.Desktop.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cwchar>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>
#include "windows_observer_timer.h"
using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Graphics::Effects;
using namespace winrt::Windows::UI::Composition;
using namespace winrt::Windows::UI::Composition::Desktop;
#include "../platform/windows-composition-preview/atlas_record.h"
#include "../platform/windows-composition-preview/sparse_shared_visuals.h"
namespace {
constexpr UINT width=3848, height=2408;
struct Window {
  HWND value{};
  ~Window(){if(value)DestroyWindow(value);}
};
struct Handle {
  HANDLE value{};
  ~Handle(){if(value)CloseHandle(value);}
};
struct Timing {
  uint32_t frame{};
  int64_t render{}, drawn{}, begin{}, copied{}, ended{}, mutation{}, committed{};
};
int64_t qpc(){LARGE_INTEGER value{};if(!QueryPerformanceCounter(&value))throw_last_error();return value.QuadPart;}
LRESULT CALLBACK window_proc(HWND window,UINT message,WPARAM w,LPARAM l){
  if(message==WM_MOUSEACTIVATE)return MA_NOACTIVATE;
  if(message==WM_ERASEBKGND)return 1;
  if(message==WM_PAINT){PAINTSTRUCT p{};BeginPaint(window,&p);EndPaint(window,&p);return 0;}
  return DefWindowProcW(window,message,w,l);
}
struct Renderer {
  com_ptr<ID3D11Device> device;
  com_ptr<ID3D11DeviceContext> context;
  com_ptr<ID3D11Texture2D> source;
  com_ptr<ID3D11RenderTargetView> rtv;
  com_ptr<ID3D11VertexShader> vs;
  com_ptr<ID3D11PixelShader> ps;
  com_ptr<ID3D11Buffer> constants;
  explicit Renderer(HMONITOR monitor,FILE* log){
    com_ptr<IDXGIFactory1> factory;check_hresult(CreateDXGIFactory1(__uuidof(IDXGIFactory1),factory.put_void()));
    com_ptr<IDXGIAdapter1> selected;
    for(UINT a=0;!selected;++a){
      com_ptr<IDXGIAdapter1> adapter;
      const auto hr=factory->EnumAdapters1(a,adapter.put());
      if(hr==DXGI_ERROR_NOT_FOUND)break;check_hresult(hr);
      for(UINT o=0;;++o){
        com_ptr<IDXGIOutput> output;
        const auto status=adapter->EnumOutputs(o,output.put());
        if(status==DXGI_ERROR_NOT_FOUND)break;check_hresult(status);
        DXGI_OUTPUT_DESC desc{};check_hresult(output->GetDesc(&desc));
        if(desc.Monitor==monitor){selected=adapter;break;}
      }
    }
    if(!selected)throw hresult_error(E_FAIL,L"monitor adapter unavailable");
    DXGI_ADAPTER_DESC1 desc{};check_hresult(selected->GetDesc1(&desc));
    if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)throw hresult_error(E_FAIL,L"hardware adapter required");
    std::fprintf(log,"probe-adapter vendor=%u device=%u luid_high=%ld luid_low=%lu software=0\n",desc.VendorId,desc.DeviceId,desc.AdapterLuid.HighPart,desc.AdapterLuid.LowPart);
    check_hresult(D3D11CreateDevice(selected.get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr,0,D3D11_SDK_VERSION,device.put(),nullptr,context.put()));
    D3D11_TEXTURE2D_DESC texture{};texture.Width=width;texture.Height=height;texture.MipLevels=1;texture.ArraySize=1;
    texture.Format=DXGI_FORMAT_B8G8R8A8_UNORM;texture.SampleDesc.Count=1;texture.Usage=D3D11_USAGE_DEFAULT;texture.BindFlags=D3D11_BIND_RENDER_TARGET;
    check_hresult(device->CreateTexture2D(&texture,nullptr,source.put()));
    check_hresult(device->CreateRenderTargetView(source.get(),nullptr,rtv.put()));
    const char* shader=R"HLSL(
cbuffer Frame:register(b0){uint frame;uint padding0;uint padding1;uint padding2;};
float4 vertex(uint id:SV_VertexID):SV_Position {float2 p=float2((id<<1)&2,id&2);return float4(p*float2(2,-2)+float2(-1,1),0,1);}
float4 pixel(float4 position:SV_Position):SV_Target {
 float2 p=position.xy-float2(4,4);
 if(any(p<0)||p.x>=3840||p.y>=2400)return float4(0,0,0,0);
 float x=p.x+(frame%4096)*5.0,y=p.y+(frame%4096)*2.0;
 float checker=fmod(floor(x/96)+floor(y/96),2);
 float3 bg=lerp(float3(.09,.18,.3),float3(.72,.83,.93),checker)*(.65+.35*p.x/3840);
 if(fmod(p.y+(frame%512)*7.0,512)<24)bg=float3(.9,.24,.08);
 if(p.x>=32&&p.x<2080&&p.y>=32&&p.y<96){
  uint cell=(uint)((p.x-32)/32),check=(frame^(frame>>16)^0xA65C)&65535,bit;
  if(cell<32)bit=(frame>>(31-cell))&1;
  else if(cell<48)bit=0;
  else bit=(check>>(63-cell))&1;
  bg=bit?float3(.96,.96,.96):float3(.04,.04,.04);
 }
 return float4(bg,1);
})HLSL";
    auto compile=[&](const char* entry,const char* target){
      com_ptr<ID3DBlob> code,errors;
      const HRESULT status=D3DCompile(shader,std::strlen(shader),nullptr,nullptr,nullptr,entry,target,D3DCOMPILE_OPTIMIZATION_LEVEL3,0,code.put(),errors.put());
      if(FAILED(status)&&errors)std::fprintf(log,"shader-error %s\n",static_cast<const char*>(errors->GetBufferPointer()));
      check_hresult(status);return code;
    };
    auto v=compile("vertex","vs_5_0"),p=compile("pixel","ps_5_0");
    check_hresult(device->CreateVertexShader(v->GetBufferPointer(),v->GetBufferSize(),nullptr,vs.put()));
    check_hresult(device->CreatePixelShader(p->GetBufferPointer(),p->GetBufferSize(),nullptr,ps.put()));
    D3D11_BUFFER_DESC buffer{};buffer.ByteWidth=16;buffer.Usage=D3D11_USAGE_DEFAULT;buffer.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
    check_hresult(device->CreateBuffer(&buffer,nullptr,constants.put()));
  }
  void draw(uint32_t frame){
    const std::array<uint32_t,4> data{frame,0,0,0};context->UpdateSubresource(constants.get(),0,nullptr,data.data(),0,0);
    ID3D11Buffer* cb=constants.get();context->PSSetConstantBuffers(0,1,&cb);
    ID3D11RenderTargetView* target=rtv.get();context->OMSetRenderTargets(1,&target,nullptr);
    D3D11_VIEWPORT viewport{0,0,float(width),float(height),0,1};context->RSSetViewports(1,&viewport);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);context->IASetInputLayout(nullptr);
    context->VSSetShader(vs.get(),nullptr,0);context->PSSetShader(ps.get(),nullptr,0);context->Draw(3,0);
    context->OMSetRenderTargets(0,nullptr,nullptr);
  }
  void copy(ID3D11Texture2D* destination,POINT offset){
    D3D11_TEXTURE2D_DESC desc{};destination->GetDesc(&desc);
    if(offset.x<0||offset.y<0||uint64_t(offset.x)+width>desc.Width||uint64_t(offset.y)+height>desc.Height)
      throw hresult_error(E_FAIL,L"drawing surface extent mismatch");
    D3D11_BOX box{0,0,0,width,height,1};context->CopySubresourceRegion(destination,0,UINT(offset.x),UINT(offset.y),0,source.get(),0,&box);
  }
};
struct Wuc {
  Compositor compositor;
  DesktopWindowTarget target{nullptr};
  CompositionGraphicsDevice graphics{nullptr};
  SpriteVisual visual{nullptr};
  com_ptr<ID2D1Device> d2d;
  std::array<CompositionDrawingSurface,2> surfaces{nullptr,nullptr};
  std::array<CompositionSurfaceBrush,2> brushes{nullptr,nullptr};
  std::optional<SharedSparseScene> scene;
  std::vector<viewflow::vfgp::AtlasPatch> patches;
  std::vector<uint8_t> opacity;
  Wuc(HWND window,Renderer& renderer,const std::wstring& mode){
    auto dxgi=renderer.device.as<IDXGIDevice>();check_hresult(D2D1CreateDevice(dxgi.get(),nullptr,d2d.put()));
    auto interop=compositor.as<ABI::Windows::UI::Composition::ICompositorInterop>();
    check_hresult(interop->CreateGraphicsDevice(d2d.get(),reinterpret_cast<ABI::Windows::UI::Composition::ICompositionGraphicsDevice**>(put_abi(graphics))));
    auto desktop=compositor.as<ABI::Windows::UI::Composition::Desktop::ICompositorDesktopInterop>();
    check_hresult(desktop->CreateDesktopWindowTarget(window,true,reinterpret_cast<ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(put_abi(target))));
    visual=compositor.CreateSpriteVisual();visual.Size({float(width),float(height)});target.Root(visual);
    for(size_t i=0;i<surfaces.size();++i){
      surfaces[i]=graphics.CreateDrawingSurface({float(width),float(height)},winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,winrt::Windows::Graphics::DirectX::DirectXAlphaMode::Premultiplied);
      brushes[i]=compositor.CreateSurfaceBrush(surfaces[i]);brushes[i].Stretch(CompositionStretch::Fill);
    }
    if(mode==L"sparse"||mode==L"elided"){
      // Five coalesced regions: four boundary strips retain the production
      // backdrop effect; the solid center already elides it.
      patches={{0,0,0,0,0,width,128},{0,0,128,0,128,128,height-256},
        {0,128,128,128,128,width-256,height-256},
        {0,width-128,128,width-128,128,128,height-256},
        {0,0,height-128,0,height-128,width,128}};
      opacity=mode==L"elided"?std::vector<uint8_t>{1,1,1,1,1}:std::vector<uint8_t>{0,0,1,0,0};
      scene=make_shared_sparse_scene(compositor,surfaces[0],patches,compositor.CreateHostBackdropBrush(),12,opacity);
      visual.Children().InsertAtTop(scene->root);
    }
  }
  void submit(Renderer& renderer,Timing& t){
    const auto index=t.frame%2;auto drawing=surfaces[index].as<ABI::Windows::UI::Composition::ICompositionDrawingSurfaceInterop>();
    com_ptr<ID3D11Texture2D> destination;POINT offset{};t.begin=qpc();
    check_hresult(drawing->BeginDraw(nullptr,__uuidof(ID3D11Texture2D),destination.put_void(),&offset));
    try{renderer.copy(destination.get(),offset);t.copied=qpc();}catch(...){drawing->EndDraw();throw;}
    check_hresult(drawing->EndDraw());renderer.context->Flush();t.ended=qpc();
    t.mutation=qpc();
    if(scene)scene->brush.Surface(surfaces[index]);else visual.Brush(brushes[index]);
    t.committed=qpc();
  }
};
struct Dcomp {
  com_ptr<IDCompositionDevice> device;
  com_ptr<IDCompositionTarget> target;
  com_ptr<IDCompositionVisual> visual;
  std::array<com_ptr<IDCompositionSurface>,2> surfaces;
  Dcomp(HWND window,Renderer& renderer){
    auto dxgi=renderer.device.as<IDXGIDevice>();check_hresult(DCompositionCreateDevice(dxgi.get(),__uuidof(IDCompositionDevice),device.put_void()));
    check_hresult(device->CreateTargetForHwnd(window,TRUE,target.put()));
    check_hresult(device->CreateVisual(visual.put()));check_hresult(target->SetRoot(visual.get()));
    for(auto& surface:surfaces)check_hresult(device->CreateSurface(width,height,DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_ALPHA_MODE_PREMULTIPLIED,surface.put()));
  }
  void submit(Renderer& renderer,Timing& t){
    auto& drawing=surfaces[t.frame%2];com_ptr<ID3D11Texture2D> destination;POINT offset{};t.begin=qpc();
    check_hresult(drawing->BeginDraw(nullptr,__uuidof(ID3D11Texture2D),destination.put_void(),&offset));
    try{renderer.copy(destination.get(),offset);t.copied=qpc();}catch(...){drawing->EndDraw();throw;}
    check_hresult(drawing->EndDraw());renderer.context->Flush();t.ended=qpc();
    t.mutation=qpc();check_hresult(visual->SetContent(drawing.get()));check_hresult(device->Commit());t.committed=qpc();
  }
};
int run(const std::wstring& mode,UINT duration,FILE* log){
  const bool direct=mode==L"dcomp";
  init_apartment(apartment_type::single_threaded);
  DispatcherQueueOptions options{sizeof(options),DQTYPE_THREAD_CURRENT,DQTAT_COM_STA};
  com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;check_hresult(CreateDispatcherQueueController(options,queue.put()));
  LARGE_INTEGER frequency{};if(!QueryPerformanceFrequency(&frequency))throw_last_error();
  HWND foreground_before=GetForegroundWindow();
  std::fprintf(log,"probe mode=%s qpc_frequency=%lld duration_ms=%u width=%u height=%u surfaces=2 input_injected=0 foreground_before=%llu\n",to_string(mode).c_str(),frequency.QuadPart,duration,width,height,(unsigned long long)(uintptr_t)foreground_before);
  struct Monitor {HMONITOR value{};RECT rect{};} monitor;
  EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR m,HDC,LPRECT rect,LPARAM data)->BOOL{
    if(rect->right-rect->left>=3840&&rect->bottom-rect->top>=2400){auto& found=*reinterpret_cast<Monitor*>(data);found.value=m;found.rect=*rect;return FALSE;}return TRUE;
  },reinterpret_cast<LPARAM>(&monitor));
  if(!monitor.value)throw hresult_error(E_FAIL,L"4K content output unavailable");
  WNDCLASSW cls{};cls.hInstance=GetModuleHandleW(nullptr);cls.lpfnWndProc=window_proc;cls.lpszClassName=L"ViewflowAtlasProxy";
  if(!RegisterClassW(&cls)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS)throw_last_error();
  Window window;
  window.value=CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW,cls.lpszClassName,L"Viewflow owned composition latency probe",WS_POPUP,monitor.rect.left-4,monitor.rect.top-4,width,height,nullptr,nullptr,cls.hInstance,nullptr);
  if(!window.value)throw_last_error();
  const bool host_flag=mode==L"hostflag"||mode==L"sparse"||mode==L"elided";
  if(host_flag){BOOL enabled=TRUE;check_hresult(DwmSetWindowAttribute(window.value,DWMWA_USE_HOSTBACKDROPBRUSH,&enabled,sizeof(enabled)));}
  std::fprintf(log,"probe-scene host_flag=%u sparse=%u backgrounds=%u diagnostic_elision=%u\n",unsigned(host_flag),unsigned(mode==L"sparse"||mode==L"elided"),mode==L"sparse"?4u:0u,unsigned(mode==L"elided"));
  Renderer renderer(monitor.value,log);
  std::unique_ptr<Wuc> wuc;std::unique_ptr<Dcomp> dcomp;
  if(direct)dcomp=std::make_unique<Dcomp>(window.value,renderer);else wuc=std::make_unique<Wuc>(window.value,renderer,mode);
  const auto timer_flags=CREATE_WAITABLE_TIMER_HIGH_RESOLUTION;
  Handle timer{CreateWaitableTimerExW(nullptr,nullptr,timer_flags,TIMER_MODIFY_STATE|SYNCHRONIZE)};
  bool highres=timer.value!=nullptr;
  if(!timer.value)timer.value=CreateWaitableTimerExW(nullptr,nullptr,0,TIMER_MODIFY_STATE|SYNCHRONIZE);
  if(!timer.value)throw_last_error();
  std::fprintf(log,"probe-ready pid=%lu hwnd=%llu high_resolution_timer=%u monitor=%ld,%ld,%ld,%ld\n",GetCurrentProcessId(),(unsigned long long)(uintptr_t)window.value,unsigned(highres),monitor.rect.left,monitor.rect.top,monitor.rect.right,monitor.rect.bottom);std::fflush(log);
  std::vector<Timing> timings;timings.reserve(duration/10+64);
  const int64_t start=qpc(),period=frequency.QuadPart/60;int64_t next=start;uint32_t frame=0;uint64_t missed=0;
  for(;;){
    MSG message{};while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){if(message.message==WM_QUIT)throw hresult_error(E_ABORT,L"unexpected quit");TranslateMessage(&message);DispatchMessageW(&message);}
    const auto now=qpc();if((now-start)*1000/frequency.QuadPart>=duration)break;
    if(now<next){
      LARGE_INTEGER due{};due.QuadPart=-std::max<int64_t>(1,(next-now)*10000000/frequency.QuadPart);
      if(!SetWaitableTimer(timer.value,&due,0,nullptr,nullptr,FALSE))throw_last_error();
      if(MsgWaitForMultipleObjectsEx(1,&timer.value,INFINITE,QS_ALLINPUT,MWMO_INPUTAVAILABLE)==WAIT_FAILED)throw_last_error();
      continue;
    }
    Timing t;t.frame=++frame;t.render=qpc();renderer.draw(t.frame);t.drawn=qpc();
    if(direct)dcomp->submit(renderer,t);else wuc->submit(renderer,t);
    check_hresult(renderer.device->GetDeviceRemovedReason());timings.push_back(t);
    if(frame==1)ShowWindow(window.value,SW_SHOWNOACTIVATE);
    next+=period;
    const auto finished=qpc();if(finished>=next+period){const auto skipped=(finished-next)/period;missed+=uint64_t(skipped);next+=skipped*period;}
  }
  const auto finished=qpc();
  for(const auto& t:timings)std::fprintf(log,"probe-frame frame=%u render_qpc=%lld drawn_qpc=%lld begin_qpc=%lld copied_qpc=%lld ended_qpc=%lld mutation_qpc=%lld committed_qpc=%lld\n",t.frame,t.render,t.drawn,t.begin,t.copied,t.ended,t.mutation,t.committed);
  std::fprintf(log,"probe-result frames=%u elapsed_qpc=%lld missed_periods=%llu foreground_after=%llu foreground_unchanged=%u physical_present_receipt=false\n",frame,finished-start,(unsigned long long)missed,(unsigned long long)(uintptr_t)GetForegroundWindow(),unsigned(GetForegroundWindow()==foreground_before));
  return 0;
}
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int){
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  int argc{};auto args=CommandLineToArgvW(GetCommandLineW(),&argc);if(!args||argc!=4)return 2;
  const std::wstring mode=args[1],path=args[3];wchar_t* end{};auto duration=wcstoul(args[2],&end,10);
  const bool valid=(mode==L"winrt"||mode==L"dcomp"||mode==L"hostflag"||mode==L"sparse"||mode==L"elided")&&end&&!*end&&duration>=1000&&duration<=60000;LocalFree(args);if(!valid)return 2;
  FILE* log{};if(_wfopen_s(&log,path.c_str(),L"w")||!log)return 3;
  int result=1;
  try{ObserverTimer timer(true,log);result=run(mode,UINT(duration),log);}
  catch(const hresult_error& e){std::fprintf(log,"probe-error hr=%08lx message=%s\n",static_cast<unsigned long>(e.code().value),to_string(e.message()).c_str());}
  catch(...){std::fprintf(log,"probe-error unknown=1\n");}
  std::fprintf(log,"exit=%d\n",result);std::fclose(log);return result;
}

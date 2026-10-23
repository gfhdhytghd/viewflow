// Full-glass mask invalidation probe. Owns one nonactivating 4K-content window.
// Alpha is constant; compare per-frame color surface vs retained alpha source.
// Both modes retain all four backgrounds and live HostBackdrop sigma=12.
// This is not a Viewflow backend or an input-to-photon acceptance test.
#include <windows.h>
#include <windows.graphics.directx.direct3d11.interop.h>

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

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Graphics::Effects;
using namespace winrt::Windows::UI::Composition;
using namespace winrt::Windows::UI::Composition::Desktop;
#include "atlas_record.h"
#include "sparse_shared_visuals.h"

#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <chrono>
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
LRESULT CALLBACK wnd(HWND h,UINT m,WPARAM w,LPARAM l){if(m==WM_MOUSEACTIVATE)return MA_NOACTIVATE;if(m==WM_ERASEBKGND)return 1;if(m==WM_PAINT){PAINTSTRUCT p{};BeginPaint(h,&p);EndPaint(h,&p);return 0;}return DefWindowProcW(h,m,w,l);}
struct OwnedWindow{HWND h{};~OwnedWindow(){if(h)DestroyWindow(h);}};
int run(FILE* log){
 init_apartment(apartment_type::single_threaded);
 DispatcherQueueOptions opt{sizeof(opt),DQTYPE_THREAD_CURRENT,DQTAT_COM_STA};
 com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;check_hresult(CreateDispatcherQueueController(opt,queue.put()));
 Compositor c;auto desktop=c.as<ABI::Windows::UI::Composition::Desktop::ICompositorDesktopInterop>();
 HWND before=GetForegroundWindow();
 WNDCLASSW wc{};wc.hInstance=GetModuleHandleW(nullptr);wc.lpfnWndProc=wnd;wc.lpszClassName=L"ViewflowBackgroundBufferProbe";if(!RegisterClassW(&wc))throw_last_error();
 RECT bounds{};GetWindowRect(GetDesktopWindow(),&bounds);
 OwnedWindow back,front;
 auto create=[&](const wchar_t* title){auto h=CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW,wc.lpszClassName,title,WS_POPUP,bounds.left+64,bounds.top+64,256,256,nullptr,nullptr,wc.hInstance,nullptr);if(!h)throw_last_error();return h;};
 back.h=create(L"Viewflow owned background fixture");front.h=create(L"Viewflow background buffer probe");
 BOOL yes=TRUE;check_hresult(DwmSetWindowAttribute(front.h,DWMWA_USE_HOSTBACKDROPBRUSH,&yes,sizeof(yes)));
 DesktopWindowTarget bt{nullptr},ft{nullptr};
 check_hresult(desktop->CreateDesktopWindowTarget(back.h,true,reinterpret_cast<ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(put_abi(bt))));
 check_hresult(desktop->CreateDesktopWindowTarget(front.h,true,reinterpret_cast<ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(put_abi(ft))));
 SetWindowPos(back.h,nullptr,bounds.left+64,bounds.top+64,512,512,SWP_NOZORDER|SWP_NOACTIVATE);SetWindowPos(front.h,nullptr,bounds.left+192,bounds.top+192,256,256,SWP_NOZORDER|SWP_NOACTIVATE);
 auto bg=c.CreateSpriteVisual();bg.Size({512,512});auto color=c.CreateColorBrush({255,220,30,50});bg.Brush(color);bt.Root(bg);
 auto root=c.CreateContainerVisual();root.Size({256,256});ft.Root(root);
 auto parent=c.CreateContainerVisual();parent.Size({256,256});root.Children().InsertAtTop(parent);
 auto child=c.CreateSpriteVisual();child.Size({256,256});parent.Children().InsertAtTop(child);
 SparsePrototypeBlur effect;effect.sigma=12;effect.Source(CompositionEffectSourceParameter(L"background"));
 auto blur=c.CreateEffectFactory(effect).CreateBrush();blur.SetSourceParameter(L"background",c.CreateHostBackdropBrush());
 com_ptr<ID3D11Device> d3d;com_ptr<ID3D11DeviceContext> ctx;
 check_hresult(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,d3d.put(),nullptr,ctx.put()));
 winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice device{nullptr};auto dxgi=d3d.as<IDXGIDevice>();
 check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(),reinterpret_cast<::IInspectable**>(put_abi(device))));
 ShowWindow(back.h,SW_SHOWNOACTIVATE);ShowWindow(front.h,SW_SHOWNOACTIVATE);
 SpriteVisual local{nullptr};
 for(unsigned phase=0;phase<10;++phase){
  parent.Opacity((phase==2||phase==6||phase==7||phase==8)?0.0f:1.0f);
  child.Brush(phase==0?CompositionBrush(color):CompositionBrush(blur));
  if(local){root.Children().Remove(local);local=nullptr;}
  if(phase>=8){child.Size({512,512});child.Offset({-128,-128,0});}
  if(phase==4){local=c.CreateSpriteVisual();local.Size({256,256});local.Brush(color);root.Children().InsertAtBottom(local);blur.SetSourceParameter(L"background",c.CreateBackdropBrush());}else blur.SetSourceParameter(L"background",c.CreateHostBackdropBrush());
  auto item=GraphicsCaptureItem::CreateFromVisual((phase==3||phase==4)?Visual(root):Visual(child));
  auto pool=Direct3D11CaptureFramePool::CreateFreeThreaded(device,DirectXPixelFormat::B8G8R8A8UIntNormalized,2,item.Size());
  auto session=pool.CreateCaptureSession(item);session.IsCursorCaptureEnabled(false);session.MinUpdateInterval(std::chrono::milliseconds(33));session.StartCapture();
  unsigned frames=0,ticks=0;bool changed=false;auto start=std::chrono::steady_clock::now();
  while(std::chrono::steady_clock::now()-start<std::chrono::seconds(3)){
   MSG m{};while(PeekMessageW(&m,nullptr,0,0,PM_REMOVE)){TranslateMessage(&m);DispatchMessageW(&m);}
   auto elapsed=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-start).count();
   if(elapsed>=1500&&!changed){changed=true;color.Color({255,30,210,90});}
   if((phase==3||phase>=5)&&elapsed>=ticks*67){++ticks;if(phase==3||phase>=7)child.Offset({(phase>=8?-128.0f:0)+float(ticks%2)*0.01f,phase>=8?-128.0f:0,0});else {auto next=c.CreateEffectFactory(effect).CreateBrush();next.SetSourceParameter(L"background",c.CreateHostBackdropBrush());child.Brush(next);}}
   auto frame=pool.TryGetNextFrame();if(!frame){Sleep(5);continue;}++frames;
   auto access=frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();com_ptr<ID3D11Texture2D> tex;check_hresult(access->GetInterface(guid_of<ID3D11Texture2D>(),tex.put_void()));
   D3D11_TEXTURE2D_DESC desc{};tex->GetDesc(&desc);desc.Width=desc.Height=1;desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=desc.MiscFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
   com_ptr<ID3D11Texture2D> read;check_hresult(d3d->CreateTexture2D(&desc,nullptr,read.put()));for(UINT x:std::vector<UINT>{32,128,phase>=8?256u:192u,phase>=8?480u:224u}){D3D11_BOX box{x,x,0,x+1,x+1,1};ctx->CopySubresourceRegion(read.get(),0,0,0,0,tex.get(),0,&box);
   D3D11_MAPPED_SUBRESOURCE map{};check_hresult(ctx->Map(read.get(),0,D3D11_MAP_READ,0,&map));auto* v=static_cast<unsigned char*>(map.pData);
   std::fprintf(log,"sample phase=%u frame=%u elapsed_ms=%lld changed=%u x=%u bgra=%u,%u,%u,%u\n",phase,frames,(long long)elapsed,unsigned(changed),x,v[0],v[1],v[2],v[3]);ctx->Unmap(read.get(),0);}frame.Close();std::fflush(log);
  }
  session.Close();pool.Close();std::fprintf(log,"phase-done phase=%u frames=%u\n",phase,frames);color.Color({255,220,30,50});
 }
 std::fprintf(log,"foreground_unchanged=%u input_injected=0\n",unsigned(GetForegroundWindow()==before));return 0;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int){SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);int n{};auto args=CommandLineToArgvW(GetCommandLineW(),&n);if(n!=2)return 2;FILE* log{};_wfopen_s(&log,args[1],L"w");LocalFree(args);if(!log)return 3;int code=1;try{code=run(log);}catch(hresult_error const& e){std::fprintf(log,"error=%08lx %s\n",(unsigned long)e.code().value,to_string(e.message()).c_str());}catch(...){std::fprintf(log,"unknown-error\n");}std::fprintf(log,"exit=%d\n",code);fclose(log);return code;}

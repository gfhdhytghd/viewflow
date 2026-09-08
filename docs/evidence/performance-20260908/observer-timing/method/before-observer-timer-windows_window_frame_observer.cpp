// Observe fixture markers in a single owned Viewflow window through WGC.
// WGC compositor render times are distinct from DXGI desktop LastPresentTime.
#include <windows.h>
#include <shellapi.h>
#include <dwmapi.h>
#include <d3d11_4.h>
#include <dxgi1_2.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/base.h>
#include <array>
#include <atomic>
#include <cstdio>
#include <cstdint>
#include <cwchar>
#include <memory>
#include <utility>

using namespace winrt;
using namespace winrt::Windows::Graphics::Capture;
using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
using winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;

struct WindowSearch { DWORD pid; HWND window{}; unsigned count{}; };
static BOOL CALLBACK find_window(HWND window, LPARAM opaque) {
  auto& search=*reinterpret_cast<WindowSearch*>(opaque); DWORD pid=0;
  GetWindowThreadProcessId(window,&pid); wchar_t name[128]{};
  if(pid==search.pid && IsWindowVisible(window) && GetClassNameW(window,name,128) &&
     std::wcscmp(name,L"ViewflowAtlasProxy")==0) { search.window=window; ++search.count; }
  return TRUE;
}
static int64_t qpc() { LARGE_INTEGER value{}; QueryPerformanceCounter(&value); return value.QuadPart; }
struct Notification {
  handle arrived{CreateEventW(nullptr,FALSE,FALSE,nullptr)};
  std::atomic<bool> stopping{false};
};
struct Readback {
  com_ptr<ID3D11Texture2D> texture;
  // WGC cannot reuse this source frame until our copy has actually completed.
  Direct3D11CaptureFrame frame{nullptr};
  std::array<UINT,64> x{};
  int64_t rendered_100ns{}, acquired_qpc{};
  unsigned sequence{};
};
static int run(DWORD pid,unsigned duration,FILE* log,bool physical4k) {
  LARGE_INTEGER frequency{}; QueryPerformanceFrequency(&frequency);
  const int64_t start=qpc();
  std::fprintf(log,"window-observer pid=%lu qpc_frequency=%lld duration_ms=%u source_pixels=3848x2408 window_render_not_desktop_present=true\n",pid,frequency.QuadPart,duration);
  WindowSearch search{pid};
  while(qpc()-start<frequency.QuadPart*5) {
    search={pid}; EnumWindows(find_window,reinterpret_cast<LPARAM>(&search));
    if(search.count==1)break;
    Sleep(10);
  }
  if(search.count!=1)return 3;
  if(physical4k) {
    RECT target{};
    EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR,HDC,LPRECT rect,LPARAM opaque)->BOOL {
      if(rect->right-rect->left>=3840 && rect->bottom-rect->top>=2400) {
        *reinterpret_cast<RECT*>(opaque)=*rect;return FALSE;
      }
      return TRUE;
    },reinterpret_cast<LPARAM>(&target));
    if(target.right==target.left)return 14;
    if(!SetWindowPos(search.window,nullptr,target.left-4,target.top-4,0,0,SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE))return 15;
  }
  RECT client{},bounds{},window_rect{};POINT origin{};
  if(!GetClientRect(search.window,&client) || !ClientToScreen(search.window,&origin) ||
     !GetWindowRect(search.window,&window_rect))return 4;
  check_hresult(DwmGetWindowAttribute(search.window,DWMWA_EXTENDED_FRAME_BOUNDS,&bounds,sizeof(bounds)));
  if(client.right!=3848 || client.bottom!=2408)return 18;
  std::fprintf(log,"window client=%ld,%ld,%ld,%ld rect=%ld,%ld,%ld,%ld extended=%ld,%ld,%ld,%ld\n",origin.x,origin.y,client.right,client.bottom,window_rect.left,window_rect.top,window_rect.right,window_rect.bottom,bounds.left,bounds.top,bounds.right,bounds.bottom);
  if(!GraphicsCaptureSession::IsSupported())return 5;
  com_ptr<ID3D11Device> device;com_ptr<ID3D11DeviceContext> context;
  check_hresult(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,
      nullptr,0,D3D11_SDK_VERSION,device.put(),nullptr,context.put()));
  auto multithread=device.as<ID3D11Multithread>();multithread->SetMultithreadProtected(TRUE);
  if(!multithread->GetMultithreadProtected())throw_hresult(E_FAIL);
  auto dxgi=device.as<IDXGIDevice>();com_ptr<IDXGIAdapter> adapter;check_hresult(dxgi->GetAdapter(adapter.put()));
  DXGI_ADAPTER_DESC adapter_desc{};check_hresult(adapter->GetDesc(&adapter_desc));
  std::fprintf(log,"adapter vendor=%u device=%u\n",adapter_desc.VendorId,adapter_desc.DeviceId);
  IDirect3DDevice capture_device{nullptr};
  check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(),reinterpret_cast<::IInspectable**>(put_abi(capture_device))));
  auto factory=get_activation_factory<GraphicsCaptureItem,IGraphicsCaptureItemInterop>();
  GraphicsCaptureItem item{nullptr};
  check_hresult(factory->CreateForWindow(search.window,guid_of<GraphicsCaptureItem>(),put_abi(item)));
  const auto size=item.Size();
  std::fprintf(log,"capture_size=%d,%d frame_pool_buffers=3\n",size.Width,size.Height);
  if(size.Width!=bounds.right-bounds.left || size.Height!=bounds.bottom-bounds.top)return 6;
  auto pool=Direct3D11CaptureFramePool::CreateFreeThreaded(capture_device,DirectXPixelFormat::B8G8R8A8UIntNormalized,3,size);
  auto session=pool.CreateCaptureSession(item);
  session.IsCursorCaptureEnabled(false);
  std::fprintf(log,"cursor_capture=%u\n",unsigned(session.IsCursorCaptureEnabled()));
  // Retain the OS's ordinary capture-border behavior; do not request access or
  // display any consent UI just to run an observation.
  auto notification=std::make_shared<Notification>();
  if(!notification->arrived)throw_last_error();
  const auto token=pool.FrameArrived([notification](auto const&,auto const&) {
    if(!notification->stopping.load())SetEvent(notification->arrived.get());
  });
  std::array<Readback,3> slots{};
  unsigned head=0,pending=0,peak=0,acquired=0,valid=0,invalid=0,changes=0,busy=0,abandoned=0;
  uint32_t previous=0;bool have_previous=false;
  const LONG left=origin.x-bounds.left+52;
  const LONG right=left+63*32+1;
  const LONG y=origin.y-bounds.top+68;
  if(left<0 || y<0 || right>size.Width || y>=size.Height) {
    pool.FrameArrived(token);session.Close();pool.Close();return 7;
  }
  D3D11_TEXTURE2D_DESC staging{};
  staging.Width=UINT(right-left);staging.Height=1;staging.MipLevels=1;staging.ArraySize=1;
  staging.Format=DXGI_FORMAT_B8G8R8A8_UNORM;staging.SampleDesc.Count=1;
  staging.Usage=D3D11_USAGE_STAGING;staging.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
  for(auto& slot:slots)check_hresult(device->CreateTexture2D(&staging,nullptr,slot.texture.put()));
  auto consume=[&]() {
    while(pending) {
      auto& slot=slots[head];D3D11_MAPPED_SUBRESOURCE mapped{};
      const int64_t map_start=qpc();
      const HRESULT hr=context->Map(slot.texture.get(),0,D3D11_MAP_READ,D3D11_MAP_FLAG_DO_NOT_WAIT,&mapped);
      if(hr==DXGI_ERROR_WAS_STILL_DRAWING){++busy;break;}
      check_hresult(hr);
      uint64_t bits=0;bool contrast=true;
      for(unsigned cell=0;cell<64;++cell) {
        const auto p=static_cast<const unsigned char*>(mapped.pData)+slot.x[cell]*4;
        const unsigned luminance=(unsigned(p[0])+p[1]+p[2])/3;
        contrast&=luminance<64 || luminance>191;bits=(bits<<1)|(luminance>127);
      }
      context->Unmap(slot.texture.get(),0);const int64_t observed=qpc();
      const uint32_t frame=uint32_t(bits>>32);const uint16_t input=uint16_t(bits>>16),check=uint16_t(bits);
      if(!contrast || check!=uint16_t(frame^(frame>>16)^input^0xA65Cu))++invalid;
      else {
        ++valid;
        if(!have_previous || previous!=frame) {
          ++changes;
          const int64_t rendered_qpc=(slot.rendered_100ns/10000000)*frequency.QuadPart+
              (slot.rendered_100ns%10000000)*frequency.QuadPart/10000000;
          std::fprintf(log,"window-marker frame=%u input=%u render_100ns=%lld render_qpc=%lld acquired_qpc=%lld observed_qpc=%lld sequence=%u readback_us=%lld map_us=%lld\n",
              frame,unsigned(input),slot.rendered_100ns,rendered_qpc,slot.acquired_qpc,observed,slot.sequence,
              (observed-slot.acquired_qpc)*1000000/frequency.QuadPart,(observed-map_start)*1000000/frequency.QuadPart);
          previous=frame;have_previous=true;
        }
      }
      slot.frame.Close();slot.frame=nullptr;--pending;head=(head+1)%unsigned(slots.size());
    }
  };
  auto close=[&]() {
    notification->stopping.store(true);pool.FrameArrived(token);session.Close();
    for(auto& slot:slots)if(slot.frame){slot.frame.Close();slot.frame=nullptr;}
    pool.Close();
  };
  try {
    session.StartCapture();
    while((qpc()-start)*1000/frequency.QuadPart<duration) {
      consume();
      if(pending==slots.size()){WaitForSingleObject(notification->arrived.get(),1);continue;}
      auto frame=pool.TryGetNextFrame();
      if(!frame){WaitForSingleObject(notification->arrived.get(),pending?1:20);continue;}
      const int64_t acquired_qpc=qpc();++acquired;
      const auto content=frame.ContentSize();
      if(content.Width!=size.Width || content.Height!=size.Height) {
        std::fprintf(log,"capture_size_changed=%d,%d\n",content.Width,content.Height);
        frame.Close();throw_hresult(E_UNEXPECTED);
      }
      const int64_t rendered=frame.SystemRelativeTime().count();
      if(rendered<0){frame.Close();throw_hresult(E_UNEXPECTED);}
      auto access=frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
      com_ptr<ID3D11Texture2D> texture;check_hresult(access->GetInterface(guid_of<ID3D11Texture2D>(),texture.put_void()));
      D3D11_TEXTURE2D_DESC desc{};texture->GetDesc(&desc);
      if(desc.Format!=staging.Format || desc.Width<UINT(right) || desc.Height<=UINT(y)){frame.Close();throw_hresult(E_UNEXPECTED);}
      auto& slot=slots[(head+pending)%unsigned(slots.size())];
      slot.frame=std::move(frame);slot.rendered_100ns=rendered;slot.acquired_qpc=acquired_qpc;slot.sequence=acquired;
      for(unsigned cell=0;cell<64;++cell)slot.x[cell]=cell*32;
      D3D11_BOX box{UINT(left),UINT(y),0,UINT(right),UINT(y+1),1};
      context->CopySubresourceRegion(slot.texture.get(),0,0,0,0,texture.get(),0,&box);
      context->Flush();++pending;if(pending>peak)peak=pending;
    }
    // Finish already submitted copies before returning their source frames.
    const int64_t drain=qpc();
    while(pending && qpc()-drain<frequency.QuadPart*2){consume();if(pending)Sleep(1);}
    abandoned=pending;close();
  } catch(...) {close();throw;}
  std::fprintf(log,"window-observer-result acquired=%u valid=%u invalid=%u changes=%u pending_peak=%u map_busy=%u abandoned=%u\n",acquired,valid,invalid,changes,peak,busy,abandoned);
  return valid?0:13;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  int argc=0;auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);
  if(!argv || (argc!=4 && argc!=5))return 2;
  const DWORD pid=wcstoul(argv[1],nullptr,10);const unsigned duration=wcstoul(argv[2],nullptr,10);
  const bool physical4k=argc==5 && std::wcscmp(argv[4],L"physical4k")==0;
  FILE* log=nullptr;
  if(!pid || duration<1000 || duration>120000 || _wfopen_s(&log,argv[3],L"w") || !log){LocalFree(argv);return 2;}
  LocalFree(argv);setvbuf(log,nullptr,_IOLBF,4096);int result=1;
  try {init_apartment(apartment_type::multi_threaded);result=run(pid,duration,log,physical4k);}
  catch(hresult_error const& error){std::fprintf(log,"capture_error=%08lx\n",static_cast<unsigned long>(error.code().value));}
  catch(...){std::fprintf(log,"capture_error=unknown\n");}
  std::fprintf(log,"exit=%d\n",result);fclose(log);return result;
}

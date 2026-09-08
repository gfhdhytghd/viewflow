// Observe fixture markers in the composed desktop. No input or focus changes.
// DXGI LastPresentTime is a desktop-present witness, not panel photon timing.
#include <windows.h>
#include <shellapi.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdint>
#include <cwchar>
#include <algorithm>
#include <array>
using Microsoft::WRL::ComPtr;
struct WindowSearch { DWORD pid; HWND window{}; unsigned count{}; };
static BOOL CALLBACK find_window(HWND window, LPARAM opaque) {
  auto& s=*reinterpret_cast<WindowSearch*>(opaque); DWORD pid=0;
  GetWindowThreadProcessId(window,&pid); wchar_t name[128]{};
  if(pid==s.pid && IsWindowVisible(window) && GetClassNameW(window,name,128) &&
     std::wcscmp(name,L"ViewflowAtlasProxy")==0) { s.window=window; ++s.count; }
  return TRUE;
}
static int run(DWORD pid, unsigned duration, FILE* log, bool physical4k) {
  bool placed=false;
  LARGE_INTEGER frequency{},start{},now{}; QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&start);
  std::fprintf(log,"observer pid=%lu qpc_frequency=%lld duration_ms=%u source_pixels=3848x2408 desktop_present_not_photon=true\n",pid,frequency.QuadPart,duration);
  EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR monitor,HDC,LPRECT rect,LPARAM out)->BOOL {
    MONITORINFOEXW info{}; info.cbSize=sizeof(info); GetMonitorInfoW(monitor,&info);
    DEVMODEW mode{}; mode.dmSize=sizeof(mode); const BOOL known=EnumDisplaySettingsW(info.szDevice,ENUM_CURRENT_SETTINGS,&mode);
    std::fprintf(reinterpret_cast<FILE*>(out),"monitor rect=%ld,%ld,%ld,%ld mode_known=%u mode=%lux%lu refresh=%lu\n",rect->left,rect->top,rect->right,rect->bottom,unsigned(known),mode.dmPelsWidth,mode.dmPelsHeight,mode.dmDisplayFrequency);
    return TRUE;
  },reinterpret_cast<LPARAM>(log));
  ComPtr<IDXGIFactory1> factory;
  HRESULT hr=CreateDXGIFactory1(IID_PPV_ARGS(&factory)); if(FAILED(hr))return 3;
  ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> context;
  ComPtr<IDXGIOutputDuplication> duplication; DXGI_OUTPUT_DESC output{};
  ComPtr<ID3D11Texture2D> staging; unsigned staging_width=0,staging_height=0;
  unsigned valid=0,invalid=0,changes=0,acquired=0; uint32_t previous=0;
  bool have_previous=false;
  while(true) {
    QueryPerformanceCounter(&now);
    if((now.QuadPart-start.QuadPart)*1000/frequency.QuadPart>=duration)break;
    WindowSearch search{pid}; EnumWindows(find_window,reinterpret_cast<LPARAM>(&search));
    if(search.count!=1) { Sleep(10); continue; }
    if(physical4k && !placed) {
      RECT target{};
      EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR,HDC,LPRECT rect,LPARAM out)->BOOL {
        if(rect->right-rect->left==3840 && rect->bottom-rect->top==2400) {
          *reinterpret_cast<RECT*>(out)=*rect; return FALSE;
        }
        return TRUE;
      },reinterpret_cast<LPARAM>(&target));
      if(target.right==target.left) { std::fprintf(log,"no_4k_monitor\n"); return 14; }
      // Align the 3840x2400 content, excluding its four-pixel capture border.
      if(!SetWindowPos(search.window,nullptr,target.left-4,target.top-4,0,0,SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE))return 15;
      std::fprintf(log,"owned_proxy_moved=%ld,%ld no_activate=true\n",target.left-4,target.top-4); placed=true;
    }
    RECT client{}; POINT origin{};
    if(!GetClientRect(search.window,&client) || !ClientToScreen(search.window,&origin) || client.right<=0 || client.bottom<=0)continue;
    HMONITOR monitor=MonitorFromWindow(search.window,MONITOR_DEFAULTTONULL);
    if(!duplication || output.Monitor!=monitor) {
      duplication.Reset(); staging.Reset(); context.Reset(); device.Reset();
      bool found=false;
      for(UINT a=0;!found;++a) {
        ComPtr<IDXGIAdapter1> adapter; if(factory->EnumAdapters1(a,&adapter)==DXGI_ERROR_NOT_FOUND)break;
        for(UINT o=0;;++o) {
          ComPtr<IDXGIOutput> candidate; if(adapter->EnumOutputs(o,&candidate)==DXGI_ERROR_NOT_FOUND)break;
          candidate->GetDesc(&output); if(output.Monitor!=monitor)continue;
          std::fprintf(log,"output_rotation=%u\n",unsigned(output.Rotation));
          if(output.Rotation>DXGI_MODE_ROTATION_ROTATE270) { std::fprintf(log,"unsupported_rotation\n"); return 4; }
          hr=D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context);
          if(FAILED(hr))return 5;
          ComPtr<IDXGIOutput1> output1; hr=candidate.As(&output1); if(FAILED(hr))return 6;
          hr=output1->DuplicateOutput(device.Get(),&duplication);
          if(FAILED(hr)) { std::fprintf(log,"duplicate_error=%08lx\n",static_cast<unsigned long>(hr)); return 7; }
          DXGI_ADAPTER_DESC1 adapter_desc{}; adapter->GetDesc1(&adapter_desc);
          std::fprintf(log,"adapter vendor=%u device=%u software=%u\n",adapter_desc.VendorId,adapter_desc.DeviceId,unsigned((adapter_desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)!=0));
          found=true; break;
        }
      }
      if(!found) { Sleep(10); continue; }
      std::fprintf(log,"output rect=%ld,%ld,%ld,%ld client=%ld,%ld,%ld,%ld\n",output.DesktopCoordinates.left,output.DesktopCoordinates.top,output.DesktopCoordinates.right,output.DesktopCoordinates.bottom,origin.x,origin.y,client.right,client.bottom);
    }
    // Capture backend adds a four-pixel border around the 3840x2400 content.
    // Only the marker's center scanline is copied to CPU; no screenshots saved.
    const double sx=double(client.right)/3848.,sy=double(client.bottom)/2408.;
    const int left=origin.x-output.DesktopCoordinates.left+int(52*sx);
    const int right=origin.x-output.DesktopCoordinates.left+int((52+63*32)*sx)+1;
    const int y=origin.y-output.DesktopCoordinates.top+int(68*sy);
    if(left<0 || y<0 || right>output.DesktopCoordinates.right-output.DesktopCoordinates.left || y>=output.DesktopCoordinates.bottom-output.DesktopCoordinates.top) { ++invalid; Sleep(10); continue; }
    LARGE_INTEGER acquire_start{},acquire_done{}; QueryPerformanceCounter(&acquire_start);
    DXGI_OUTDUPL_FRAME_INFO info{}; ComPtr<IDXGIResource> resource;
    hr=duplication->AcquireNextFrame(20,&info,&resource);
    if(hr==DXGI_ERROR_WAIT_TIMEOUT)continue;
    if(hr==DXGI_ERROR_ACCESS_LOST) { duplication.Reset(); continue; }
    if(FAILED(hr)) { std::fprintf(log,"acquire_error=%08lx\n",static_cast<unsigned long>(hr)); return 8; }
    QueryPerformanceCounter(&acquire_done);
    ++acquired;
    ComPtr<ID3D11Texture2D> desktop; hr=resource.As(&desktop);
    if(FAILED(hr)) { duplication->ReleaseFrame(); return 9; }
    D3D11_TEXTURE2D_DESC desc{}; desktop->GetDesc(&desc);
    if(desc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM) { duplication->ReleaseFrame(); return 10; }
    std::array<POINT,64> samples{};
    LONG min_x=LONG(desc.Width),min_y=LONG(desc.Height),max_x=0,max_y=0;
    for(unsigned cell=0;cell<64;++cell) {
      const LONG dx=origin.x-output.DesktopCoordinates.left+int((52+cell*32)*sx),dy=y;
      POINT p{dx,dy};
      switch(output.Rotation) {
        case DXGI_MODE_ROTATION_ROTATE90:p={dy,LONG(desc.Height)-1-dx};break;
        case DXGI_MODE_ROTATION_ROTATE180:p={LONG(desc.Width)-1-dx,LONG(desc.Height)-1-dy};break;
        case DXGI_MODE_ROTATION_ROTATE270:p={LONG(desc.Width)-1-dy,dx};break;
        default:break;
      }
      if(p.x<0 || p.y<0 || p.x>=LONG(desc.Width) || p.y>=LONG(desc.Height)) { duplication->ReleaseFrame(); return 16; }
      samples[cell]=p;min_x=std::min(min_x,p.x);min_y=std::min(min_y,p.y);max_x=std::max(max_x,p.x);max_y=std::max(max_y,p.y);
    }
    if(!staging || staging_width!=unsigned(max_x-min_x+1) || staging_height!=unsigned(max_y-min_y+1)) {
      staging.Reset(); staging_width=unsigned(max_x-min_x+1);staging_height=unsigned(max_y-min_y+1);
      desc.Width=staging_width; desc.Height=staging_height; desc.MipLevels=1; desc.ArraySize=1;
      desc.Usage=D3D11_USAGE_STAGING; desc.BindFlags=0; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ; desc.MiscFlags=0;
      hr=device->CreateTexture2D(&desc,nullptr,&staging);
      if(FAILED(hr)) { duplication->ReleaseFrame(); return 11; }
    }
    D3D11_BOX box{UINT(min_x),UINT(min_y),0,UINT(max_x+1),UINT(max_y+1),1};
    context->CopySubresourceRegion(staging.Get(),0,0,0,0,desktop.Get(),0,&box);
    D3D11_MAPPED_SUBRESOURCE mapped{}; hr=context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped);
    if(FAILED(hr)) { duplication->ReleaseFrame(); return 12; }
    uint64_t bits=0; bool contrast=true;
    for(unsigned cell=0;cell<64;++cell) {
      const auto sample=samples[cell];
      const auto p=static_cast<const unsigned char*>(mapped.pData)+size_t(sample.y-min_y)*mapped.RowPitch+size_t(sample.x-min_x)*4;
      const unsigned luminance=(unsigned(p[0])+p[1]+p[2])/3;
      contrast&=luminance<64 || luminance>191;
      bits=(bits<<1)|(luminance>127);
    }
    context->Unmap(staging.Get(),0); duplication->ReleaseFrame(); QueryPerformanceCounter(&now);
    const uint32_t frame=uint32_t(bits>>32); const uint16_t input=uint16_t(bits>>16),check=uint16_t(bits);
    if(!contrast || check!=uint16_t(frame^(frame>>16)^input^0xA65Cu)) { ++invalid; continue; }
    ++valid;
    if(!have_previous || frame!=previous) {
      ++changes; std::fprintf(log,"desktop-marker frame=%u input=%u present_qpc=%lld observed_qpc=%lld accumulated=%u mouse_only=%u acquire_us=%lld copy_map_us=%lld\n",frame,unsigned(input),info.LastPresentTime.QuadPart,now.QuadPart,info.AccumulatedFrames,unsigned(info.LastPresentTime.QuadPart==0),(acquire_done.QuadPart-acquire_start.QuadPart)*1000000/frequency.QuadPart,(now.QuadPart-acquire_done.QuadPart)*1000000/frequency.QuadPart);
      previous=frame; have_previous=true;
    }
  }
  std::fprintf(log,"observer-result acquired=%u valid=%u invalid=%u changes=%u\n",acquired,valid,invalid,changes);
  return valid?0:13;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  int argc=0; auto argv=CommandLineToArgvW(GetCommandLineW(),&argc); if(!argv || (argc!=4 && argc!=5))return 2;
  const bool physical4k=argc==5 && std::wcscmp(argv[4],L"physical4k")==0;
  const DWORD pid=wcstoul(argv[1],nullptr,10); const unsigned duration=wcstoul(argv[2],nullptr,10);
  FILE* log=nullptr; if(!pid || duration<1000 || duration>120000 || _wfopen_s(&log,argv[3],L"w") || !log) { LocalFree(argv); return 2; }
  LocalFree(argv); setvbuf(log,nullptr,_IOLBF,4096);
  const int result=run(pid,duration,log,physical4k); std::fprintf(log,"exit=%d\n",result); fclose(log); return result;
}

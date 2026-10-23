#include <windows.h>
#include <shellapi.h>
#include <dwmapi.h>
#include <DispatcherQueue.h>
#include <windows.ui.composition.interop.h>
#include <winrt/Windows.UI.Composition.h>
#include <winrt/Windows.UI.Composition.Desktop.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.System.h>
#include <array>
#include <cstdio>
#include <vector>
using namespace winrt;
using namespace winrt::Windows::UI::Composition;
static LRESULT CALLBACK proc(HWND h,UINT m,WPARAM w,LPARAM l){if(m==WM_MOUSEACTIVATE)return MA_NOACTIVATE;if(m==WM_NCHITTEST)return HTTRANSPARENT;return DefWindowProcW(h,m,w,l);}
static int run(FILE* log){
 init_apartment(apartment_type::single_threaded);
 DispatcherQueueOptions opts{sizeof(opts),DQTYPE_THREAD_CURRENT,DQTAT_COM_STA};com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;check_hresult(CreateDispatcherQueueController(opts,queue.put()));
 const auto foreground=GetForegroundWindow();WNDCLASSW cls{};cls.lpfnWndProc=proc;cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=L"ViewflowPassiveStyleProbe";check_bool(RegisterClassW(&cls));
 Compositor compositor;auto interop=compositor.as<ABI::Windows::UI::Composition::Desktop::ICompositorDesktopInterop>();
 std::array<HWND,3> windows{};struct Cleanup{std::array<HWND,3>& windows;~Cleanup(){for(auto h:windows)if(h)DestroyWindow(h);}}cleanup{windows};
 std::vector<winrt::Windows::UI::Composition::Desktop::DesktopWindowTarget> targets;
 const int x=2700,y=600;constexpr DWORD extended=WS_EX_TOPMOST|WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW;
 for(unsigned i=0;i<3;++i){
  windows[i]=CreateWindowExW(extended|(i==0?WS_EX_NOREDIRECTIONBITMAP:0),cls.lpszClassName,L"Viewflow passive style test",WS_POPUP,x+int(i)*160,y,128,128,nullptr,nullptr,cls.hInstance,nullptr);check_bool(windows[i]);
  if(i<2){check_bool(SetLayeredWindowAttributes(windows[i],0,255,LWA_ALPHA));
   winrt::Windows::UI::Composition::Desktop::DesktopWindowTarget target{nullptr};check_hresult(interop->CreateDesktopWindowTarget(windows[i],true,reinterpret_cast<ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(put_abi(target))));
   auto root=compositor.CreateContainerVisual();root.Size({128,128});auto visual=compositor.CreateSpriteVisual();visual.Size({128,128});visual.Brush(compositor.CreateColorBrush(i==0?winrt::Windows::UI::Color{255,255,0,0}:winrt::Windows::UI::Color{255,0,255,0}));root.Children().InsertAtTop(visual);target.Root(root);targets.push_back(target);
  }else{
   HDC screen=GetDC(nullptr),memory=CreateCompatibleDC(screen);BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=128;info.bmiHeader.biHeight=-128;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;void* pixels{};HBITMAP bitmap=CreateDIBSection(screen,&info,DIB_RGB_COLORS,&pixels,nullptr,0);check_bool(bitmap);for(unsigned k=0;k<128*128;++k)static_cast<unsigned*>(pixels)[k]=0xff0000ff;
   auto old=SelectObject(memory,bitmap);POINT position{x+int(i)*160,y},source{};SIZE size{128,128};BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};const BOOL ok=UpdateLayeredWindow(windows[i],screen,&position,&size,memory,&source,0,&blend,ULW_ALPHA);SelectObject(memory,old);DeleteObject(bitmap);DeleteDC(memory);ReleaseDC(nullptr,screen);check_bool(ok);
  }
  ShowWindow(windows[i],SW_SHOWNOACTIVATE);
 }
 for(unsigned n=0;n<20;++n){MSG message{};while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}DwmFlush();Sleep(100);
  HDC screen=GetDC(nullptr);for(unsigned i=0;i<3;++i){const POINT center{x+int(i)*160+64,y+64};const auto pixel=GetPixel(screen,center.x,center.y);const auto hit=WindowFromPoint(center);bool owned=false;for(auto h:windows)owned|=hit==h;std::fprintf(log,"style-sample iteration=%u mode=%u rgb=%06lx owned_hit=%u foreground_unchanged=%u exstyle=%llx\n",n,i,pixel,unsigned(owned),unsigned(GetForegroundWindow()==foreground),static_cast<unsigned long long>(GetWindowLongPtrW(windows[i],GWL_EXSTYLE)));if(owned){ReleaseDC(nullptr,screen);return 3;}}ReleaseDC(nullptr,screen);std::fflush(log);
 }
 std::fprintf(log,"style-probe input_injected=0 foreground_unchanged=%u\n",unsigned(GetForegroundWindow()==foreground));return 0;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int){SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);int argc{};auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);if(!argv||argc!=2)return 2;FILE* log{};_wfopen_s(&log,argv[1],L"w");if(!log)return 2;int code=1;try{code=run(log);}catch(winrt::hresult_error const& e){std::fprintf(log,"HRESULT=%08lx\n",static_cast<unsigned long>(e.code()));}std::fclose(log);LocalFree(argv);return code;}

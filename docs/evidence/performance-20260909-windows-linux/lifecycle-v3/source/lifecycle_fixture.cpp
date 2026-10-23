// Only owned nonactivating windows on the existing non-primary test display.
#include <windows.h>
#include <chrono>
#include <cstdio>
#include <vector>
#include <utility>
#include <stdexcept>
using Clock=std::chrono::steady_clock;
void require(bool ok){if(!ok)throw std::runtime_error("owned lifecycle fixture Win32 failure");}
long long now(){LARGE_INTEGER t{},f{};QueryPerformanceCounter(&t);QueryPerformanceFrequency(&f);return t.QuadPart/f.QuadPart*10000000+(t.QuadPart%f.QuadPart)*10000000/f.QuadPart;}
void paint(HWND w,int x,int y,int width,int height,bool stripes){
 auto screen=GetDC(nullptr),memory=CreateCompatibleDC(screen);BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=width;info.bmiHeader.biHeight=-height;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
 void* pixels{};auto bitmap=CreateDIBSection(screen,&info,DIB_RGB_COLORS,&pixels,nullptr,0);require(bitmap!=nullptr);auto previous=SelectObject(memory,bitmap);
 for(int row=0;row<height;++row)for(int col=0;col<width;++col){const unsigned alpha=stripes?static_cast<unsigned>(col<width/4?0:col<width/2?64:col<3*width/4?128:255):255;static_cast<unsigned*>(pixels)[row*width+col]=(alpha<<24)|(alpha<<16);}
 POINT destination{x,y},origin{};SIZE size{width,height};BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};const auto result=UpdateLayeredWindow(w,screen,&destination,&size,memory,&origin,0,&blend,ULW_ALPHA);
 SelectObject(memory,previous);DeleteObject(bitmap);DeleteDC(memory);ReleaseDC(nullptr,screen);require(result!=FALSE);
}
int main(){try{
 SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);auto desktop=OpenInputDesktop(0,FALSE,GENERIC_ALL);require(desktop && SetThreadDesktop(desktop));
 RECT rect{-6144,-780,0,2676};MONITORINFO info{sizeof(info)};auto monitor=MonitorFromRect(&rect,MONITOR_DEFAULTTONULL);require(monitor && GetMonitorInfoW(monitor,&info) && EqualRect(&info.rcMonitor,&rect) && !(info.dwFlags&MONITORINFOF_PRIMARY));
 auto initial_focus=GetForegroundWindow();auto instance=GetModuleHandleW(nullptr);WNDCLASSW cls{};cls.hInstance=instance;cls.lpszClassName=L"VFReverseLifecycleOwned";cls.lpfnWndProc=DefWindowProcW;require(RegisterClassW(&cls)!=0);
 auto create=[&](const wchar_t* title,int x,int y,int width,int height,bool stripes){auto w=CreateWindowExW(WS_EX_LAYERED|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_TRANSPARENT,cls.lpszClassName,title,WS_POPUP,x,y,width,height,nullptr,nullptr,instance,nullptr);require(w!=nullptr);paint(w,x,y,width,height,stripes);ShowWindow(w,SW_SHOWNOACTIVATE);return w;};
 const int x=-6080,y=-716;auto first=create(L"lifecycle-original",x,y,256,192,true);HWND second{};int phase=0;
 auto log=[&](){
 for(auto pair:{std::pair{1,first},std::pair{2,second}}){if(!pair.second)continue;RECT rect{},client{};const bool valid=GetWindowRect(pair.second,&rect)!=FALSE;GetClientRect(pair.second,&client);std::fprintf(stderr,"lifecycle_window phase=%d index=%d valid=%u visible=%u x=%ld y=%ld width=%ld height=%ld client_width=%ld client_height=%ld\n",phase,pair.first,unsigned(valid),unsigned(IsWindowVisible(pair.second)!=FALSE),rect.left,rect.top,rect.right-rect.left,rect.bottom-rect.top,client.right-client.left,client.bottom-client.top);if(phase==4 && pair.first==1)require(valid && rect.right-rect.left==320 && rect.bottom-rect.top==256);}
 std::fprintf(stderr,"lifecycle_phase phase=%d at=%lld foreground_initial=%p foreground_now=%p\n",phase,now(),initial_focus,GetForegroundWindow());std::fflush(stderr);};log();const auto start=Clock::now();
 while(Clock::now()-start<std::chrono::seconds(17)){
  MSG msg{};while(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);}
  const auto seconds=std::chrono::duration_cast<std::chrono::seconds>(Clock::now()-start).count();const int next=seconds<5?0:1+static_cast<int>((seconds-5)/2);
  if(next>phase){phase=next;switch(phase){
   case 1:require(SetWindowTextW(first,L"lifecycle-renamed")!=FALSE);break;
   case 2:require(SetWindowPos(first,nullptr,x+64,y+32,0,0,SWP_NOSIZE|SWP_NOACTIVATE|SWP_NOZORDER)!=FALSE);break;
   case 3:second=create(L"lifecycle-second",x+512,y+64,128,192,false);break;
   case 4:paint(first,x+64,y+32,320,256,true);break;
   case 5:ShowWindow(second,SW_HIDE);break;
   case 6:DestroyWindow(first);first=nullptr;break;
  }log();}
  Sleep(5);
 }
 if(first)DestroyWindow(first);if(second)DestroyWindow(second);std::fprintf(stderr,"lifecycle_end at=%lld foreground=%p\n",now(),GetForegroundWindow());return 0;
}catch(const std::exception& e){std::fprintf(stderr,"lifecycle_error %s error=%lu\n",e.what(),GetLastError());return 1;}}

// A short-lived, nonactivating, click-through alpha fixture. No input injection.
#include <windows.h>
#include <cstdio>
#include <chrono>
#include <cstdlib>
int main(int argc,char** argv) {
    const int left=argc==3?std::atoi(argv[1]):64,top=argc==3?std::atoi(argv[2]):64;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const auto desktop=OpenInputDesktop(0,FALSE,GENERIC_ALL);
    if(!desktop || !SetThreadDesktop(desktop))return 1;
    const auto instance=GetModuleHandleW(nullptr);
    WNDCLASSW cls{};cls.hInstance=instance;cls.lpszClassName=L"VFReverseCaptureProbe";cls.lpfnWndProc=DefWindowProcW;
    if(!RegisterClassW(&cls))return 2;
    HWND window=CreateWindowExW(WS_EX_LAYERED|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_TRANSPARENT,cls.lpszClassName,
        L"Viewflow alpha capture check",WS_POPUP,left,top,256,128,nullptr,nullptr,instance,nullptr);
    if(!window)return 3;
    const auto screen=GetDC(nullptr),memory=CreateCompatibleDC(screen);
    BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=256;
    info.bmiHeader.biHeight=-128;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
    void* pixels{};const auto bitmap=CreateDIBSection(screen,&info,DIB_RGB_COLORS,&pixels,nullptr,0);
    if(!bitmap)return 4;
    auto previous=SelectObject(memory,bitmap);
    for(unsigned y=0;y<128;++y)for(unsigned x=0;x<256;++x){
        const unsigned alpha=x<64?0:x<128?64:x<192?128:255;
        static_cast<unsigned*>(pixels)[y*256+x]=(alpha<<24)|((y<64?alpha:0)<<16)|((y>=64?alpha:0)<<8);
    }
    POINT destination{left,top},origin{};SIZE size{256,128};BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};
    if(!UpdateLayeredWindow(window,screen,&destination,&size,memory,&origin,0,&blend,ULW_ALPHA))return 5;
    ShowWindow(window,SW_SHOWNOACTIVATE);
    std::fprintf(stderr,"nonactivating alpha fixture ready\n");
    const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(12);
    while(std::chrono::steady_clock::now()<until){MSG message{};while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}Sleep(10);}
    DestroyWindow(window);SelectObject(memory,previous);DeleteObject(bitmap);DeleteDC(memory);ReleaseDC(nullptr,screen);
    return 0;
}

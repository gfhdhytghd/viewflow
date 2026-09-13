// Read-only interactive diagnostic: discovers and captures existing IME UI.
// Never creates/focuses a window or generates input.
#include "window_inventory.hpp"
#include "../windows-window-capture/wgc_window_capture.hpp"
#include <winrt/base.h>
#include <dwmapi.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>

int main() {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    unsigned candidates=0,captured=0;
    for(const auto entry:viewflow::reverse::capture_window_inventory()) {
        const auto window=entry.window;
        DWORD cloaked{};
        if(!entry.ime || !IsWindowVisible(window) ||
            (SUCCEEDED(DwmGetWindowAttribute(window,DWMWA_CLOAKED,&cloaked,sizeof(cloaked))) && cloaked))continue;
        RECT rect{};if(!GetWindowRect(window,&rect) || rect.right<=rect.left || rect.bottom<=rect.top)continue;
        ++candidates;
        std::atomic<unsigned> frames{},width{},height{};
        viewflow::windows_capture::WindowCapture capture;
        viewflow::windows_capture::FrameCallbacks callbacks;
        callbacks.on_frame=[&](const viewflow::windows_capture::CapturedFrame& frame){
            width=frame.geometry.content_width;height=frame.geometry.content_height;++frames;
        };
        const auto result=capture.start(window,{8192,8192,8192ull*8192},std::move(callbacks));
        if(result)for(unsigned i=0;i<100 && !frames.load();++i)std::this_thread::sleep_for(std::chrono::milliseconds(20));
        capture.stop();
        std::printf("ime hwnd=%p parent=%p x=%ld y=%ld width=%ld height=%ld start_hr=%08x frames=%u captured=%ux%u\n",
            window,GetParent(window),rect.left,rect.top,rect.right-rect.left,rect.bottom-rect.top,
            result.native_hresult,frames.load(),width.load(),height.load());
        if(frames)++captured;
    }
    std::printf("ime candidates=%u captured=%u\n",candidates,captured);
    return candidates && candidates==captured?0:1;
}

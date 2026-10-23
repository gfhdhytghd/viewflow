// Nonactivating GPU motion fixture. Tiny premultiplied alpha keeps the host
// test layer unobtrusive and below the receiver's input-region threshold.
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <dcomp.h>
#include <dwmapi.h>
#include "../windows-window-capture/wgc_window_capture.hpp"
#include "capture_staging.hpp"
#include "fixture_gpu_probe.hpp"
#include "../reverse-common/fixture_stamp.hpp"
#include "../reverse-common/shared_copy.hpp"
#include <atomic>
#include <mutex>
#include <thread>
#include <wrl/client.h>
#include <chrono>
#include <cstdio>
#include <cwchar>
#include <stdexcept>
#include <string>
#include <vector>
#include <algorithm>
using Microsoft::WRL::ComPtr;
static void check(HRESULT hr){if(FAILED(hr))throw std::runtime_error("motion fixture HRESULT="+std::to_string(static_cast<unsigned long>(hr)));}
static constexpr GUID console_display_state{0x6fe69556,0x704a,0x47a0,{0x8f,0x24,0xc2,0x8d,0x93,0x6f,0xda,0x47}};
static void report_input_clock(const char* phase){
    LASTINPUTINFO input{sizeof(LASTINPUTINFO)};
    SetLastError(0);
    const auto ok=GetLastInputInfo(&input);
    const auto error=ok?0:GetLastError();
    const auto now=GetTickCount();
    std::fprintf(stderr,"motion-input-clock phase=%s ok=%u tick_ms=%lu last_input_ms=%lu idle_ms=%lu error=%lu scope=session-last-input-not-injected\n",phase,unsigned(ok!=0),now,input.dwTime,ok?DWORD(now-input.dwTime):0,error);
}
static LRESULT CALLBACK procedure(HWND w,UINT m,WPARAM a,LPARAM b){
    if(m==WM_POWERBROADCAST && a==PBT_POWERSETTINGCHANGE){const auto* power=reinterpret_cast<const POWERBROADCAST_SETTING*>(b);if(IsEqualGUID(power->PowerSetting,console_display_state) && power->DataLength==sizeof(DWORD)){DWORD value{};std::memcpy(&value,power->Data,sizeof(value));std::fprintf(stderr,"motion-display-power state=%lu (0=off,1=on,2=dim)\n",value);report_input_clock("power-change");}return TRUE;}
    if(m==WM_NCHITTEST)return HTTRANSPARENT;
    if(m==WM_MOUSEACTIVATE)return MA_NOACTIVATE;
    if(m==WM_ERASEBKGND)return 1;
    return DefWindowProcW(w,m,a,b);
}
int main(int argc,char** argv){try{
    for(int i=0;i<argc;++i)std::fprintf(stderr,"motion-arg index=%d value=%s\n",i,argv[i]);
    const unsigned seconds=argc>1?std::stoul(argv[1]):12;
    unsigned copy_threads=4,copy_every=1;bool copy_cached=false,copy_ram=false,wake_monitor=false,probe_topmost=false;
    bool copy_low_priority=false;
    bool present_zero=false;
    bool cycle8=false,waitable=false,capture_only=false,capture_staging=false,capture_map=false,capture_copy=false,capture_worker=false;
    for(int i=2;i<argc;++i){const std::string arg=argv[i];if(arg=="present-zero")present_zero=true;else if(arg=="copy-low-priority")copy_low_priority=true;else if(arg=="probe-topmost")probe_topmost=true;else if(arg=="wake-monitor")wake_monitor=true;else if(arg=="cycle8")cycle8=true;else if(arg=="waitable")waitable=true;else if(arg=="capture-only")capture_only=true;else if(arg=="capture-staging")capture_staging=true;else if(arg=="capture-map"){capture_map=true;capture_staging=true;}else if(arg=="capture-copy"){capture_copy=true;capture_map=true;capture_staging=true;}else if(arg=="capture-worker" || arg=="capture-worker1" || arg=="capture-worker2" || arg=="capture-worker8" || arg=="capture-memcpy" || arg=="capture-halfcopy" || arg=="capture-ramcopy"){copy_ram=arg=="capture-ramcopy";copy_every=arg=="capture-halfcopy"?2u:1u;copy_cached=arg=="capture-memcpy";copy_threads=arg=="capture-worker1"?1u:arg=="capture-worker2"?2u:arg=="capture-worker8"?8u:4u;capture_worker=true;capture_copy=true;capture_map=true;capture_staging=true;}else throw std::runtime_error("unknown fixture option");}
    if(present_zero && !waitable)throw std::runtime_error("present-zero requires waitable pacing");
    if(!seconds || seconds>60)throw std::runtime_error("fixture duration must be 1..60 seconds");
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const auto desktop=OpenInputDesktop(0,FALSE,GENERIC_ALL);
    if(!desktop || !SetThreadDesktop(desktop))throw std::runtime_error("fixture input desktop unavailable");
    wchar_t desktop_name[256]{},station_name[256]{};DWORD needed{},session{};
    GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),UOI_NAME,desktop_name,sizeof(desktop_name),&needed);
    GetUserObjectInformationW(GetProcessWindowStation(),UOI_NAME,station_name,sizeof(station_name),&needed);
    ProcessIdToSessionId(GetCurrentProcessId(),&session);
    std::fprintf(stderr,"motion-desktop name=%ls station=%ls session=%lu active_console=%lu requested_topmost=%u foreground=%p\n",desktop_name,station_name,session,WTSGetActiveConsoleSessionId(),unsigned(probe_topmost),GetForegroundWindow());
    for(const auto action:{UINT(SPI_GETSCREENSAVEACTIVE),UINT(SPI_GETSCREENSAVETIMEOUT),UINT(SPI_GETPOWEROFFACTIVE),UINT(SPI_GETPOWEROFFTIMEOUT)}) {
        UINT value=0;SetLastError(0);const auto ok=SystemParametersInfoW(action,0,&value,0);
        std::fprintf(stderr,"motion-system-parameter action=%u ok=%u value=%u error=%lu\n",action,unsigned(ok!=0),value,ok?0:GetLastError());
    }
    const auto previous_execution=SetThreadExecutionState(ES_CONTINUOUS|ES_DISPLAY_REQUIRED|ES_SYSTEM_REQUIRED);
    if(!previous_execution)throw std::runtime_error("fixture display execution request failed");
    struct ExecutionOwner {EXECUTION_STATE previous;~ExecutionOwner(){SetThreadExecutionState(previous);}} execution_owner{previous_execution};
    check(CoInitializeEx(nullptr,COINIT_MULTITHREADED));
    // Inventory the actual interactive desktop; SSH session enumeration can
    // be empty. This probe never applies a display mode or changes focus.
    for(DWORD index=0;;++index) {
        DISPLAY_DEVICEW display{};display.cb=sizeof(display);
        if(!EnumDisplayDevicesW(nullptr,index,&display,0))break;
        if(!(display.StateFlags&DISPLAY_DEVICE_ATTACHED_TO_DESKTOP))continue;
        DEVMODEW mode{};mode.dmSize=sizeof(mode);
        if(EnumDisplaySettingsW(display.DeviceName,ENUM_CURRENT_SETTINGS,&mode))
            std::fprintf(stderr,"motion-display name=%ls current=%lux%lu refresh_hz=%lu\n",display.DeviceName,mode.dmPelsWidth,mode.dmPelsHeight,mode.dmDisplayFrequency);
        for(DWORD n=0;;++n) {
            mode={};mode.dmSize=sizeof(mode);if(!EnumDisplaySettingsW(display.DeviceName,n,&mode))break;
            if(mode.dmPelsWidth==6144 && mode.dmPelsHeight==3456)
                std::fprintf(stderr,"motion-display name=%ls available_6k_refresh_hz=%lu bpp=%lu\n",display.DeviceName,mode.dmDisplayFrequency,mode.dmBitsPerPel);
        }
    }
    const auto* dd_output=_wgetenv(L"VIEWFLOW_PROFILE_FULLSCREEN_OUTPUT");
    const auto* dd_token=_wgetenv(L"VIEWFLOW_PROFILE_FIXTURE_TOKEN");
    const bool dd_fixture=dd_output&&*dd_output&&dd_token&&std::wcslen(dd_token)==32;
    POINT dd_origin{};
    if(dd_fixture){
        bool found=false;
        for(DWORD i=0;;++i){DISPLAY_DEVICEW d{};d.cb=sizeof(d);if(!EnumDisplayDevicesW(nullptr,i,&d,0))break;
            if(std::wcscmp(dd_output,d.DeviceName))continue;
            DEVMODEW mode{};mode.dmSize=sizeof(mode);
            if((d.StateFlags&DISPLAY_DEVICE_PRIMARY_DEVICE)||!(d.StateFlags&DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)||
               !EnumDisplaySettingsW(d.DeviceName,ENUM_CURRENT_SETTINGS,&mode)||mode.dmPelsWidth!=6144||mode.dmPelsHeight!=3456||mode.dmDisplayFrequency!=60||mode.dmDisplayOrientation!=DMDO_DEFAULT)
                throw std::runtime_error("DD fixture requires existing non-primary 6144x3456@60 unrotated output");
            dd_origin={mode.dmPosition.x,mode.dmPosition.y};found=true;break;
        }
        if(!found)throw std::runtime_error("DD fixture output unavailable");
        if(probe_topmost||wake_monitor)throw std::runtime_error("DD fixture does not use topmost or monitor wake");
    }
    const auto before=GetForegroundWindow();
    WNDCLASSW cls{};cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=L"VF6KMotionFixture";cls.lpfnWndProc=procedure;
    if(!RegisterClassW(&cls))throw std::runtime_error("fixture class registration");
    constexpr unsigned width=6144,height=3456;
    HWND window=CreateWindowExW((probe_topmost?WS_EX_TOPMOST:0)|(dd_fixture?0:WS_EX_NOREDIRECTIONBITMAP|WS_EX_TRANSPARENT)|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW,cls.lpszClassName,
        L"Viewflow 6K performance fixture",WS_POPUP,dd_origin.x,dd_origin.y,width,height,nullptr,nullptr,cls.hInstance,nullptr);
    if(!window)throw std::runtime_error("fixture window creation");
    if(dd_fixture){
        const std::wstring property=std::wstring(L"Viewflow.DD.Fixture.")+dd_token;
        if(!SetPropW(window,property.c_str(),reinterpret_cast<HANDLE>(1)))throw std::runtime_error("fixture token property");
        std::fprintf(stderr,"motion-dd-fixture output=%ls mode=opaque-hwnd noactivate=1 input_injected=0\n",dd_output);
    }
    struct WindowOwner{HWND w;~WindowOwner(){DestroyWindow(w);}} owner{window};
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
    check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context));
    ComPtr<IDXGIDevice> dxgi;check(device.As(&dxgi));ComPtr<IDXGIAdapter> adapter;check(dxgi->GetAdapter(&adapter));
    ComPtr<IDXGIFactory2> factory;check(adapter->GetParent(IID_PPV_ARGS(&factory)));
    DXGI_SWAP_CHAIN_DESC1 desc{};desc.Width=width;desc.Height=height;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;
    desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;desc.BufferCount=2;desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;desc.AlphaMode=dd_fixture?DXGI_ALPHA_MODE_IGNORE:DXGI_ALPHA_MODE_PREMULTIPLIED;
    if(waitable)desc.Flags|=DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
    ComPtr<IDXGISwapChain1> swap;if(dd_fixture)check(factory->CreateSwapChainForHwnd(device.Get(),window,&desc,nullptr,nullptr,&swap));else check(factory->CreateSwapChainForComposition(device.Get(),&desc,nullptr,&swap));
    struct WaitHandle{HANDLE value{};~WaitHandle(){if(value)CloseHandle(value);}} frame_ready,pacing_timer;
    if(present_zero && std::getenv("VIEWFLOW_FIXTURE_HIGH_RES_TIMER")) {
        pacing_timer.value=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_MODIFY_STATE|SYNCHRONIZE);
        if(!pacing_timer.value)throw std::runtime_error("high-resolution fixture timer unavailable");
        std::fprintf(stderr,"motion-pacing high_resolution_timer=1 target_hz=60\n");
    }
    if(waitable){ComPtr<IDXGISwapChain2> low_latency;check(swap.As(&low_latency));check(low_latency->SetMaximumFrameLatency(1));UINT actual{};check(low_latency->GetMaximumFrameLatency(&actual));if(actual!=1)throw std::runtime_error("frame latency readback");frame_ready.value=low_latency->GetFrameLatencyWaitableObject();if(!frame_ready.value)throw std::runtime_error("frame latency handle");}
    ComPtr<IDCompositionDevice> composition;ComPtr<IDCompositionTarget> target;ComPtr<IDCompositionVisual> visual;
    if(!dd_fixture){check(DCompositionCreateDevice(dxgi.Get(),IID_PPV_ARGS(&composition)));
        check(composition->CreateTargetForHwnd(window,TRUE,&target));check(composition->CreateVisual(&visual));
        check(visual->SetContent(swap.Get()));check(target->SetRoot(visual.Get()));check(composition->Commit());}
    ComPtr<ID3D11Texture2D> texture;check(swap->GetBuffer(0,IID_PPV_ARGS(&texture)));
    ComPtr<ID3D11RenderTargetView> view;check(device->CreateRenderTargetView(texture.Get(),nullptr,&view));
    const bool pixel_stamp=std::getenv("VIEWFLOW_FIXTURE_PIXEL_STAMP")!=nullptr;
    ComPtr<ID3D11Texture2D> stamp_texture;
    if(pixel_stamp){D3D11_TEXTURE2D_DESC marker{};marker.Width=viewflow::reverse::fixture_stamp::width;marker.Height=1;marker.MipLevels=marker.ArraySize=1;marker.Format=DXGI_FORMAT_B8G8R8A8_UNORM;marker.SampleDesc.Count=1;marker.Usage=D3D11_USAGE_DEFAULT;check(device->CreateTexture2D(&marker,nullptr,&stamp_texture));}
    const auto power_notification=RegisterPowerSettingNotification(window,&console_display_state,DEVICE_NOTIFY_WINDOW_HANDLE);
    if(!power_notification)throw std::runtime_error("fixture display notification registration failed");
    struct NotificationOwner{HPOWERNOTIFY handle;~NotificationOwner(){UnregisterPowerSettingNotification(handle);}} notification_owner{power_notification};
    ShowWindow(window,SW_SHOWNOACTIVATE);
    if(probe_topmost){SetLastError(0);const auto placed=SetWindowPos(window,HWND_TOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);std::fprintf(stderr,"motion-topmost applied=%u error=%lu exstyle=0x%llx\n",unsigned(placed!=0),GetLastError(),static_cast<unsigned long long>(GetWindowLongPtrW(window,GWL_EXSTYLE)));if(!placed)throw std::runtime_error("fixture topmost placement failed");}
    const auto report_window=[&](const char* phase){DWORD cloaked=0;const auto hr=DwmGetWindowAttribute(window,DWMWA_CLOAKED,&cloaked,sizeof(cloaked));RECT rect{};GetWindowRect(window,&rect);std::fprintf(stderr,"motion-window phase=%s visible=%u iconic=%u cloaked=%lu cloak_hr=0x%08lx topmost=%u rect=%ld,%ld,%ld,%ld foreground_unchanged=%u\n",phase,unsigned(IsWindowVisible(window)!=0),unsigned(IsIconic(window)!=0),cloaked,static_cast<unsigned long>(hr),unsigned((GetWindowLongPtrW(window,GWL_EXSTYLE)&WS_EX_TOPMOST)!=0),rect.left,rect.top,rect.right,rect.bottom,unsigned(before==GetForegroundWindow()));};
    report_window("start");
    report_input_clock("start");
    if(wake_monitor){DWORD_PTR result{};const auto sent=SendMessageTimeoutW(HWND_BROADCAST,WM_SYSCOMMAND,SC_MONITORPOWER,-1,SMTO_ABORTIFHUNG,100,&result);std::fprintf(stderr,"motion-monitor wake_sent=%u error=%lu foreground_unchanged=%u\n",unsigned(sent!=0),sent?0:GetLastError(),unsigned(before==GetForegroundWindow()));}
    if(const auto* gate=_wgetenv(L"VIEWFLOW_FIXTURE_START_GATE");gate && *gate) {
        // Establish the nonactivating capture surface before the receiver reconnects.
        // This initialization submission is outside the measured generation interval.
        const float transparent[4]{0,0,0,dd_fixture?1.0f:0.0f};
        context->ClearRenderTargetView(view.Get(),transparent);
        check(swap->Present(0,0));
        const auto gate_start=std::chrono::steady_clock::now();auto gate_present=gate_start;unsigned gate_frames=1;
        std::fprintf(stderr,"motion-gate ready path=%ls watchdog_ms=60000 initialization_frames=1 measured=0\n",gate);
        std::fflush(stderr);
        for(;;) {
            MSG message{};
            while(PeekMessageW(&message,window,0,0,PM_REMOVE)) {
                TranslateMessage(&message);DispatchMessageW(&message);
            }
            if(!IsWindow(window))throw std::runtime_error("motion-gate fixture window closed");
            if(dd_fixture&&std::chrono::steady_clock::now()-gate_present>=std::chrono::milliseconds(100)){
                const float initialization[4]{0,0,(++gate_frames%2)?1.f/255.f:0.f,1.f};
                context->ClearRenderTargetView(view.Get(),initialization);check(swap->Present(0,0));gate_present=std::chrono::steady_clock::now();
            }
            const auto elapsed=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-gate_start).count();
            const auto attributes=GetFileAttributesW(gate);
            if(attributes!=INVALID_FILE_ATTRIBUTES && !(attributes&FILE_ATTRIBUTE_DIRECTORY)) {
                if(dd_fixture)std::fprintf(stderr,"motion-dd-gate initialization_frames=%u measured=0\n",gate_frames);
                LARGE_INTEGER gate_qpc{},gate_frequency{};QueryPerformanceCounter(&gate_qpc);QueryPerformanceFrequency(&gate_frequency);
                std::fprintf(stderr,"motion-gate open wait_ms=%lld qpc=%lld frequency=%lld\n",static_cast<long long>(elapsed),gate_qpc.QuadPart,gate_frequency.QuadPart);
                std::fflush(stderr);break;
            }
            if(attributes==INVALID_FILE_ATTRIBUTES) {
                const auto error=GetLastError();
                if(error!=ERROR_FILE_NOT_FOUND && error!=ERROR_PATH_NOT_FOUND)
                    throw std::runtime_error("motion-gate file query error="+std::to_string(error));
            }
            if(elapsed>=60000) {
                std::fprintf(stderr,"motion-gate timeout wait_ms=%lld scope=fixture-operation-watchdog\n",static_cast<long long>(elapsed));
                std::fflush(stderr);
                throw std::runtime_error("motion-gate operation timed out");
            }
            MsgWaitForMultipleObjectsEx(0,nullptr,25,QS_ALLINPUT,MWMO_INPUTAVAILABLE);
        }
    }
    ComPtr<ID3D11Device> capture_device;ComPtr<ID3D11DeviceContext> capture_context;
    viewflow::reverse::shm::CaptureStaging staging_pool;
    std::shared_ptr<viewflow::reverse::shm::CapturedStaging> staging;
    std::vector<std::int64_t> captured_stamps;unsigned wrong_extent=0,staging_misses=0;
    std::vector<std::shared_ptr<viewflow::reverse::shm::CapturedStaging>> map_pending;
    unsigned mapped_frames=0,map_not_ready=0;std::vector<double> map_durations;unsigned char map_touch=0;
    std::vector<std::uint8_t> copied_pixels,ram_source;std::vector<double> cpu_copy_ms;
    std::unique_ptr<viewflow::reverse::shm::ParallelCopy> pixel_copier;
    if(capture_copy){copied_pixels.resize(std::size_t(width)*height*4);pixel_copier=std::make_unique<viewflow::reverse::shm::ParallelCopy>(copy_threads,true,copy_cached);}
    if(copy_ram)ram_source.resize(std::size_t(width)*height*4,0x5a);
    std::atomic<unsigned> capture_failure{};
    std::mutex pending_mutex;
    unsigned worker_pending_at_stop=0;
    const auto process_pending=[&](auto& pending){
                for(auto it=pending.begin();it!=pending.end();){
                    BOOL done=FALSE;const auto ready=capture_context->GetData((*it)->done.Get(),&done,sizeof(done),D3D11_ASYNC_GETDATA_DONOTFLUSH);check(ready);
                    if(ready!=S_OK || !done){++map_not_ready;++it;continue;}
                    D3D11_MAPPED_SUBRESOURCE mapped{};const auto begin=std::chrono::steady_clock::now();
                    const auto hr=capture_context->Map((*it)->texture.Get(),0,D3D11_MAP_READ,D3D11_MAP_FLAG_DO_NOT_WAIT,&mapped);
                    if(hr==DXGI_ERROR_WAS_STILL_DRAWING){++map_not_ready;++it;continue;}check(hr);
                    struct MapOwner {ID3D11DeviceContext* context;ID3D11Texture2D* texture;void release(){if(texture){context->Unmap(texture,0);texture=nullptr;}}~MapOwner(){release();}} mapped_owner{capture_context.Get(),(*it)->texture.Get()};
                    const auto* bytes=static_cast<const volatile unsigned char*>(mapped.pData);
                    map_touch^=bytes[0]^bytes[std::size_t(height-1)*mapped.RowPitch+width*4-1];
                    if(capture_copy && mapped_frames%copy_every==0){const auto copy_begin=std::chrono::steady_clock::now();pixel_copier->copy(copied_pixels.data(),copy_ram?ram_source.data():static_cast<const std::uint8_t*>(mapped.pData),std::size_t(width)*4,copy_ram?width*4:mapped.RowPitch,height);cpu_copy_ms.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-copy_begin).count());}
                    mapped_owner.release();
                    map_durations.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count());++mapped_frames;
                    it=pending.erase(it);
                }
    };
    // Declare before capture: exception unwinding stops the producer before
    // requesting/joining the consumer, and keeps all referenced resources alive.
    const auto lower_copy_priority=[](HANDLE thread){
        if(!SetThreadPriority(thread,THREAD_PRIORITY_BELOW_NORMAL) || GetThreadPriority(thread)!=THREAD_PRIORITY_BELOW_NORMAL)
            throw std::runtime_error("copy thread priority readback failed");
    };
    if(copy_low_priority && pixel_copier){pixel_copier->configure_workers(lower_copy_priority);std::fprintf(stderr,"motion-copy-priority helpers=%u priority=below-normal verified=1\n",copy_threads-1);}
    std::jthread copy_worker;
    viewflow::windows_capture::WindowCapture capture;
    if(capture_only || capture_staging){
        check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&capture_device,nullptr,&capture_context));
        viewflow::windows_capture::FrameCallbacks callbacks;
        callbacks.on_frame=[&](const viewflow::windows_capture::CapturedFrame& f){
            if(f.geometry.content_width!=width || f.geometry.content_height!=height){++wrong_extent;return;}
            captured_stamps.push_back(f.system_relative_time_100ns);
            if(capture_map && !capture_worker){
                process_pending(map_pending);
                if(map_pending.size()>=2){++staging_misses;return;}
            }
            if(capture_staging){D3D11_BOX box{0,0,0,width,height,1};auto next=staging_pool.copy(capture_device.Get(),capture_context.Get(),f.surface,box,staging);if(next){staging=std::move(next);if(capture_map){std::lock_guard lock(pending_mutex);map_pending.push_back(staging);}}else ++staging_misses;}
        };
        callbacks.on_terminal=[&](auto,unsigned hr){capture_failure=hr?hr:1;};
        const auto started=capture.start(window,{16384,16384,16384ull*16384},std::move(callbacks),capture_device.Get());
        if(!started)throw std::runtime_error("fixture self-capture start failed");
        if(capture_worker)copy_worker=std::jthread([&](std::stop_token stop){
            std::vector<std::shared_ptr<viewflow::reverse::shm::CapturedStaging>> pending;
            try {
                if(copy_low_priority){lower_copy_priority(GetCurrentThread());std::fprintf(stderr,"motion-copy-priority caller=worker priority=below-normal verified=1\n");}
                while(!stop.stop_requested()) {
                    {std::lock_guard lock(pending_mutex);pending.insert(pending.end(),map_pending.begin(),map_pending.end());map_pending.clear();}
                    process_pending(pending);
                    Sleep(1); // Bounded polling; never hold the queue lock during a copy.
                }
            } catch(...) {capture_failure=1;}
            worker_pending_at_stop=static_cast<unsigned>(pending.size());
        });
    }
    struct DwmSample {const char* phase;DWM_TIMING_INFO info;HRESULT hr;LARGE_INTEGER stamp,frequency;std::int64_t begin;};
    std::vector<DwmSample> dwm_samples;dwm_samples.reserve(64);
    const auto report_dwm=[&](const char* phase){
        DWM_TIMING_INFO info{};info.cbSize=sizeof(info);
        LARGE_INTEGER begin{},stamp{},frequency{};QueryPerformanceCounter(&begin);
        const auto hr=DwmGetCompositionTimingInfo(nullptr,&info);
        QueryPerformanceCounter(&stamp);QueryPerformanceFrequency(&frequency);
        if(dwm_samples.size()<64)dwm_samples.push_back({phase,info,hr,stamp,frequency,begin.QuadPart});
    };
    report_dwm("start");auto dwm_report_at=std::chrono::steady_clock::now();
    const auto start=std::chrono::steady_clock::now();unsigned frames=0;std::vector<double> present_ms,wait_ms;unsigned wait_timeouts=0,present_occluded=0,present_other=0;
    const auto* opaque_option=std::getenv("VIEWFLOW_FIXTURE_OPAQUE");
    const bool opaque_fixture=dd_fixture || (opaque_option && std::string_view(opaque_option)=="1");
    std::fprintf(stderr,"motion-fixture started hwnd=%p width=%u height=%u seconds=%u alpha=%s noactivate=true pattern=%s\n",window,width,height,seconds,opaque_fixture?"1":"1/255",cycle8?"cycle8":"alternating2");
    HWND observed_foreground=GetForegroundWindow();unsigned foreground_changes=0;
    const auto observe_foreground=[&]{
        const auto current=GetForegroundWindow();if(current==observed_foreground)return;
        LARGE_INTEGER stamp{},frequency{};QueryPerformanceCounter(&stamp);QueryPerformanceFrequency(&frequency);
        DWORD pid{};const auto tid=GetWindowThreadProcessId(current,&pid);
        LASTINPUTINFO input{sizeof(input)};const auto input_ok=GetLastInputInfo(&input);
        std::fprintf(stderr,"motion-foreground-change qpc=%lld frequency=%lld before=%p after=%p pid=%lu tid=%lu last_input_ms=%lu input_ok=%u scope=read-only-sampled\n",stamp.QuadPart,frequency.QuadPart,observed_foreground,current,pid,tid,input.dwTime,unsigned(input_ok!=0));
        observed_foreground=current;++foreground_changes;
    };
    struct PresentTiming {unsigned sequence;std::int64_t generated,begin,end;};
    std::vector<PresentTiming> present_timings;if(pixel_stamp)present_timings.reserve(8192);
    const auto qpc100ns=[] {LARGE_INTEGER q{},f{};QueryPerformanceCounter(&q);QueryPerformanceFrequency(&f);return q.QuadPart/f.QuadPart*10000000+(q.QuadPart%f.QuadPart)*10000000/f.QuadPart;};
    const bool media_probe=std::getenv("VIEWFLOW_FIXTURE_MEDIA_TRACE")!=nullptr;
    ComPtr<IDXGISwapChainMedia> media;const auto media_hr=media_probe?swap.As(&media):E_NOINTERFACE;
    struct MediaTiming {unsigned sequence;HRESULT hr,last_hr;UINT last;DXGI_FRAME_STATISTICS_MEDIA stats;};
    std::vector<MediaTiming> media_timings;if(media_probe)media_timings.reserve(8192);
    const bool gpu_probe_enabled=std::getenv("VIEWFLOW_FIXTURE_GPU_TRACE")!=nullptr;
    FixtureGpuProbe gpu_probe(device.Get(),context.Get(),gpu_probe_enabled);
    auto paced_deadline=start;
    // Optional reproducibility control. Align only the initial deadline; retain
    // 60 Hz pacing and report actual per-frame QPC separately. This does not
    // change application/capture scheduling or establish physical scanout.
    if(const auto* phase=std::getenv("VIEWFLOW_FIXTURE_PHASE_EIGHTH")) {
        if(phase[0]<'0' || phase[0]>'7' || phase[1]!='\0' || !present_zero || !pacing_timer.value)
            throw std::runtime_error("fixture phase requires digit0..7, present-zero and high-resolution timer");
        DWM_TIMING_INFO info{};info.cbSize=sizeof(info);
        check(DwmGetCompositionTimingInfo(nullptr,&info));
        LARGE_INTEGER stamp{},frequency{};QueryPerformanceCounter(&stamp);QueryPerformanceFrequency(&frequency);
        const auto steady=std::chrono::steady_clock::now();
        const auto period=static_cast<std::int64_t>(info.qpcRefreshPeriod);
        if(frequency.QuadPart<=0 || period<=0 || !info.qpcVBlank ||
           period>frequency.QuadPart || period<frequency.QuadPart/1000)
            throw std::runtime_error("fixture phase timing unavailable");
        auto target=static_cast<std::int64_t>(info.qpcVBlank)+period*(phase[0]-'0')/8;
        const auto earliest=stamp.QuadPart+period*2;
        if(target<earliest)target+=((earliest-target+period-1)/period)*period;
        paced_deadline=steady+std::chrono::nanoseconds((target-stamp.QuadPart)*1000000000/frequency.QuadPart);
        std::fprintf(stderr,"motion-phase requested_eighth=%c qpc=%lld target_qpc=%lld frequency=%lld period_qpc=%lld scope=desktop-metadata-start-alignment\n",phase[0],stamp.QuadPart,target,frequency.QuadPart,period);
    }
    if(pixel_stamp)std::fprintf(stderr,"motion-generation-origin before_clear=1 version=2\n");
    LARGE_INTEGER loop_begin_qpc{},loop_frequency{};QueryPerformanceCounter(&loop_begin_qpc);QueryPerformanceFrequency(&loop_frequency);
    std::fprintf(stderr,"motion-loop begin qpc=%lld frequency=%lld\n",loop_begin_qpc.QuadPart,loop_frequency.QuadPart);
    while(std::chrono::steady_clock::now()-start<std::chrono::seconds(seconds)) {
        observe_foreground();
        if(std::chrono::steady_clock::now()-dwm_report_at>=std::chrono::seconds(5)){report_dwm("sample");dwm_report_at=std::chrono::steady_clock::now();}
        MSG message{};while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}
        if(waitable){
            const auto wait_begin=std::chrono::steady_clock::now();
            const auto result=MsgWaitForMultipleObjectsEx(1,&frame_ready.value,100,QS_ALLINPUT,MWMO_INPUTAVAILABLE);
            if(result==WAIT_OBJECT_0+1)continue;
            if(result==WAIT_TIMEOUT){++wait_timeouts;continue;}
            if(result!=WAIT_OBJECT_0)throw std::runtime_error("frame latency wait failed");
            wait_ms.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-wait_begin).count());
            if(std::chrono::steady_clock::now()-start>=std::chrono::seconds(seconds))break;
        }
        if(present_zero){
            // Present(0) may release the waitable object faster than refresh.
            // Bound this control to60Hz; skip missed periods instead of bursts.
            if(pacing_timer.value){
                const auto remaining=std::chrono::duration_cast<std::chrono::nanoseconds>(paced_deadline-std::chrono::steady_clock::now()).count();
                if(remaining>0){
                    LARGE_INTEGER due{};due.QuadPart=-((remaining+99)/100);
                    if(!SetWaitableTimerEx(pacing_timer.value,&due,0,nullptr,nullptr,nullptr,0) || WaitForSingleObject(pacing_timer.value,1000)!=WAIT_OBJECT_0)
                        throw std::runtime_error("high-resolution fixture wait failed");
                }
            }else std::this_thread::sleep_until(paced_deadline);
            const auto now=std::chrono::steady_clock::now();
            if(now-start>=std::chrono::seconds(seconds))break;
            do{paced_deadline+=std::chrono::nanoseconds(16666667);}while(paced_deadline<=now);
        }
        const float alpha=dd_fixture?1.f:1.f/255.f;const unsigned bits=cycle8?frames%8:(frames%2?1:4);
        // Retain low-amplitude RGB changes even in the opaque control.
        const float color[]={bits&1?alpha:0.f,bits&2?alpha:0.f,bits&4?alpha:0.f,opaque_fixture?1.f:alpha};
        // Include the first rendering command in generation-to-feedback timing.
        const std::int64_t generated=pixel_stamp?qpc100ns():0;
        context->ClearRenderTargetView(view.Get(),color);
        if(pixel_stamp){
            const auto stamp=generated;
            const auto pixels=viewflow::reverse::fixture_stamp::encode({frames,static_cast<std::uint64_t>(stamp)});
            context->UpdateSubresource(stamp_texture.Get(),0,nullptr,pixels.data(),static_cast<UINT>(pixels.size()),0);
            context->CopySubresourceRegion(texture.Get(),0,0,0,0,stamp_texture.Get(),0,nullptr);
        }
        if(gpu_probe_enabled)gpu_probe.submit(frames,generated);
        const auto begin_qpc=pixel_stamp?qpc100ns():0;
        const auto present_begin=std::chrono::steady_clock::now();const auto presented=swap->Present(present_zero?0:1,0);check(presented);if(presented==DXGI_STATUS_OCCLUDED)++present_occluded;else if(presented!=S_OK)++present_other;
        if(pixel_stamp && present_timings.size()<8192)present_timings.push_back({frames,generated,begin_qpc,qpc100ns()});
        if(media_probe && media_timings.size()<8192){MediaTiming m{};m.sequence=frames;m.hr=media?media->GetFrameStatisticsMedia(&m.stats):media_hr;m.last_hr=swap->GetLastPresentCount(&m.last);media_timings.push_back(m);}
        present_ms.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-present_begin).count());++frames;
    }
    LARGE_INTEGER loop_end_qpc{};QueryPerformanceCounter(&loop_end_qpc);
    const double elapsed=double(loop_end_qpc.QuadPart-loop_begin_qpc.QuadPart)/double(loop_frequency.QuadPart);
    observe_foreground();
    std::fprintf(stderr,"motion-loop end qpc=%lld frequency=%lld\n",loop_end_qpc.QuadPart,loop_frequency.QuadPart);
    std::fprintf(stderr,"motion-foreground-summary changes=%u scope=frame-sampled-not-event-hook\n",foreground_changes);
    if(gpu_probe_enabled)gpu_probe.report();
    for(const auto& t:present_timings)std::fprintf(stderr,"motion-present sequence=%u generated=%lld begin=%lld end=%lld\n",t.sequence,static_cast<long long>(t.generated),static_cast<long long>(t.begin),static_cast<long long>(t.end));
    for(const auto& m:media_timings)std::fprintf(stderr,"motion-media sequence=%u hr=0x%08lx last_hr=0x%08lx last=%u count=%u refresh=%u sync_refresh=%u sync_qpc=%lld mode=%d\n",m.sequence,static_cast<unsigned long>(m.hr),static_cast<unsigned long>(m.last_hr),m.last,m.stats.PresentCount,m.stats.PresentRefreshCount,m.stats.SyncRefreshCount,static_cast<long long>(m.stats.SyncQPCTime.QuadPart),int(m.stats.CompositionMode));
    capture.stop();
    if(copy_worker.joinable()){copy_worker.request_stop();copy_worker.join();}
    if(capture_only || capture_staging){
        unsigned gaps=0;double max_gap=0;
        for(std::size_t i=1;i<captured_stamps.size();++i){const auto gap=double(captured_stamps[i]-captured_stamps[i-1])/10000;gaps+=gap>25;max_gap=std::max(max_gap,gap);}
        const double fps=captured_stamps.size()>1?double(captured_stamps.size()-1)*1e7/double(captured_stamps.back()-captured_stamps.front()):0;
        std::fprintf(stderr,"motion-self-capture mode=%s frames=%zu stamp_fps=%.3f gaps_over25ms=%u max_gap_ms=%.3f wrong_extent=%u staging_misses=%u terminal=0x%08x scope=WGC-not-transport\n",capture_worker?"worker-copy":capture_copy?"cpu-copy":capture_map?"map":capture_staging?"staging":"capture-only",captured_stamps.size(),fps,gaps,max_gap,wrong_extent,staging_misses,capture_failure.load());
    }
    if(capture_map){std::sort(map_durations.begin(),map_durations.end());std::fprintf(stderr,"motion-map frames=%u not_ready=%u pending_at_stop=%zu map_unmap_p50_ms=%.3f map_unmap_p95_ms=%.3f touch=%u scope=nonblocking-previous-frame-includes-optional-copy\n",mapped_frames,map_not_ready,map_pending.size()+worker_pending_at_stop,map_durations.empty()?0:map_durations[map_durations.size()/2],map_durations.empty()?0:map_durations[map_durations.size()*95/100],unsigned(map_touch));}
    if(capture_copy){std::sort(cpu_copy_ms.begin(),cpu_copy_ms.end());std::fprintf(stderr,"motion-cpu-copy frames=%zu threads=%u every=%u algorithm=%s source=%s destination=ordinary-RAM bytes_per_frame=%zu p50_ms=%.3f p95_ms=%.3f\n",cpu_copy_ms.size(),copy_threads,copy_every,copy_cached?"memcpy":"streaming",copy_ram?"static-ordinary-RAM":"mapped-staging",copied_pixels.size(),cpu_copy_ms.empty()?0:cpu_copy_ms[cpu_copy_ms.size()/2],cpu_copy_ms.empty()?0:cpu_copy_ms[cpu_copy_ms.size()*95/100]);}
    std::fprintf(stderr,"motion-present-status occluded=%u other_success=%u\n",present_occluded,present_other);
    report_window("end");
    report_input_clock("end");
    report_dwm("end");
    for(const auto& sample:dwm_samples){
        const auto& info=sample.info;const auto hr=sample.hr;const auto* phase=sample.phase;
        const auto stamp=sample.stamp,frequency=sample.frequency;
        std::fprintf(stderr,"motion-dwm phase=%s hr=0x%08lx qpc=%lld frequency=%lld refresh_num=%u refresh_den=%u compose_num=%u compose_den=%u refresh=%llu frame=%llu displayed=%llu late=%llu dropped=%llu missed=%llu outstanding=%u refresh_period_qpc=%llu vblank_qpc=%llu compose_qpc=%llu displayed_qpc=%llu complete_qpc=%llu scope=desktop-composition-not-per-window\n",phase,static_cast<unsigned long>(hr),stamp.QuadPart,frequency.QuadPart,info.rateRefresh.uiNumerator,info.rateRefresh.uiDenominator,info.rateCompose.uiNumerator,info.rateCompose.uiDenominator,info.cRefresh,info.cFrame,info.cFramesDisplayed,info.cFramesLate,info.cFramesDropped,info.cFramesMissed,info.cFramesOutstanding,info.qpcRefreshPeriod,info.qpcVBlank,info.qpcCompose,info.qpcFrameDisplayed,info.qpcFrameComplete);
        std::fprintf(stderr,"motion-dwm-query phase=%s begin_qpc=%lld end_qpc=%lld frequency=%lld scope=CPU-query-duration\n",phase,static_cast<long long>(sample.begin),stamp.QuadPart,frequency.QuadPart);
    }
    std::fprintf(stderr,"motion-fixture frames=%u elapsed_s=%.6f submit_fps=%.3f foreground_unchanged=%u (fixture submissions, not received fps)\n",frames,elapsed,frames/elapsed,unsigned(before==GetForegroundWindow()));
    std::sort(wait_ms.begin(),wait_ms.end());
    if(waitable)std::fprintf(stderr,"motion-fixture waitable=1 max_latency=1 wait_p50_ms=%.3f wait_p95_ms=%.3f wait_timeouts=%u\n",wait_ms.empty()?0:wait_ms[wait_ms.size()/2],wait_ms.empty()?0:wait_ms[wait_ms.size()*95/100],wait_timeouts);
    std::sort(present_ms.begin(),present_ms.end());
    if(!present_ms.empty())std::fprintf(stderr,"motion-fixture present_cpu_ms_p50=%.3f p95=%.3f max=%.3f over25ms=%zu\n",present_ms[present_ms.size()/2],present_ms[present_ms.size()*95/100],present_ms.back(),std::count_if(present_ms.begin(),present_ms.end(),[](double ms){return ms>25;}));
    return 0;
}catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 1;}}

#include "performance_mode.hpp"
#include "fusion_policy.hpp"
#include "shell_crop.hpp"
#include "shared_readback.hpp"
#include "d12_transport.hpp"
#include "fullscreen_window_capture.hpp"
#include "readback_wait.hpp"
#include "capture_wake.hpp"
#include "diagnostics.hpp"
#include "frame_changes.hpp"
#include "ime_priority.hpp"
#include "application_icon.hpp"
#include "atlas_capacity.hpp"
#include "atlas_row_width.hpp"
#include "hardware_encoder.hpp"
#include "alpha_plane.hpp"
#include "alpha_encode.hpp"
#include "touchpad.hpp"
#include "window_inventory.hpp"
#include "../reverse-common/wire.hpp"
#include "../reverse-common/activity_input.hpp"
#include "../reverse-common/activity_feedback.hpp"
#include "../reverse-common/activity_hint.hpp"
#include "../reverse-common/window_residency.hpp"
#include "../windows-window-capture/wgc_window_capture.hpp"
#include <d3d11_4.h>
#include <dwmapi.h>
#include <winrt/base.h>
#include <io.h>
#include <fcntl.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <optional>
#include <thread>
#include <future>
#include <algorithm>
#include <set>
#include <mmsystem.h>

namespace vf=viewflow::reverse;
using Microsoft::WRL::ComPtr;
using Clock=std::chrono::steady_clock;
namespace {
void check(HRESULT hr) {if(FAILED(hr))throw std::runtime_error("Windows reverse HRESULT="+std::to_string(static_cast<unsigned long>(hr)));}
struct TimerResolution {
    MMRESULT result=timeBeginPeriod(1);
    ~TimerResolution(){if(result==TIMERR_NOERROR)timeEndPeriod(1);}
};
std::int64_t qpc100ns(){LARGE_INTEGER t{},f{};QueryPerformanceCounter(&t);QueryPerformanceFrequency(&f);return t.QuadPart/f.QuadPart*10000000+(t.QuadPart%f.QuadPart)*10000000/f.QuadPart;}
// Observe native moves independently of WGC/codec allocation. A complete fast
// gesture must not disappear while the capture thread is warming its pipeline.
vf::ImePriority ime_priority;
std::int64_t scheduler_ms(){return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();}
void CALLBACK ime_event(HWINEVENTHOOK,DWORD,HWND window,LONG object,LONG,DWORD,DWORD){
    if(window && object==OBJID_WINDOW && vf::ime_popup(window))ime_priority.activity(scheduler_ms());
}
struct MoveOrigin { RECT bounds{},final_bounds{}; POINT grab{}; DWORD pid{}; std::uint64_t serial{}; bool ended{}; };
std::uint64_t next_move_serial=0;
std::map<HWND,MoveOrigin> move_origins;
std::mutex move_mutex;
std::optional<MoveOrigin> observed_move_for(HWND window) {
    std::lock_guard lock(move_mutex);auto found=move_origins.find(window);
    return found==move_origins.end()?std::nullopt:std::optional<MoveOrigin>(found->second);
}
bool native_moves_pending(){std::lock_guard lock(move_mutex);return !move_origins.empty();}
void CALLBACK move_event(HWINEVENTHOOK, DWORD event, HWND window, LONG, LONG, DWORD, DWORD) {
    if(!window)return;
    RECT rect{};if(FAILED(DwmGetWindowAttribute(window,DWMWA_EXTENDED_FRAME_BOUNDS,&rect,sizeof(rect))))GetWindowRect(window,&rect);
    DWORD pid{};GetWindowThreadProcessId(window,&pid);
    if(event==EVENT_SYSTEM_MOVESIZEEND){
        std::lock_guard lock(move_mutex);
        if(auto found=move_origins.find(window);found!=move_origins.end() && found->second.pid==pid){
            found->second.ended=true;found->second.final_bounds=rect;
        }
        return;
    }
    POINT pointer{};
    if(pid && GetCursorPos(&pointer) && rect.right>rect.left && rect.bottom>rect.top){
        std::lock_guard lock(move_mutex);
        move_origins[window]={rect,rect,{pointer.x-rect.left,pointer.y-rect.top},pid,++next_move_serial,false};
    }
}
struct MoveObserver {
    std::atomic<DWORD> thread_id{};
    std::thread worker;
    MoveObserver():worker([this]{
        const auto desktop=OpenInputDesktop(0,FALSE,GENERIC_ALL);
        if(desktop)SetThreadDesktop(desktop);
        MSG message{};PeekMessageW(&message,nullptr,0,0,PM_NOREMOVE);
        thread_id.store(GetCurrentThreadId(),std::memory_order_release);
        const auto hook=SetWinEventHook(EVENT_SYSTEM_MOVESIZESTART,EVENT_SYSTEM_MOVESIZEEND,nullptr,move_event,0,0,WINEVENT_OUTOFCONTEXT|WINEVENT_SKIPOWNPROCESS);
        const auto ime_hook=SetWinEventHook(EVENT_OBJECT_SHOW,EVENT_OBJECT_HIDE,nullptr,ime_event,0,0,WINEVENT_OUTOFCONTEXT|WINEVENT_SKIPOWNPROCESS);
        if(!hook)std::fprintf(stderr,"reverse native move observer unavailable error=%lu\n",GetLastError());
        if(!ime_hook)std::fprintf(stderr,"reverse IME observer unavailable; periodic inventory retained error=%lu\n",GetLastError());
        while(GetMessageW(&message,nullptr,0,0)>0){TranslateMessage(&message);DispatchMessageW(&message);}
        if(hook)UnhookWinEvent(hook);
        if(ime_hook)UnhookWinEvent(ime_hook);
        if(desktop)CloseDesktop(desktop);
    }){}
    ~MoveObserver(){
        DWORD id{};while(!(id=thread_id.load(std::memory_order_acquire)))std::this_thread::yield();
        PostThreadMessageW(id,WM_QUIT,0,0);worker.join();
    }
};
bool owned_dd_fixture(HWND window,DWORD pid) {
    const auto* output=std::getenv("VIEWFLOW_PROFILE_FULLSCREEN_OUTPUT");
    const auto* wanted=std::getenv("VIEWFLOW_PROFILE_SOURCE_PID");
    const auto* born=std::getenv("VIEWFLOW_PROFILE_FIXTURE_CREATED");
    const auto* token=_wgetenv(L"VIEWFLOW_PROFILE_FIXTURE_TOKEN");
    if(!output||!*output||!wanted||!born||!token||std::wcslen(token)!=32)return false;
    for(unsigned i=0;i<32;++i)if(!((token[i]>=L'0'&&token[i]<=L'9')||(token[i]>=L'a'&&token[i]<=L'f')))return false;
    char* end{};const auto requested=std::strtoul(wanted,&end,10);if(!end||*end||requested!=pid)return false;
    const auto creation=std::strtoull(born,&end,10);if(!end||*end||!creation)return false;
    wchar_t cls[64]{};GetClassNameW(window,cls,64);if(std::wcscmp(cls,L"VF6KMotionFixture"))return false;
    const std::wstring property=std::wstring(L"Viewflow.DD.Fixture.")+token;
    if(GetPropW(window,property.c_str())!=reinterpret_cast<HANDLE>(1))return false;
    HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)return false;
    FILETIME start{},exit{},kernel{},user{};const bool read=GetProcessTimes(process,&start,&exit,&kernel,&user)!=FALSE;CloseHandle(process);
    return read&&((std::uint64_t(start.dwHighDateTime)<<32)|start.dwLowDateTime)==creation;
}
struct Source {
    HWND window{};std::uint64_t id{},owner{};DWORD pid{};
    viewflow::windows_capture::WindowCapture capture;
    std::mutex mutex;
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11ShaderResourceView> texture_view;
    // Enabled lazily by an eligible direct transport. Pool ownership remains on
    // Source until management stops callbacks; never destroy it in on_frame.
    std::unique_ptr<vf::d12::SharedCapture> shared_source_pool;
    std::shared_ptr<vf::d12::SharedCapture::Snapshot> shared_source_snapshot;
    ComPtr<ID3D12Device3> shared_snapshot_device; // Current snapshot keeps its device through DD restore.
    ID3D12Device3* shared_source_device{}; // Kept alive by the initialized pool.
    bool shared_source_attempted{},shared_source_failed{};
    vf::shm::BandedStaging band_pool;std::shared_ptr<vf::shm::CapturedBands> bands;
    vf::shm::CaptureStaging staging_pool;std::shared_ptr<vf::shm::CapturedStaging> staging;
    unsigned frame_width{},frame_height{},capture_width{},capture_height{};
    viewflow::windows_capture::CaptureGeometry geometry,requested_geometry;
    bool ime_popup{},shell_menu{},first_submitted{},icon_sent{};
    vf::ShellCrop shell_crop;
    unsigned shell_x{},shell_y{};
    vf::SourceIcon icon;
    Clock::time_point discovered_at=Clock::now();
    std::optional<vf::PixelRect> resident;
    std::uint64_t geometry_ack{};
    std::uint64_t capture_version{};std::int64_t pts{};bool closed{},in_move{},was_resized{};RECT move_origin{};
    Clock::time_point retry_at{},geometry_seen_at{};
    std::unique_ptr<vf::d12::FullscreenWindowCapture> fullscreen_capture;
    std::optional<vf::Input> fullscreen_request,fullscreen_geometry;
    bool owned_dd_test{};
    bool fullscreen_suppress{},fullscreen_snapshot{},fullscreen_retiring{},fullscreen_force_wgc{},desktop_output_snapshot{};
    std::optional<vf::Input> fullscreen_intent;
    std::uint64_t fullscreen_generation{};
    std::int64_t wgc_after{};
    RECT fullscreen_presentation{};
    ~Source(){capture.stop();}

};
struct App {
    vf::shm::CaptureWake capture_wake; // Outlives source callbacks during teardown.
    const unsigned capture_bands=[]{const auto* value=std::getenv("VIEWFLOW_SHM_CAPTURE_BANDS");return value && std::string_view(value)=="2"?2u:value && std::string_view(value)=="4"?4u:0u;}();
    const bool capture_staging=std::getenv("VIEWFLOW_SHM_CAPTURE_STAGING") && std::string_view(std::getenv("VIEWFLOW_SHM_CAPTURE_STAGING"))=="1";
    unsigned capture_limit=8192,capture_pixels=vf::max_pixels;
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
    std::map<HWND,std::shared_ptr<Source>> sources;
    std::vector<std::shared_ptr<Source>> retiring_sources;
    std::mutex source_mutex;
    std::mutex activity_mutex;
    viewflow::activity::Priority<std::uint64_t> activity;
    viewflow::activity::Feedback lane_feedback[2][3];
    viewflow::activity::Feedback feedback(unsigned lane) {
        std::lock_guard lock(activity_mutex);viewflow::activity::Feedback result;result.lane=lane;
        for(auto& stage:lane_feedback[lane]){
            result.keyframe|=stage.keyframe;result.single_lane|=stage.single_lane;result.saturated|=stage.saturated;
            result.queue_us=std::max(result.queue_us,stage.queue_us);stage.keyframe=false;
        }
        return result;
    }
    struct Scheduling {
        std::uint64_t preferred{},focus{};
        std::vector<std::uint64_t> members;
        std::map<std::uint64_t,std::uint64_t> roots;
        bool belongs(std::uint64_t id,std::uint64_t root) const {
            const auto found=roots.find(id);return root && found!=roots.end() && found->second==root;
        }
    };
    Scheduling scheduling() {
        std::vector<std::pair<std::uint64_t,std::uint64_t>> visible;
        {std::lock_guard lock(source_mutex);for(const auto& [_,s]:sources)visible.emplace_back(s->id,s->owner);}
        std::lock_guard lock(activity_mutex);activity.membership(visible);
        Scheduling result;result.preferred=activity.preferred(viewflow::activity::now_us());result.focus=activity.last_focus();
        for(const auto& [id,_]:visible){result.members.push_back(id);result.roots[id]=activity.owner_root(id);}
        std::sort(result.members.begin(),result.members.end());return result;
    }
    std::atomic<bool> running{true};
    std::uint64_t next_id{1};int left{-6144},top{-780},right{0},bottom{2676};
    std::map<unsigned,INPUT> held_keys,held_buttons;
    std::uint64_t last_input{},touchpad_target{};
    vf::TouchpadAssembler touchpad_frames;
    vf::TouchpadInjector touchpad;
    bool inventory_logged{};
    vf::FusionPolicy fusion;
    const bool fullscreen_enabled=std::getenv("VIEWFLOW_FULLSCREEN_DMA") && std::string_view(std::getenv("VIEWFLOW_FULLSCREEN_DMA"))=="1";
    bool fullscreen_transport{};
    ComPtr<ID3D12Device> fullscreen_device;
    std::uint64_t fullscreen_owner{};

    ~App() {
        // Keep the source map's strong references while stopping callbacks.
        // Otherwise a callback can release the last Source reference after
        // map destruction and run ~Source/stop recursively on the WGC thread.
        for(auto& [_,source]:sources){source->capture.stop();std::lock_guard lock(source->mutex);
            if(source->fullscreen_capture && !source->fullscreen_capture->restore())
                std::fprintf(stderr,"reverse-fullscreen restore deferred-at-shutdown id=%llu\n",source->id);
        }
        for(auto& source:retiring_sources){source->capture.stop();if(source->fullscreen_capture && !source->fullscreen_capture->restore())std::fprintf(stderr,"reverse-fullscreen retiring restore failed-at-shutdown id=%llu\n",source->id);}
    }
    void release() {
        {std::lock_guard lock(activity_mutex);activity.release(0,viewflow::activity::now_us());}
        touchpad_frames.reset();touchpad.release();touchpad_target=0;
        for(auto& [_,input]:held_keys){input.ki.dwFlags|=KEYEVENTF_KEYUP;SendInput(1,&input,sizeof(input));}
        for(auto& [_,input]:held_buttons){
            const auto down=input.mi.dwFlags;
            input.mi.dwFlags=down==MOUSEEVENTF_LEFTDOWN?MOUSEEVENTF_LEFTUP:down==MOUSEEVENTF_RIGHTDOWN?MOUSEEVENTF_RIGHTUP:down==MOUSEEVENTF_MIDDLEDOWN?MOUSEEVENTF_MIDDLEUP:MOUSEEVENTF_XUP;
            SendInput(1,&input,sizeof(input));
        }
        held_keys.clear();held_buttons.clear();
    }
    std::shared_ptr<Source> source_for(std::uint64_t id) {
        std::lock_guard lock(source_mutex);
        for(auto& [_,source]:sources)if(source->id==id)return source;
        return {};
    }
    static RECT bounds(HWND window) {
        RECT rect{};if(FAILED(DwmGetWindowAttribute(window,DWMWA_EXTENDED_FRAME_BOUNDS,&rect,sizeof(rect))))GetWindowRect(window,&rect);return rect;
    }
    static void focus(HWND window) {
        HWND root=GetAncestor(window,GA_ROOTOWNER);if(!root)root=window;
        if(GetForegroundWindow()==root)return;
        const auto foreground=GetWindowThreadProcessId(GetForegroundWindow(),nullptr);
        const auto current=GetCurrentThreadId();
        const bool attached=foreground && foreground!=current && AttachThreadInput(current,foreground,TRUE);
        SetForegroundWindow(root);
        if(attached)AttachThreadInput(current,foreground,FALSE);
    }
    void input(const vf::Input& event) {
        if(event.sequence<=last_input)throw std::runtime_error("reverse input sequence regression");last_input=event.sequence;
        {std::lock_guard lock(activity_mutex);viewflow::activity::observe(activity,event,viewflow::activity::now_us());
            if(event.kind==vf::InputKind::touchpad_frame)activity.hold(event.id,3,0,event.c>0,viewflow::activity::now_us());}
        if(event.kind==vf::InputKind::button || event.kind==vf::InputKind::key)
            std::fprintf(stderr,"reverse-input-received id=%llu seq=%llu kind=%u down=%d\n",(unsigned long long)event.id,(unsigned long long)event.sequence,unsigned(event.kind),event.b);
        if(event.kind==vf::InputKind::release){release();return;}
        if(event.kind==vf::InputKind::proxy_drag || event.kind==vf::InputKind::proxy_drag_anchor)throw std::runtime_error("local proxy control arrived on Windows input");
        const bool touchpad_input=event.kind==vf::InputKind::touchpad_contact || event.kind==vf::InputKind::touchpad_frame;
        if(event.kind==vf::InputKind::touchpad_frame && event.c==0){
            touchpad_frames.reset();if(touchpad_target==event.id){touchpad.release();touchpad_target=0;}return;
        }
        auto source=source_for(event.id);if(!source){if(touchpad_input){touchpad_frames.reset();if(touchpad_target==event.id){touchpad.release();touchpad_target=0;}}return;}
        // Experimental fixture geometry is controlled by its retained owner,
        // not by the proxy WM. No user Source uses this branch.
        if(source->owned_dd_test && (event.kind==vf::InputKind::geometry || static_cast<unsigned>(event.kind)==17))return;
        if(static_cast<unsigned>(event.kind)==17){
            if(!fullscreen_enabled || !fullscreen_transport || source->ime_popup || source->shell_menu || event.b!=1 ||
               (event.a!=0 && event.a!=2) || (event.a==2 && (event.c<=0||event.d<=0||event.c>16384||event.d>16384)))return;
            std::lock_guard lock(source->mutex);source->fullscreen_request=event;source->fullscreen_force_wgc=false;capture_wake.notify();return;
        }
        if(event.kind==vf::InputKind::visibility){
            std::lock_guard lock(source->mutex);
            const auto resident=vf::clip_resident(source->frame_width,source->frame_height,event.a,event.b,event.c,event.d);
            if(vf_diag::metrics() && source->resident!=resident)vf_diag::trace("profile_residency id=%llu at=%lld x=%u y=%u width=%u height=%u\n",source->id,qpc100ns(),resident.x,resident.y,resident.width,resident.height);
            source->resident=resident;
            return;
        }
        DWORD pid{};GetWindowThreadProcessId(source->window,&pid);if(pid!=source->pid || !IsWindow(source->window))return;
        if(touchpad_input){
            try {
                if(auto frame=touchpad_frames.input(event)){
                    if(touchpad_target && touchpad_target!=event.id && !touchpad.release()){std::fprintf(stderr,"reverse touchpad release failed error=%lu\n",GetLastError());return;}
                    touchpad_target=event.id;
                    if(!touchpad.apply(*frame))std::fprintf(stderr,"reverse touchpad injection failed error=%lu\n",GetLastError());
                }
            }catch(const std::exception& error){touchpad_frames.reset();touchpad.release();std::fprintf(stderr,"reverse touchpad: %s\n",error.what());}
            return;
        }
        const auto rect=bounds(source->window);
        INPUT native{};
        switch(event.kind) {
        case vf::InputKind::pointer: {
            POINT delta{};{std::lock_guard lock(source->mutex);if(source->fullscreen_capture && source->fullscreen_capture->bound())delta=source->fullscreen_capture->presentation_delta();}
            const auto x=std::int64_t(event.c==1?delta.x:rect.left)+event.a,y=std::int64_t(event.c==1?delta.y:rect.top)+event.b;
            if(x>=LONG_MIN && x<=LONG_MAX && y>=LONG_MIN && y<=LONG_MAX) {
                BOOL moved=FALSE;
                if(source->shell_menu) {
                    // CoreWindow/XAML hover needs the mouse input path, not
                    // just a cursor warp. Use virtual-desktop coordinates so
                    // cropped shell surfaces also work on secondary outputs.
                    const auto left=GetSystemMetrics(SM_XVIRTUALSCREEN),top=GetSystemMetrics(SM_YVIRTUALSCREEN);
                    const auto width=std::max(1,GetSystemMetrics(SM_CXVIRTUALSCREEN)),height=std::max(1,GetSystemMetrics(SM_CYVIRTUALSCREEN));
                    native.type=INPUT_MOUSE;
                    native.mi.dx=static_cast<LONG>(std::clamp<std::int64_t>(((x-left)*65536+32768)/width,0,65535));
                    native.mi.dy=static_cast<LONG>(std::clamp<std::int64_t>(((y-top)*65536+32768)/height,0,65535));
                    native.mi.dwFlags=MOUSEEVENTF_MOVE|MOUSEEVENTF_ABSOLUTE|MOUSEEVENTF_VIRTUALDESK;
                    moved=SendInput(1,&native,sizeof(native))==1;
                } else moved=SetCursorPos(static_cast<int>(x),static_cast<int>(y));
                if(source->shell_menu) {
                    static auto logged=Clock::time_point{};
                    if(Clock::now()-logged>=std::chrono::milliseconds(250)) {
                        logged=Clock::now();POINT actual{};GetCursorPos(&actual);
                        std::fprintf(stderr,"reverse-shell-pointer id=%llu xy=%lld,%lld actual=%ld,%ld moved=%u hit=%p target=%p\n",(unsigned long long)event.id,(long long)x,(long long)y,actual.x,actual.y,unsigned(moved),WindowFromPoint(actual),source->window);
                    }
                }
            }
            break;
        }
        case vf::InputKind::button: {
            native.type=INPUT_MOUSE;
            DWORD down{},up{};
            switch(event.a){case 272:down=MOUSEEVENTF_LEFTDOWN;up=MOUSEEVENTF_LEFTUP;break;case 273:down=MOUSEEVENTF_RIGHTDOWN;up=MOUSEEVENTF_RIGHTUP;break;case 274:down=MOUSEEVENTF_MIDDLEDOWN;up=MOUSEEVENTF_MIDDLEUP;break;case 275:case 276:down=MOUSEEVENTF_XDOWN;up=MOUSEEVENTF_XUP;native.mi.mouseData=event.a==275?XBUTTON1:XBUTTON2;break;default:return;}
            native.mi.dwFlags=event.b?down:up;
            if(event.b) {
                auto target=source->window;
                if(source->ime_popup){std::lock_guard lock(source_mutex);for(const auto& [window,parent]:sources)if(parent->id==source->owner){target=window;break;}}
                focus(target);
            }
            SetLastError(0);const auto injected=SendInput(1,&native,sizeof(native));const auto error=GetLastError();
            POINT cursor{};GetCursorPos(&cursor);
            std::fprintf(stderr,"reverse-input-button id=%llu seq=%llu result=%u error=%lu cursor=%ld,%ld rect=%ld,%ld,%ld,%ld foreground=%p target=%p\n",(unsigned long long)event.id,(unsigned long long)event.sequence,injected,error,cursor.x,cursor.y,rect.left,rect.top,rect.right,rect.bottom,GetForegroundWindow(),source->window);
            if(injected==1){ime_priority.activity(scheduler_ms());if(event.b)held_buttons[event.a]=native;else held_buttons.erase(event.a);}
            break;
        }
        case vf::InputKind::wheel:
            native.type=INPUT_MOUSE;native.mi.dwFlags=event.a?MOUSEEVENTF_HWHEEL:MOUSEEVENTF_WHEEL;
            native.mi.mouseData=static_cast<DWORD>(event.b);SendInput(1,&native,sizeof(native));break;
        case vf::InputKind::key: {
            unsigned code=static_cast<unsigned>(event.a),scan=code;bool extended=false;
            switch(code){case 96:scan=0x1c;extended=true;break;case 97:scan=0x1d;extended=true;break;case 98:scan=0x35;extended=true;break;case 100:scan=0x38;extended=true;break;case 102:scan=0x47;extended=true;break;case 103:scan=0x48;extended=true;break;case 104:scan=0x49;extended=true;break;case 105:scan=0x4b;extended=true;break;case 106:scan=0x4d;extended=true;break;case 107:scan=0x4f;extended=true;break;case 108:scan=0x50;extended=true;break;case 109:scan=0x51;extended=true;break;case 110:scan=0x52;extended=true;break;case 111:scan=0x53;extended=true;break;case 125:scan=0x5b;extended=true;break;case 126:scan=0x5c;extended=true;break;case 127:scan=0x5d;extended=true;break;default:if(code>88)return;}
            native.type=INPUT_KEYBOARD;native.ki.wScan=static_cast<WORD>(scan);
            native.ki.dwFlags=KEYEVENTF_SCANCODE|(extended?KEYEVENTF_EXTENDEDKEY:0)|(event.b?0:KEYEVENTF_KEYUP);
            if(SendInput(1,&native,sizeof(native))==1){ime_priority.activity(scheduler_ms());if(event.b)held_keys[code]=native;else held_keys.erase(code);}
            break;
        }
        case vf::InputKind::focus:focus(source->window);break;
        case vf::InputKind::geometry: {
            {std::lock_guard lock(source->mutex);if(source->fullscreen_request || source->fullscreen_suppress || source->fullscreen_retiring){
                source->fullscreen_geometry=event;source->fullscreen_retiring=true;capture_wake.notify();return;
            }}
            if(source->shell_menu){std::lock_guard lock(source->mutex);source->geometry_ack=event.sequence;return;}
            if(event.c<=0 || event.d<=0 || event.c>16384 || event.d>16384)return;
            RECT outer{};if(!GetWindowRect(source->window,&outer))return;
            const bool applied=SetWindowPos(source->window,nullptr,event.a-(rect.left-outer.left),event.b-(rect.top-outer.top),
                event.c+(outer.right-outer.left)-(rect.right-rect.left),event.d+(outer.bottom-outer.top)-(rect.bottom-rect.top),SWP_NOACTIVATE|SWP_NOZORDER);
            if(applied){std::lock_guard lock(source->mutex);source->geometry_ack=event.sequence;}
            else std::fprintf(stderr,"reverse geometry failed id=%llu error=%lu\n",static_cast<unsigned long long>(source->id),GetLastError());
            break;
        }
        case vf::InputKind::close:PostMessageW(source->window,WM_CLOSE,0,0);break;
        default:break;
        }
    }
    void input_loop() {
        HDESK desktop=OpenInputDesktop(0,FALSE,GENERIC_ALL);if(desktop)SetThreadDesktop(desktop);
        try {
            while(running) {
                std::uint8_t prefix[4];if(fread(prefix,1,4,stdin)!=4)break;
                vf::Reader length{{prefix,4}};auto size=length.u32();if(size!=40 && !(size==24 && viewflow::activity::negotiated()))throw std::runtime_error("reverse input record size");
                std::vector<std::uint8_t> bytes(size);if(fread(bytes.data(),1,size,stdin)!=size)break;
                if(size==24){
                    if(vf::Reader{bytes}.u32()==6){std::lock_guard lock(activity_mutex);
                        viewflow::activity::observe(activity,viewflow::activity::unpack_hint(bytes),viewflow::activity::now_us());continue;}
                    const auto value=viewflow::activity::unpack_feedback(bytes);
                    std::lock_guard lock(activity_mutex);auto& stage=lane_feedback[value.lane][value.stage];
                    const bool keyframe=stage.keyframe || value.keyframe;stage=value;stage.keyframe=keyframe;continue;
                }
                input(vf::unpack_input(bytes));
            }
        }catch(const std::exception& error){std::fprintf(stderr,"reverse input: %s\n",error.what());}
        release();running=false;if(desktop)CloseDesktop(desktop);
    }
    // Candidate -> hidden TSF/IME helpers -> application. Resolve after enrollment.
    std::uint64_t owner_id(HWND window) {
        std::set<HWND> visited{window};
        auto owner=GetWindow(window,GW_OWNER);
        for(unsigned depth=0;owner && depth<32 && visited.insert(owner).second;++depth) {
            if(auto found=sources.find(owner);found!=sources.end())return found->second->id;
            const auto next=GetWindow(owner,GW_OWNER);owner=next?next:GetParent(owner);
        }
        if(auto current=sources.find(window);current!=sources.end() && current->second->ime_popup) {
            const auto foreground=GetForegroundWindow();
            if(auto found=sources.find(foreground);found!=sources.end() && !found->second->ime_popup)return found->second->id;
        }
        return 0;
    }
    bool candidate(HWND window) {
        if(auto existing=sources.find(window);existing!=sources.end()){
            std::lock_guard lock(existing->second->mutex);
            if(existing->second->fullscreen_suppress || existing->second->fullscreen_retiring)return true;
        }
        if(!IsWindowVisible(window) || (IsIconic(window) && !fusion.enabled()))return false;
        DWORD pid{};GetWindowThreadProcessId(window,&pid);if(!pid || pid==GetCurrentProcessId())return false;
        const auto selected=std::getenv("VIEWFLOW_PROFILE_SOURCE_PID");if(vf_diag::enabled() && selected && pid!=std::strtoul(selected,nullptr,10))return false;
        wchar_t cls[256]{};GetClassNameW(window,cls,256);
        if(wcsncmp(cls,L"Viewflow",8)==0 || wcscmp(cls,L"Progman")==0 || wcscmp(cls,L"WorkerW")==0 || wcscmp(cls,L"Shell_TrayWnd")==0 || wcscmp(cls,L"Shell_SecondaryTrayWnd")==0)return false;
        DWORD cloaked{};DwmGetWindowAttribute(window,DWMWA_CLOAKED,&cloaked,sizeof(cloaked));if(cloaked)return false;
        auto rect=bounds(window);
        if(IsIconic(window) && fusion.enabled()) {
            WINDOWPLACEMENT placement{sizeof(placement)};
            if(GetWindowPlacement(window,&placement))rect=placement.rcNormalPosition;
        }
        // Warm a narrow resident strip so an approaching window keeps its WGC
        // texture and proxy identity before the pointer crosses the shared edge.
        constexpr int resident=256;
        if(auto move=observed_move_for(window);move && move->pid==pid &&
            (!move->ended || sources.contains(window)))return true;
        if(fullscreen_enabled && fullscreen_transport && owned_dd_fixture(window,pid))return true;
        const bool eligible=rect.right>left-resident && rect.left<right+resident && rect.bottom>top-resident && rect.top<bottom+resident && rect.right>rect.left && rect.bottom>rect.top;
        if(eligible)fusion.manage(window);
        return eligible;
    }
    void start_capture(const std::shared_ptr<Source>& source) {
        // Stop outside source_mutex and the callback mutex: stop joins callbacks.
        source->capture.stop();
        {std::lock_guard lock(source->mutex);source->closed=false;source->retry_at=Clock::now()+std::chrono::milliseconds(500);}
            viewflow::windows_capture::FrameCallbacks callbacks;
            callbacks.on_geometry=[weak=std::weak_ptr<Source>(source)](const viewflow::windows_capture::CaptureGeometry& geometry){
                if(auto source=weak.lock()){
                    std::lock_guard lock(source->mutex);
                    if(source->fullscreen_suppress)return;
                    if(source->requested_geometry.content_width!=geometry.content_width || source->requested_geometry.content_height!=geometry.content_height)source->geometry_seen_at=Clock::now();
                    source->requested_geometry=geometry;
                    if(vf_diag::metrics())vf_diag::trace("profile_geometry id=%llu at=%lld epoch=%llu width=%u height=%u\n",static_cast<unsigned long long>(source->id),qpc100ns(),static_cast<unsigned long long>(geometry.epoch),geometry.content_width,geometry.content_height);
                }
            };
            callbacks.on_frame=[this,weak=std::weak_ptr<Source>(source)](const viewflow::windows_capture::CapturedFrame& frame) {
                auto source=weak.lock();if(!source)return;
                const auto callback_qpc=vf_diag::metrics()?qpc100ns():0;
                if(vf_diag::metrics())vf_diag::trace("profile_capture_entry id=%llu capture=%lld callback_qpc=%lld width=%u height=%u\n",source->id,frame.system_relative_time_100ns,callback_qpc,frame.geometry.content_width,frame.geometry.content_height);
                const auto callback_begin=vf_diag::metrics()?Clock::now():Clock::time_point{};
                std::unique_lock lock(source->mutex);
                if(source->fullscreen_suppress || frame.system_relative_time_100ns<source->wgc_after)return;
                const auto callback_locked=vf_diag::metrics()?Clock::now():Clock::time_point{};
                auto cw=frame.geometry.content_width,ch=frame.geometry.content_height;
                unsigned capture_x=0,capture_y=0;
                RECT outer{};const auto visible=App::bounds(source->window);
                // WGC has no desktop origin in its texture. Crop only when the
                // captured extent proves its origin is GetWindowRect; otherwise
                // the usual WGC extended-frame body is already shadow-free.
                if(GetWindowRect(source->window,&outer) && cw==unsigned(outer.right-outer.left) && ch==unsigned(outer.bottom-outer.top) &&
                    visible.left>=outer.left && visible.top>=outer.top && visible.right<=outer.right && visible.bottom<=outer.bottom && visible.right>visible.left && visible.bottom>visible.top){
                    capture_x=visible.left-outer.left;capture_y=visible.top-outer.top;
                    cw=visible.right-visible.left;ch=visible.bottom-visible.top;
                }
                // Source sends only the real window body. Each destination owns
                // its local shadow; neither custom nor native exterior shadows
                // are encoded into the window tile.
                if(source->shell_menu) {
                    const auto crop=source->shell_crop.measure(device.Get(),context.Get(),frame.surface);
                    if(!crop)return;
                    capture_x=crop->left;capture_y=crop->top;cw=crop->right-crop->left;ch=crop->bottom-crop->top;
                    source->shell_x=capture_x;source->shell_y=capture_y;
                }
                const auto fw=cw,fh=ch;
                D3D11_BOX box{capture_x,capture_y,0,capture_x+cw,capture_y+ch,1};
                vf::shm::CaptureStaging::Timing timing;
                Clock::time_point prepared{};bool staging_acquired=false;
                const auto report_staging=[&] {
                    if(capture_staging && vf_diag::metrics()) {
                        const auto ms=[](auto a,auto b){return std::chrono::duration<double,std::milli>(b-a).count();};
                        vf_diag::trace("profile_capture_stages id=%llu capture=%lld lock_ms=%.3f geometry_ms=%.3f prepare_ms=%.3f copy_ms=%.3f end_ms=%.3f flush_ms=%.3f acquired=%u\n",source->id,frame.system_relative_time_100ns,ms(callback_begin,callback_locked),ms(callback_locked,prepared),timing.prepare_ms,timing.copy_ms,timing.end_ms,timing.flush_ms,unsigned(staging_acquired));
                    }
                };
                if(capture_staging && capture_bands) {
                    prepared=vf_diag::metrics()?Clock::now():Clock::time_point{};
                    auto captured=source->band_pool.copy(device.Get(),context.Get(),frame.surface,box,source->bands,capture_bands,vf_diag::metrics()?&timing:nullptr);
                    staging_acquired=bool(captured);if(!captured){lock.unlock();
                        if(vf_diag::metrics())vf_diag::trace("profile_capture_drop id=%llu capture=%lld reason=band_pool_busy callback_qpc=%lld\n",source->id,frame.system_relative_time_100ns,callback_qpc);
                        report_staging();return;}
                    if(source->frame_width!=fw || source->frame_height!=fh)source->resident.reset();
                    source->shared_source_snapshot.reset();source->shared_snapshot_device=nullptr;source->bands=std::move(captured);source->staging.reset();source->texture.Reset();source->texture_view.Reset();
                    source->frame_width=fw;source->frame_height=fh;
                }else if(capture_staging) {
                    prepared=vf_diag::metrics()?Clock::now():Clock::time_point{};
                    auto captured=source->staging_pool.copy(device.Get(),context.Get(),frame.surface,box,source->staging,vf_diag::metrics()?&timing:nullptr);
                    staging_acquired=bool(captured);
                    if(!captured){lock.unlock();report_staging();return;}
                    if(source->frame_width!=fw || source->frame_height!=fh)source->resident.reset();
                    source->shared_source_snapshot.reset();source->shared_snapshot_device=nullptr;source->staging=std::move(captured);source->texture=source->staging->texture;source->texture_view.Reset();
                    source->frame_width=fw;source->frame_height=fh;
                }else {
                bool shared_captured=false;
                if(source->shared_source_pool && !source->shared_source_failed) {
                    std::shared_ptr<vf::d12::SharedCapture::Snapshot> snapshot;
                    const auto status=source->shared_source_pool->capture(frame.surface,snapshot,&box);
                    if(status==vf::d12::SharedCapture::Status::busy) {
                        // The latest metadata and pixels remain paired. Never
                        // wait on a consumer fence in the WGC callback.
                        lock.unlock();return;
                    }
                    if(status==vf::d12::SharedCapture::Status::ready) {
                        if(source->frame_width!=fw || source->frame_height!=fh)source->resident.reset();
                        source->texture=snapshot->owned11;source->texture_view=snapshot->view11;
                        source->shared_source_snapshot=std::move(snapshot);source->shared_snapshot_device=source->shared_source_device;
                        source->frame_width=fw;source->frame_height=fh;shared_captured=true;
                    }else {
                        // Keep failed/in-flight pool entries alive until Source
                        // teardown on management, while ordinary capture recovers.
                        source->shared_source_failed=true;
                        std::fprintf(stderr,"reverse-d12 source-pool fallback id=%llu hr=0x%08lx reason=%s\n",
                            static_cast<unsigned long long>(source->id),static_cast<unsigned long>(source->shared_source_pool->last_error()),source->shared_source_pool->diagnostic());
                    }
                }
                if(!shared_captured) {
                const bool was_shared=bool(source->shared_source_snapshot);
                source->shared_source_snapshot.reset();source->shared_snapshot_device=nullptr;
                D3D11_TEXTURE2D_DESC desc{};frame.surface->GetDesc(&desc);
                // A leased shared source must never be overwritten by fallback.
                if(was_shared || !source->texture || source->frame_width!=fw || source->frame_height!=fh) {
                    source->resident.reset();
                    desc.Width=fw;desc.Height=fh;
                    desc.MipLevels=1;desc.ArraySize=1;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;desc.MiscFlags=0;desc.Usage=D3D11_USAGE_DEFAULT;desc.CPUAccessFlags=0;
                    ComPtr<ID3D11Texture2D> replacement;
                    check(device->CreateTexture2D(&desc,nullptr,&replacement));
                    ComPtr<ID3D11ShaderResourceView> replacement_view;
                    check(device->CreateShaderResourceView(replacement.Get(),nullptr,&replacement_view));
                    source->texture=std::move(replacement);source->texture_view=std::move(replacement_view);
                    source->frame_width=fw;source->frame_height=fh;
                    std::fprintf(stderr,"reverse-window-body id=%llu silhouette=source-alpha source-shadow=unclassified body=%ux%u crop=%u,%u premultiplied=1\n",source->id,cw,ch,capture_x,capture_y);
                }
                context->CopySubresourceRegion(source->texture.Get(),0,0,0,0,frame.surface,0,&box);
                }
                }
                if((source->ime_popup || source->shell_menu) && source->capture_version==0){
                    ime_priority.activity(scheduler_ms());ime_priority.first_frame();
                    std::fprintf(stderr,"reverse-ime-first-capture id=%llu discovery-us=%lld\n",source->id,std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-source->discovered_at).count());
                }
                source->fullscreen_snapshot=false;source->desktop_output_snapshot=false;
                source->geometry=frame.geometry;source->capture_width=frame.geometry.content_width;source->capture_height=frame.geometry.content_height;source->geometry.content_width=cw;source->geometry.content_height=ch;source->pts=frame.system_relative_time_100ns;++source->capture_version;
                const auto copied_at=vf_diag::metrics()?qpc100ns():0;
                // Publish ownership before diagnostic I/O. A slow stderr pipe
                // must not keep the sender waiting on this source mutex.
                lock.unlock();capture_wake.notify();
                report_staging();
                if(vf_diag::metrics())vf_diag::trace("profile_capture id=%llu capture=%lld copied=%lld width=%u height=%u callback_qpc=%lld wgc_entered=%lld wgc_locked=%lld wgc_acquired=%lld wgc_geometry_done=%lld wgc_surface_ready=%lld\n",source->id,frame.system_relative_time_100ns,copied_at,frame.geometry.content_width,frame.geometry.content_height,callback_qpc,frame.delivery.entered,frame.delivery.locked,frame.delivery.acquired,frame.delivery.geometry_done,frame.delivery.surface_ready);
            };
            callbacks.on_terminal=[weak=std::weak_ptr<Source>(source)](auto failure,std::uint32_t hr){
                if(auto source=weak.lock()){std::lock_guard lock(source->mutex);source->closed=true;std::fprintf(stderr,"reverse-capture-terminal id=%llu reason=%u hr=%08x\n",static_cast<unsigned long long>(source->id),static_cast<unsigned>(failure),hr);}
            };
            const auto result=source->capture.start(source->window,{capture_limit,capture_limit,capture_pixels},std::move(callbacks),device.Get());
            if(!result){std::lock_guard lock(source->mutex);source->closed=true;std::fprintf(stderr,"reverse-capture-start hwnd=%p hr=%08x retry=true\n",source->window,result.native_hresult);}
    }
    void poll_fullscreen() {
        if(!fullscreen_enabled)return;
        for(auto it=retiring_sources.begin();it!=retiring_sources.end();){
            auto& source=*it;
            if(!source->fullscreen_capture || source->fullscreen_capture->restore()){
                if(fullscreen_owner==source->id)fullscreen_owner=0;it=retiring_sources.erase(it);
            }else ++it;
        }
        std::vector<std::shared_ptr<Source>> current;
        {std::lock_guard lock(source_mutex);for(auto& [_,source]:sources)current.push_back(source);}
        for(auto& source:current){
            bool restart=false,stop_wgc=false;
            {
                std::lock_guard lock(source->mutex);
                const auto resize_body=[&](const vf::Input& event){
                    if(event.c<=0||event.d<=0||event.c>16384||event.d>16384)return;
                    RECT outer{};const auto visible=bounds(source->window);
                    if(GetWindowRect(source->window,&outer) && SetWindowPos(source->window,nullptr,
                        event.a-(visible.left-outer.left),event.b-(visible.top-outer.top),
                        event.c+(outer.right-outer.left)-(visible.right-visible.left),
                        event.d+(outer.bottom-outer.top)-(visible.bottom-visible.top),SWP_NOACTIVATE|SWP_NOZORDER))
                        source->geometry_ack=event.sequence;
                };
                if(source->fullscreen_request || source->fullscreen_retiring){
                    if(source->fullscreen_capture){
                        if(!source->fullscreen_capture->restore()){source->fullscreen_retiring=true;continue;}
                        source->fullscreen_capture.reset();if(fullscreen_owner==source->id)fullscreen_owner=0;
                        source->wgc_after=qpc100ns();restart=true;
                    }
                    source->fullscreen_suppress=false;source->fullscreen_retiring=false;
                    if(source->fullscreen_request){
                        const auto request=*source->fullscreen_request;source->fullscreen_request.reset();
                        source->fullscreen_generation=request.sequence;source->fullscreen_intent=request;
                        if(request.a==2){
                            const auto original=bounds(source->window);
                            HRESULT hr=DXGI_ERROR_NOT_CURRENTLY_AVAILABLE;
                            wchar_t configured[128]{};const auto count=GetEnvironmentVariableW(L"VIEWFLOW_FULLSCREEN_OUTPUT",configured,128);
                            if(fullscreen_transport && !source->fullscreen_force_wgc && (!fullscreen_owner || fullscreen_owner==source->id) && count>0 && count<128){
                                struct Find {const wchar_t* name;HMONITOR monitor{};} found{configured};
                                EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR m,HDC,LPRECT,LPARAM arg)->BOOL{
                                    auto& f=*reinterpret_cast<Find*>(arg);MONITORINFOEXW info{};info.cbSize=sizeof(info);
                                    if(GetMonitorInfoW(m,&info)&&!std::wcscmp(info.szDevice,f.name)){f.monitor=m;return FALSE;}return TRUE;
                                },reinterpret_cast<LPARAM>(&found));
                                if(found.monitor){
                                    ComPtr<IDXGIDevice> dxgi;ComPtr<IDXGIAdapter> adapter;DXGI_ADAPTER_DESC desc{};
                                    hr=device.As(&dxgi);if(SUCCEEDED(hr))hr=dxgi->GetAdapter(&adapter);if(SUCCEEDED(hr))hr=adapter->GetDesc(&desc);
                                    if(SUCCEEDED(hr)&&!fullscreen_device)hr=D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&fullscreen_device));
                                    vf::d12::OutputIdentity identity;
                                    if(SUCCEEDED(hr))hr=vf::d12::query_output_identity(desc.AdapterLuid,configured,identity);
                                    if(SUCCEEDED(hr)){
                                        source->fullscreen_capture=std::make_unique<vf::d12::FullscreenWindowCapture>();
                                        hr=source->fullscreen_capture->bind(source->window,found.monitor,identity,device.Get(),context.Get(),fullscreen_device.Get(),request.c,request.d,request.sequence);
                                    }
                                }
                            }
                            if(SUCCEEDED(hr)){
                                fullscreen_owner=source->id;source->fullscreen_suppress=true;source->fullscreen_snapshot=true;
                                source->fullscreen_presentation=original;restart=false;stop_wgc=true;
                                std::fprintf(stderr,"reverse-fullscreen id=%llu route=desktop-duplication generation=%llu width=%d height=%d\n",source->id,request.sequence,request.c,request.d);
                            }else{
                                if(source->fullscreen_capture && !source->fullscreen_capture->restore()){
                                    fullscreen_owner=source->id;source->fullscreen_suppress=true;source->fullscreen_retiring=true;
                                    source->fullscreen_request=request;source->fullscreen_force_wgc=true;continue;
                                }
                                source->fullscreen_capture.reset();
                                vf::Input geometry=request;geometry.a=original.left;geometry.b=original.top;resize_body(geometry);
                                source->wgc_after=qpc100ns();restart=true;
                                std::fprintf(stderr,"reverse-fullscreen id=%llu route=wgc reason=dd-unavailable hr=0x%08lx width=%d height=%d\n",source->id,static_cast<unsigned long>(hr),request.c,request.d);
                            }
                        }else source->fullscreen_intent.reset();
                    }
                    if(source->fullscreen_geometry){
                        const auto geometry=*source->fullscreen_geometry;source->fullscreen_geometry.reset();
                        if(geometry.sequence>source->fullscreen_generation){
                            // Exit request restoration is already complete. A later
                            // ordinary geometry command wins over the saved bounds.
                            resize_body(geometry);source->wgc_after=qpc100ns();restart=true;
                        }
                    }
                }
                if(source->fullscreen_capture && source->fullscreen_capture->bound()){
                    ComPtr<ID3D11Texture2D> snapshot;ComPtr<ID3D11ShaderResourceView> snapshot_view;
                    std::shared_ptr<vf::d12::SharedCapture::Snapshot> shared_snapshot;
                    const auto result=source->fullscreen_capture->poll(snapshot,snapshot_view,source->fullscreen_generation,&shared_snapshot);
                    if(result==vf::d12::FullscreenWindowCapture::Status::ready){
                        const auto hr=snapshot_view?S_OK:E_FAIL;
                        if(SUCCEEDED(hr)){
                            D3D11_TEXTURE2D_DESC desc{};snapshot->GetDesc(&desc);
                            source->shared_source_snapshot=std::move(shared_snapshot);
                            source->shared_snapshot_device=source->shared_source_snapshot?source->fullscreen_capture->shared_device():nullptr;
                            source->texture=std::move(snapshot);source->texture_view=std::move(snapshot_view);source->bands.reset();source->staging.reset();
                            source->frame_width=source->capture_width=source->geometry.content_width=desc.Width;
                            source->frame_height=source->capture_height=source->geometry.content_height=desc.Height;
                            source->fullscreen_presentation=source->fullscreen_capture->presentation_rect(bounds(source->window));
                            source->fullscreen_snapshot=true;source->desktop_output_snapshot=true;source->resident.reset();source->pts=source->fullscreen_capture->capture_time_100ns();if(!source->pts)source->pts=qpc100ns();++source->capture_version;
                            if(source->owned_dd_test)vf_diag::trace("profile_dd_capture id=%llu capture=%lld capture_clock=dxgi-last-present copied=%lld width=%u height=%u generation=%llu shared_source=%u\n",source->id,source->pts,qpc100ns(),desc.Width,desc.Height,source->fullscreen_generation,unsigned(bool(source->shared_source_snapshot)));
                            capture_wake.notify();
                        }else{source->fullscreen_retiring=true;source->fullscreen_request=source->fullscreen_intent;source->fullscreen_force_wgc=true;}
                    }else if(result==vf::d12::FullscreenWindowCapture::Status::window_fallback){
                        source->fullscreen_retiring=true;source->fullscreen_request=source->fullscreen_intent;source->fullscreen_force_wgc=true;
                    }
                }
            }
            if(stop_wgc)source->capture.stop(); // Joins callbacks outside Source mutex.
            if(restart)start_capture(source);
        }
    }
    void inventory() {
        const auto found=vf::capture_window_inventory();
        if(!inventory_logged){std::fprintf(stderr,"reverse-inventory windows=%zu viewport=%d,%d,%d,%d\n",found.size(),left,top,right,bottom);inventory_logged=true;}
        std::map<HWND,bool> eligible;
        std::set<HWND> shell_windows;
        for(const auto entry:found)if(entry.shell)shell_windows.insert(entry.window);
        for(const auto entry:found)if(candidate(entry.window) && eligible.size()<16)eligible[entry.window]=entry.ime;
        {std::lock_guard lock(move_mutex);std::erase_if(move_origins,[&](const auto& move){return move.second.ended && !eligible.contains(move.first);});}
        std::vector<std::shared_ptr<Source>> removed;
        {
            std::lock_guard lock(source_mutex);
            for(auto it=sources.begin();it!=sources.end();) {
                DWORD pid{};GetWindowThreadProcessId(it->first,&pid);
                if(!eligible.contains(it->first) || pid!=it->second->pid){removed.push_back(it->second);it=sources.erase(it);}else ++it;
            }
        }
        for(auto& source:removed){source->capture.stop();if(source->fullscreen_capture && !source->fullscreen_capture->restore()){source->fullscreen_retiring=true;retiring_sources.push_back(source);}else if(fullscreen_owner==source->id)fullscreen_owner=0;std::fprintf(stderr,"reverse-window-removed id=%llu\n",static_cast<unsigned long long>(source->id));}
        std::vector<std::pair<HWND,bool>> startup_order(eligible.begin(),eligible.end());
        std::stable_sort(startup_order.begin(),startup_order.end(),[](const auto& a,const auto& b){return a.second>b.second;});
        for(const auto [window,ime]:startup_order) {
            std::shared_ptr<Source> existing;
            {std::lock_guard lock(source_mutex);if(auto it=sources.find(window);it!=sources.end())existing=it->second;}
            if(existing) {
                bool retry,resize_pending;
                {
                    std::lock_guard lock(existing->mutex);const auto now=Clock::now();
                    resize_pending=existing->texture && existing->requested_geometry.content_width &&
                        (existing->capture_width!=existing->requested_geometry.content_width || existing->capture_height!=existing->requested_geometry.content_height) &&
                        now-existing->geometry_seen_at>=std::chrono::milliseconds(500);
                    retry=!existing->fullscreen_suppress && (existing->closed || resize_pending) && now>=existing->retry_at;
                }
                // A one-shot resize may produce only the discarded transition
                // frame. Restart this capture if no correctly sized frame follows;
                // retain its last texture/proxy while WGC acquires current pixels.
                if(retry){std::fprintf(stderr,"reverse-capture-retry id=%llu hwnd=%p resize_pending=%u\n",static_cast<unsigned long long>(existing->id),window,unsigned(resize_pending));start_capture(existing);}
                continue;
            }
            auto source=std::make_shared<Source>();source->window=window;source->id=next_id++;GetWindowThreadProcessId(window,&source->pid);
            if(fullscreen_enabled && fullscreen_transport && owned_dd_fixture(window,source->pid)){
                source->owned_dd_test=true;
                source->fullscreen_request=vf::Input{source->id,1,static_cast<vf::InputKind>(17),2,1,6144,3456};
                std::fprintf(stderr,"profile_dd_fixture_request id=%llu pid=%lu generation=1 width=6144 height=3456 identity=pid-creation-class-token scope=owned-producer-route\n",source->id,source->pid);
            }
            source->ime_popup=ime;
            source->shell_menu=shell_windows.contains(window);
            if(!ime && !source->shell_menu)source->icon=vf::source_icon(window);
            start_capture(source);
            {std::lock_guard lock(source_mutex);sources.emplace(window,source);}
            wchar_t window_class[256]{};GetClassNameW(window,window_class,256);
            std::fprintf(stderr,"reverse-window-added id=%llu hwnd=%p ime_popup=%u class=%ls root_owner=%p\n",static_cast<unsigned long long>(source->id),window,source->ime_popup,window_class,GetAncestor(window,GA_ROOTOWNER));
        }
        {std::lock_guard lock(source_mutex);for(auto& [window,source]:sources){
            const auto owner=owner_id(window);
            if(source->owner!=owner){source->owner=owner;std::fprintf(stderr,"reverse-window-owner id=%llu owner=%llu ime_popup=%u\n",static_cast<unsigned long long>(source->id),static_cast<unsigned long long>(owner),source->ime_popup);}
        }}
    }
};
void write_frame(const vf::Frame& frame) {
    const auto pack_begin=qpc100ns();auto bytes=vf::pack_frame(frame);const auto pack_end=qpc100ns();vf::Writer prefix;prefix.u32(static_cast<std::uint32_t>(bytes.size()));
    if(fwrite(prefix.bytes.data(),1,4,stdout)!=4 || fwrite(bytes.data(),1,bytes.size(),stdout)!=bytes.size() || fflush(stdout)!=0)throw std::runtime_error("reverse output closed");
    if(vf_diag::metrics())vf_diag::trace("profile_output pts=%lld pack_begin=%lld pack_end=%lld write_end=%lld color=%zu alpha=%zu bytes=%zu\n",frame.pts,pack_begin,pack_end,qpc100ns(),frame.color.size(),frame.alpha.size(),bytes.size());
}
std::string title(HWND window) {
    wchar_t text[2048]{};const auto count=GetWindowTextW(window,text,2048);if(count<=0)return "Windows";
    const auto size=WideCharToMultiByte(CP_UTF8,0,text,count,nullptr,0,nullptr,nullptr);
    std::string result(size,0);WideCharToMultiByte(CP_UTF8,0,text,count,result.data(),size,nullptr,nullptr);
    if(result.size()>4096)result.resize(4096);return result;
}
}
int main(int argc,char** argv) {
    if(argc==2 && std::string_view(argv[1])=="--activity-priority-capabilities") { _setmode(_fileno(stdout), _O_BINARY); std::puts("activity-priority-v1"); return 0; }
    try {
        std::vector<std::string_view> arguments;
        for(int i=1;i<argc;++i)arguments.emplace_back(argv[i]);
        auto options=vf::parse_options(arguments);
        if(options.mode_file.empty() && !options.explicit_mode){
            wchar_t executable[32768]{};const auto length=GetModuleFileNameW(nullptr,executable,32768);
            if(!length || length>=32768)throw std::runtime_error("cannot locate reverse performance settings");
            options.mode_file=std::filesystem::path(executable).parent_path()/L"reverse-performance-mode";
        }
        if(!options.mode_file.empty())if(auto mode=vf::read_mode(options.mode_file))options.mode=*mode;
        if(options.status_only){
            std::printf("{\"schema\":1,\"mode\":\"%s\",\"max_pending\":%u,\"scope\":\"configured\"}\n",vf::mode_name(options.mode),vf::pending_limit(options.mode));
            return 0;
        }
        std::fprintf(stderr,"reverse_performance mode=%s max_pending=%u\n",vf::mode_name(options.mode),vf::pending_limit(options.mode));
        _setmode(_fileno(stdin),_O_BINARY);_setmode(_fileno(stdout),_O_BINARY);
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        const auto input_desktop=OpenInputDesktop(0,FALSE,GENERIC_ALL);
        if(!input_desktop || !SetThreadDesktop(input_desktop))throw std::runtime_error("reverse capture input desktop unavailable="+std::to_string(GetLastError()));
        // Keep the bound desktop handle alive for this process's capture lifetime.
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        TimerResolution timer_resolution;
        App app;
        MoveObserver moves;
        app.left=options.bounds[0];app.top=options.bounds[1];app.right=options.bounds[2];app.bottom=options.bounds[3];
        auto mode_check_at=Clock::now();
        auto fusion_check_at=Clock::now();
        D3D_FEATURE_LEVEL level{};
        check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT|D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
            nullptr,0,D3D11_SDK_VERSION,&app.device,&level,&app.context));
        ComPtr<ID3D11Multithread> mt;check(app.device.As(&mt));mt->SetMultithreadProtected(TRUE);
        std::shared_ptr<vf::shm::Mapping> shared_mapping;
        std::shared_ptr<vf::shm::Frames> shared_frames;
        const auto shm_index=options.shared_memory?std::to_string(*options.shared_memory):std::string(std::getenv("VIEWFLOW_IVSHMEM")?std::getenv("VIEWFLOW_IVSHMEM"):"");
        if(!shm_index.empty()) {
            try {
                unsigned value{};const std::string_view text(shm_index);auto parsed=std::from_chars(text.data(),text.data()+text.size(),value);
                if(parsed.ec!=std::errc{} || parsed.ptr!=text.data()+text.size())throw std::runtime_error("IVSHMEM device index must be an integer");
                shared_mapping=std::make_shared<vf::shm::Mapping>(value);shared_frames=std::make_shared<vf::shm::Frames>(shared_mapping->frames());shared_frames->streaming_writes=true;shared_frames->parallel_writes=true;
                app.capture_limit=vf::shared_max_dimension;app.capture_pixels=vf::shared_max_pixels;
                std::fprintf(stderr,"reverse-media transport=ivshmem format=bgra codec=none device=%u\n",value);
            }catch(const std::exception& error){std::fprintf(stderr,"reverse-media fallback=encoded reason=%s\n",error.what());}
        }
        const auto* progressive_option=std::getenv("VIEWFLOW_SHM_PROGRESSIVE");
        const bool progressive_enabled=progressive_option && std::string_view(progressive_option)=="1";
        const bool progressive_probe_enabled=progressive_enabled || std::getenv("VIEWFLOW_SHM_NEGOTIATION_PROBE")!=nullptr;
        vf::shm::ProgressiveProbe progressive_probe(progressive_probe_enabled && shared_frames?&shared_frames->progressive_negotiation():nullptr,true,vf::shm::progressive_feature|(progressive_enabled?vf::shm::progressive_payload_feature:0));
        bool progressive_probe_agreed=false;
        const bool d12_enabled=std::getenv("VIEWFLOW_SHM_D12") && std::string_view(std::getenv("VIEWFLOW_SHM_D12"))=="1";
        app.fullscreen_transport=bool(shared_frames) && d12_enabled && !progressive_enabled;
        if(d12_enabled)std::fprintf(stderr,"reverse-d12 requested=1 default=off eligibility=SHM1-tight-DEFAULT flags=CAPTURE_STAGING:0,PROGRESSIVE:0 banks=lazy-selected-slot\n");
        std::thread input([&]{app.input_loop();});
        struct Lane {
            std::unique_ptr<vf::shm::Readback> readback;
            std::unique_ptr<vf::d12::Transport> d12;
            bool d12_attempted=false;
            std::uint64_t d12_cpu_frames=0;
            std::unique_ptr<vf::HardwareEncoder> encoder;std::unique_ptr<vf::AlphaPlane> alpha;
            ComPtr<ID3D11Texture2D> atlas;ComPtr<ID3D11ShaderResourceView> atlas_view;ComPtr<ID3D11RenderTargetView> atlas_target;
            vf::FrameChangeTracker changes;std::uint64_t unchanged_skips{},submitted_urgent{},epoch{};
            Clock::time_point last_submission{},next_frame{};
            std::array<std::uint64_t,3> skips{};unsigned reported_fps{};
            bool force_keyframe=true;
            std::vector<std::uint8_t> raw_alpha,last_raw_alpha,last_encoded_alpha,opaque_encoded_alpha;
            std::future<std::pair<std::vector<std::uint8_t>,std::vector<std::uint8_t>>> alpha_work;
            std::int64_t alpha_work_tag{};
            vf::AtlasCapacity capacity;
            unsigned width{},height{};std::map<std::int64_t,vf::Frame> pending;
            viewflow::activity::Congestion congestion;
        };
        Lane lanes[2];
        vf::shm::ReadbackWait readback_wait;
        const bool activity_enabled=viewflow::activity::negotiated();bool dual=activity_enabled;
        bool alpha_async=activity_enabled;
        App::Scheduling previous_schedule;std::uint64_t activity_epoch=1;
        viewflow::activity::SingleLaneBudget single_budget;
        wchar_t direct_value[8]{};
        const bool direct_single_surface=GetEnvironmentVariableW(L"VIEWFLOW_REVERSE_DIRECT_SINGLE_SURFACE",direct_value,8)!=1 || direct_value[0]!=L'0';
        std::fprintf(stderr,"reverse_direct_single_surface enabled=%u\n",unsigned(direct_single_surface));
        wchar_t changes_value[8]{};
        const bool capture_changes=GetEnvironmentVariableW(L"VIEWFLOW_REVERSE_CAPTURE_CHANGES",changes_value,8)!=1 || changes_value[0]!=L'0';
        std::fprintf(stderr,"reverse_capture_changes enabled=%u\n",unsigned(capture_changes));
        auto inventory_at=Clock::now();auto inventory_completed=Clock::time_point{};std::int64_t pts=0;
        std::uint64_t inventory_wake=0;
        const bool immediate_shared_poll=std::getenv("VIEWFLOW_SHM_IMMEDIATE_POLL") && std::string_view(std::getenv("VIEWFLOW_SHM_IMMEDIATE_POLL"))=="1";
        const bool early_shared_poll=std::getenv("VIEWFLOW_SHM_EARLY_POLL") && std::string_view(std::getenv("VIEWFLOW_SHM_EARLY_POLL"))=="1";
        const auto poll_shared=[&](auto& lane) {
                if(lane.d12) {
                    vf::Frame ready;
                    if(lane.d12->poll(ready)) {
                        vf_diag::trace("profile_shared_ready pts=%lld payload=shm1 path=d12 completed=1\n",ready.pts);
                        for(const auto& tile:ready.tiles)if(tile.flags&vf::windows_desktop_output_flag)
                            vf_diag::trace("profile_dd_shared_ready pts=%lld id=%llu width=%u height=%u completed=1\n",ready.pts,tile.id,tile.width,tile.height);
                        write_frame(ready);
                        for(const auto& tile:ready.tiles)if(auto source=app.source_for(tile.id)){std::lock_guard lock(source->mutex);source->first_submitted=true;}
                    }
                    if(lane.d12->take_failed_frame()) {
                        lane.force_keyframe=true;
                        std::fprintf(stderr,"reverse-d12 fallback=cpu-readback hr=0x%08lx reason=%s\n",static_cast<unsigned long>(lane.d12->last_error()),lane.d12->diagnostic());
                    }
                }
                if(lane.readback)lane.readback->poll(app.context.Get(),[&](const vf::Frame& ready){
                    const bool early=ready.color.size()>=4 && vf::Reader{ready.color}.u32()==0x324d4853;
                    if(early)vf_diag::trace("profile_shared_announced pts=%lld payload=shm2\n",ready.pts);
                    if(vf_diag::metrics() && !early)vf_diag::trace("profile_shared_ready pts=%lld ready_ms=%.3f map_ms=%.3f publish_ms=%.3f gpu_copy_ms=%.3f superseded=%llu\n",ready.pts,lane.readback->last_timing.ready_ms,lane.readback->last_timing.map_ms,lane.readback->last_timing.publish_ms,lane.readback->last_timing.gpu_copy_ms,static_cast<unsigned long long>(lane.readback->superseded_frames));
                    write_frame(ready);
                    for(const auto& tile:ready.tiles)if(auto source=app.source_for(tile.id)){std::lock_guard lock(source->mutex);source->first_submitted=true;}
                });
        };
        std::array<std::vector<double>,3> loop_samples;auto loop_report=Clock::now();
        const auto loop_sample=[&](unsigned stage,Clock::time_point start){if(vf_diag::metrics() && loop_samples[stage].size()<4096)loop_samples[stage].push_back(std::chrono::duration<double,std::milli>(Clock::now()-start).count());};
        try {
            while(app.running) {
                const auto loop_begin=vf_diag::metrics()?Clock::now():Clock::time_point{};
                if(progressive_probe_enabled){const bool agreed=progressive_probe.poll();if(agreed!=progressive_probe_agreed){progressive_probe_agreed=agreed;std::fprintf(stderr,"progressive-negotiation role=writer agreed=%u payload_capable=%u probe=1\n",unsigned(agreed),unsigned(progressive_enabled));}}
                if(!options.fusion_file.empty() && Clock::now()>=fusion_check_at) {
                    fusion_check_at=Clock::now()+std::chrono::milliseconds(250);
                    std::ifstream setting(options.fusion_file);std::string value;
                    if(setting>>value && (value=="on" || value=="off"))app.fusion.set(value=="on");
                }
                if(!options.mode_file.empty() && Clock::now()>=mode_check_at){
                    mode_check_at=Clock::now()+std::chrono::milliseconds(250);
                    if(auto mode=vf::read_mode(options.mode_file);mode && *mode!=options.mode){
                        options.mode=*mode;
                        std::fprintf(stderr,"reverse_performance mode=%s max_pending=%u\n",vf::mode_name(options.mode),vf::pending_limit(options.mode));
                    }
                }
                // Publish already completed snapshots before potentially slow
                // window inventory. Keep the later poll for completions that
                // arrive during inventory/scheduling; neither poll waits on GPU.
                if(early_shared_poll)for(unsigned turn=0;turn<(activity_enabled?2u:1u);++turn)
                    poll_shared(lanes[activity_enabled?1-turn:0]);
                const auto wake=ime_priority.wake();
                if(Clock::now()>=inventory_at || (wake!=inventory_wake && Clock::now()-inventory_completed>=std::chrono::milliseconds(8))){inventory_wake=wake;const auto inventory_begin=vf_diag::metrics()?Clock::now():Clock::time_point{};app.inventory();loop_sample(2,inventory_begin);inventory_completed=Clock::now();inventory_at=inventory_completed+std::chrono::milliseconds(ime_priority.inventory_ms(scheduler_ms(),native_moves_pending()));}
                app.poll_fullscreen();
                auto schedule=activity_enabled?app.scheduling():App::Scheduling{};
                const auto preferred_window=schedule.preferred;
                if(!dual)schedule.preferred=0;
                if(schedule.preferred!=previous_schedule.preferred || schedule.focus!=previous_schedule.focus || schedule.members!=previous_schedule.members || schedule.roots!=previous_schedule.roots){
                    ++activity_epoch;previous_schedule=schedule;
                }
                // Poll both independent encoders on every turn; priority capture
                // never waits for background output readiness.
                for(unsigned turn=0;turn<(activity_enabled?2u:1u);++turn){
                    const unsigned lane_index=activity_enabled?1-turn:0;
                    auto& lane=lanes[lane_index];
                    const bool use_shared=shared_frames && shared_frames->reader_ready();
                    const unsigned atlas_max_width=use_shared?vf::shared_max_dimension:8192u;
                    const unsigned atlas_max_height=use_shared?vf::shared_max_dimension:4096u;
                    if(lane.atlas && bool(lane.readback)!=use_shared && lane.pending.empty() && (!lane.readback || lane.readback->idle()) && (!lane.d12 || !lane.d12->active())) {
                        lane=Lane{};std::fprintf(stderr,"reverse-media transition=%s lane=%u\n",use_shared?"ivshmem":"encoded",lane_index);
                    }
                    auto& encoder=lane.encoder;auto& alpha=lane.alpha;
                    auto& atlas=lane.atlas;auto& atlas_view=lane.atlas_view;auto& atlas_target=lane.atlas_target;
                    auto& changes=lane.changes;auto& unchanged_skips=lane.unchanged_skips;
                    auto& last_submission=lane.last_submission;auto& force_keyframe=lane.force_keyframe;
                    auto& raw_alpha=lane.raw_alpha;auto& last_raw_alpha=lane.last_raw_alpha;
                    auto& last_encoded_alpha=lane.last_encoded_alpha;auto& opaque_encoded_alpha=lane.opaque_encoded_alpha;
                    auto& capacity=lane.capacity;auto& width=lane.width;auto& height=lane.height;
                    auto& pending=lane.pending;auto& next_frame=lane.next_frame;auto& submitted_urgent=lane.submitted_urgent;
                    if(activity_enabled && lane.epoch!=activity_epoch){lane.epoch=activity_epoch;force_keyframe=true;next_frame=Clock::now();}
                    const auto feedback=app.feedback(lane_index);force_keyframe|=feedback.keyframe;
                    if(feedback.single_lane && dual){dual=false;break;}
                    const auto encode_age=pending.empty()?0ull:static_cast<unsigned long long>(std::max<std::int64_t>(0,qpc100ns()-pending.begin()->first)/10);
                    lane.congestion.observe(viewflow::activity::now_us(),std::max<std::uint64_t>(feedback.queue_us,encode_age),feedback.saturated || pending.size()>=vf::pending_limit(options.mode),60);
                    const auto background_fps=activity_enabled?lane.congestion.background_fps(60):60u;
                    const bool weighted_single=activity_enabled && !dual && preferred_window;
                    const bool background_due=!weighted_single || single_budget.background_due(viewflow::activity::now_us(),background_fps);
                    const auto target_fps=activity_enabled && !lane_index && !weighted_single?background_fps:60u;
                    if(vf_diag::metrics() && lane.reported_fps!=target_fps){lane.reported_fps=target_fps;vf_diag::trace("profile_budget lane=%u at=%lld target_fps=%u congestion=%u activity=%u preferred=%llu\n",lane_index,qpc100ns(),target_fps,lane.congestion.level(),unsigned(activity_enabled),(unsigned long long)preferred_window);}
                    const auto publish=[&](std::uint64_t id,std::uint64_t owner){
                        (void)owner;return !weighted_single || background_due || schedule.belongs(id,preferred_window);
                    };
                poll_shared(lane);
                if(encoder) {
                    std::vector<vf::EncodedFrame> encoded;check(encoder->poll(encoded));
                    for(auto& packet:encoded) {
                        auto found=pending.find(packet.timestamp);if(found==pending.end())continue;
                        found->second.color=std::move(packet.bytes);found->second.keyframe=packet.keyframe;
                        if(vf_diag::metrics())vf_diag::trace("profile_color_ready pts=%lld at=%lld\n",packet.timestamp,qpc100ns());
                    }
                }
                if(alpha){
                    if(lane.alpha_work.valid() && lane.alpha_work.wait_for(std::chrono::seconds(0))==std::future_status::ready){
                        auto packed=lane.alpha_work.get();
                        last_raw_alpha=std::move(packed.first);last_encoded_alpha=std::move(packed.second);
                        auto found=pending.find(lane.alpha_work_tag);
                        if(found==pending.end())throw std::runtime_error("packed alpha metadata missing");
                        found->second.alpha=last_encoded_alpha;
                    }
                    // Alpha compression owns plain bytes on one bounded worker
                    // per lane. A busy background packer never blocks priority MF.
                    for(;!lane.alpha_work.valid();){
                        std::int64_t tag{};bool opaque=false;const auto collect_begin=qpc100ns();
                        const auto result=alpha->poll(tag,raw_alpha,&opaque);check(result);if(result==S_FALSE)break;
                        const auto collect_end=qpc100ns();
                        auto found=pending.find(tag);if(found==pending.end())throw std::runtime_error("alpha metadata missing");
                        if(!opaque && raw_alpha!=last_raw_alpha){
                            if(alpha_async){
                                lane.alpha_work_tag=tag;
                                auto bytes=std::make_shared<std::vector<std::uint8_t>>(std::move(raw_alpha));
                                try {
                                    lane.alpha_work=std::async(std::launch::async,[bytes] {
                                        auto packed=vf::encode_windows_alpha(*bytes);
                                        return std::pair{std::move(*bytes),std::move(packed)};
                                    });
                                    break;
                                } catch(const std::system_error& error) {
                                    raw_alpha=std::move(*bytes);dual=false;alpha_async=false;
                                    std::fprintf(stderr,"activity_priority fallback=single reason=alpha-worker detail=%s\n",error.what());
                                }
                            }
                            last_encoded_alpha=vf::encode_windows_alpha(raw_alpha);last_raw_alpha.swap(raw_alpha);
                        }
                        found->second.alpha=opaque?opaque_encoded_alpha:last_encoded_alpha;
                        if(vf_diag::metrics())vf_diag::trace("profile_alpha_summary pts=%lld opaque=%u bytes=%zu\n",tag,unsigned(opaque),raw_alpha.size());
                        if(vf_diag::metrics())vf_diag::trace("profile_alpha_ready pts=%lld begin=%lld copied=%lld packed=%lld\n",tag,collect_begin,collect_end,qpc100ns());
                    }
                }
                while(!pending.empty() && !pending.begin()->second.color.empty() && !pending.begin()->second.alpha.empty()){
                    write_frame(pending.begin()->second);
                    for(const auto& tile:pending.begin()->second.tiles)if(tile.flags&vf::application_icon_flag)
                        if(auto source=app.source_for(tile.id)){std::lock_guard lock(source->mutex);source->icon_sent=true;}
                    pending.erase(pending.begin());
                }
                if(lane.atlas && bool(lane.readback)!=use_shared){if(encoder)check(encoder->request_output());continue;}
                if(lane_index && !dual){if(pending.empty())lane=Lane{};continue;}
                if(pending.size()>=ime_priority.pending_limit(scheduler_ms(),vf::pending_limit(options.mode))){if(encoder)check(encoder->request_output());continue;}
                const auto urgent=ime_priority.urgent();
                // WGC already paces new captures. An independent 60 Hz deadline
                // can defer a just-arrived capture until the following poll.
                // Keep lower background budgets and require change tracking so
                // this experiment cannot continuously republish static pixels.
                const bool capture_paced=use_shared && capture_changes && target_fps==60 &&
                    std::getenv("VIEWFLOW_SHM_CAPTURE_PACED") &&
                    std::string_view(std::getenv("VIEWFLOW_SHM_CAPTURE_PACED"))=="1";
                if(!capture_paced && Clock::now()<next_frame && urgent==submitted_urgent){++lane.skips[0];continue;}
                if((lane.readback && !lane.readback->available()) || (lane.d12 && !lane.d12->available())){++lane.skips[1];continue;}
                if(encoder){const auto ready=encoder->can_submit();check(ready);if(ready==S_FALSE){continue;}}
                if(lane_index && (!schedule.preferred || !lanes[0].atlas))continue;
                std::vector<std::shared_ptr<Source>> sources;
                {std::lock_guard lock(app.source_mutex);for(auto& [_,source]:app.sources)sources.push_back(source);}
                if(lane_index)std::erase_if(sources,[&](const auto& source){
                    return !schedule.belongs(source->id,schedule.preferred);
                });
                const auto selected=[&](std::uint64_t id,std::uint64_t owner){(void)owner;return schedule.belongs(id,schedule.preferred);};
                std::stable_sort(sources.begin(),sources.end(),[](const auto& a,const auto& b){return a->ime_popup<b->ime_popup;});
                std::map<std::uint64_t,vf::AtlasExtent> layout_extents;
                std::vector<vf::AtlasExtent> layout_sizes;
                for(const auto& source:sources){
                    std::lock_guard lock(source->mutex);if(!source->texture && !source->bands)continue;
                    const auto crop=source->resident.value_or(vf::PixelRect{0,0,source->frame_width,source->frame_height});
                    const vf::AtlasExtent extent{crop.width,crop.height,source->ime_popup};
                    layout_extents.emplace(source->id,extent);layout_sizes.push_back(extent);
                }
                const auto row_width=vf::atlas_row_width(layout_sizes,width,height,atlas_max_width,atlas_max_height);
                bool layout_changed=false;
                bool popup_band=false;unsigned body_height=192;
                const auto frame_begin=qpc100ns();std::int64_t capture_pts=0;
                std::map<std::uint64_t,std::pair<std::int64_t,std::uint64_t>> capture_timing;
                vf::Frame frame;
                if(activity_enabled){frame.activity_lane=lane_index;frame.activity_epoch=activity_epoch;
                    frame.activity_preferred=schedule.preferred;frame.activity_focus=schedule.focus;frame.activity_members=schedule.members;}
                std::vector<std::pair<HWND,std::uint64_t>> completed_moves;vf::FrameChangeTracker::Versions observed_versions,copied_versions;unsigned row_x=0,row_y=0,row_height=0,needed_width=use_shared?1u:192u,needed_height=use_shared?1u:192u;
                for(auto& source:sources) {
                    std::lock_guard lock(source->mutex);if(!source->texture && !source->bands)continue; // Keep the last frame and proxy while this capture recovers.
                    const auto w=source->frame_width,h=source->frame_height;
                    const auto crop=source->resident.value_or(vf::PixelRect{0,0,w,h});
                    const auto rw=crop.width,rh=crop.height;
                    const auto planned=layout_extents.find(source->id);
                    if(planned==layout_extents.end() || planned->second!=vf::AtlasExtent{rw,rh,source->ime_popup}){layout_changed=true;break;}
                    if(rw>atlas_max_width || rh>atlas_max_height)continue;
                    if(source->ime_popup && !popup_band){
                        body_height=needed_height;row_y=(body_height+63)&~63u;row_x=0;row_height=0;popup_band=true;
                    }
                    if(row_x+rw>row_width){row_y+=row_height;row_x=0;row_height=0;}
                    if(row_y+rh>atlas_max_height)continue;
                    DWORD window_pid{};const auto window_thread=GetWindowThreadProcessId(source->window,&window_pid);
                    if(!window_thread || window_pid!=source->pid)continue;
                    auto rect=source->fullscreen_snapshot?source->fullscreen_presentation:App::bounds(source->window);
                    if(source->shell_menu){rect.left+=source->shell_x;rect.top+=source->shell_y;rect.right=rect.left+w;rect.bottom=rect.top+h;}
                    if(rect.right<=rect.left || rect.bottom<=rect.top)continue;
                    const auto frame_title=title(source->window);
                    // Destruction can race the inventory interval and the Win32
                    // metadata reads. Do not publish an invalid rectangle/title.
                    DWORD checked_pid{};if(GetWindowThreadProcessId(source->window,&checked_pid)!=window_thread || checked_pid!=source->pid)continue;
                    GUITHREADINFO gui{};gui.cbSize=sizeof(gui);
                    const bool moving=GetGUIThreadInfo(window_thread,&gui) &&
                        (gui.flags&GUI_INMOVESIZE) && gui.hwndMoveSize==source->window;
                    if(moving && !source->in_move){
                        const auto start=observed_move_for(source->window);
                        source->move_origin=start && start->pid==source->pid?start->bounds:rect;
                        source->was_resized=false;
                    }
                    if(moving && (rect.right-rect.left!=source->move_origin.right-source->move_origin.left ||
                        rect.bottom-rect.top!=source->move_origin.bottom-source->move_origin.top))source->was_resized=true;
                    source->in_move=moving;
                    const auto observed_move=observed_move_for(source->window);
                    const bool known_move=observed_move && observed_move->pid==source->pid;
                    const auto& drag_origin=known_move?observed_move->bounds:source->move_origin;
                    const bool move_ended=known_move && observed_move->ended;
                    const bool native_drag=(moving || move_ended) &&
                        rect.right-rect.left==drag_origin.right-drag_origin.left &&
                        rect.bottom-rect.top==drag_origin.bottom-drag_origin.top &&
                        (rect.left!=drag_origin.left || rect.top!=drag_origin.top);
                    frame.tiles.push_back({source->id,source->owner,rect.left,rect.top,w,h,row_x,row_y,frame_title,vf::residency_capability|(native_drag && !source->ime_popup?(known_move?5u:1u):0u)|(source->ime_popup?2u:0u),
                        rect.right-rect.left==static_cast<int>(source->geometry.content_width) && rect.bottom-rect.top==static_cast<int>(source->geometry.content_height)?source->geometry_ack:0});
                    auto& body_tile=frame.tiles.back();body_tile.flags|=16u;
                    if(source->desktop_output_snapshot)body_tile.flags|=vf::windows_desktop_output_flag;
                    if(!source->shell_menu && !source->ime_popup && vf::native_popup(source->window))body_tile.flags|=vf::windows_popup_flag;
                    if(app.fusion.enabled() && source->shell_menu)body_tile.flags|=vf::windows_shell_flag;
                    if(!source->icon_sent && !source->icon.png.empty()) {
                        body_tile.flags|=vf::application_icon_flag;body_tile.app_id=source->icon.app_id;body_tile.icon_png=source->icon.png;
                    }
                    body_tile.body_x=body_tile.body_y=0;
                    body_tile.body_width=body_tile.logical_width=source->geometry.content_width;
                    body_tile.body_height=body_tile.logical_height=source->geometry.content_height;
                    body_tile.pixel_scale=1;
                    if(source->resident)vf::set_resident_rect(frame.tiles.back(),crop);
                    if(native_drag && known_move && !source->ime_popup){
                        frame.tiles.back().grab_x=observed_move->grab.x;
                        frame.tiles.back().grab_y=observed_move->grab.y;
                    }
                    if(move_ended && publish(source->id,source->owner))completed_moves.emplace_back(source->window,observed_move->serial);
                    if(rw && rh && publish(source->id,source->owner) && (lane_index || !selected(source->id,source->owner)))observed_versions[source->id]=source->capture_version;
                    row_x+=rw;row_height=std::max(row_height,rh);needed_width=std::max(needed_width,row_x);needed_height=std::max(needed_height,row_y+rh);
                }
                // A capture resize may race the layout snapshot. Retry before
                // publishing rather than omitting a tile from a narrow shelf.
                if(layout_changed)continue;
                if(weighted_single && !background_due)std::erase_if(frame.tiles,[&](const auto& tile){return !publish(tile.id,tile.owner);});
                if(frame.tiles.empty() && !atlas){next_frame=Clock::now()+std::chrono::milliseconds(16);continue;}
                const bool periodic_refresh=Clock::now()-last_submission>=std::chrono::seconds(1);
                if(capture_changes && !changes.needs_frame(frame.tiles,observed_versions,force_keyframe,periodic_refresh)){
                    ++unchanged_skips;++lane.skips[2];
                    // Allow the next 60 Hz capture after submission. Starting
                    // another timer here would add a second frame interval to
                    // the last update of a static scene.
                    if(encoder && !pending.empty() && Clock::now()-last_submission>=std::chrono::milliseconds(20))check(encoder->request_output());
                    continue;
                }
                // Reserve a separate popup band even while hidden: showing or
                // animating the candidate does not resize the body's encoder.
                if(!popup_band)body_height=needed_height;
                if(use_shared) {
                    // Raw BGRA has no encoder alignment or restart penalty.
                    // Exact extents also allow the existing single-surface
                    // path to bypass a redundant atlas clear and GPU copy.
                    // Segment boundaries and D3D12 placed footprints require
                    // 512-byte row alignment. Pad only the transport atlas;
                    // tile crops/geometry (including menus) remain exact.
                    if(d12_enabled && shared_mapping && shared_mapping->supports_segmented_dma())
                        std::tie(needed_width,needed_height)=capacity.select(needed_width,needed_height,scheduler_ms(),popup_band||ime_priority.active(scheduler_ms()),atlas_max_width,atlas_max_height,128,1);
                    else
                        std::tie(needed_width,needed_height)=capacity.select_shared(needed_width,needed_height,scheduler_ms(),popup_band||ime_priority.active(scheduler_ms()),atlas_max_width,atlas_max_height);
                }else {
                    needed_width=std::max(needed_width,2048u);
                    needed_height=std::max(needed_height,std::min(atlas_max_height,((body_height+63)&~63u)+512u));
                    std::tie(needed_width,needed_height)=capacity.select(needed_width,needed_height,scheduler_ms(),popup_band||ime_priority.active(scheduler_ms()),atlas_max_width,atlas_max_height);
                }
                if(needed_width!=width || needed_height!=height || !atlas) {
                    // Drain ownership before replacing a codec; no old metadata is
                    // ever attached to a frame from the new dimensions.
                    if(!pending.empty()){check(encoder->request_output());continue;}
                    width=needed_width;height=needed_height;
                    force_keyframe=true;last_raw_alpha.clear();last_encoded_alpha.clear();
                    if(!use_shared)opaque_encoded_alpha=vf::encode_windows_opaque_alpha(std::size_t(width)*height);
                    const auto restart_begin=Clock::now();
                    try {
                    if(use_shared && !shared_frames->fits(width,height)) {
                        std::fprintf(stderr,"reverse-media fallback=encoded reason=ivshmem-capacity width=%u height=%u\n",width,height);
                        for(auto& old:lanes)old=Lane{};shared_frames.reset();break;
                    }
                    if(use_shared){lane.readback=std::make_unique<vf::shm::Readback>(*shared_frames);lane.readback->latest_ready=std::getenv("VIEWFLOW_SHM_LATEST_READY") && std::string_view(std::getenv("VIEWFLOW_SHM_LATEST_READY"))=="1";lane.readback->measure=vf_diag::metrics();lane.readback->measure_gpu=vf_diag::metrics() && std::getenv("VIEWFLOW_SHM_GPU_TIMING");lane.readback->single_pending=std::getenv("VIEWFLOW_SHM_SINGLE_READBACK") && std::string_view(std::getenv("VIEWFLOW_SHM_SINGLE_READBACK"))=="1";}
                    else {
                        encoder=std::make_unique<vf::HardwareEncoder>();check(encoder->start(app.device.Get(),width,height,60,2));
                        alpha=std::make_unique<vf::AlphaPlane>();check(alpha->start(app.device.Get(),width,height));
                    }
                    atlas_view.Reset();atlas_target.Reset();atlas.Reset();
                    D3D11_TEXTURE2D_DESC desc{};desc.Width=width;desc.Height=height;desc.ArraySize=1;desc.MipLevels=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
                    check(app.device->CreateTexture2D(&desc,nullptr,&atlas));check(app.device->CreateShaderResourceView(atlas.Get(),nullptr,&atlas_view));check(app.device->CreateRenderTargetView(atlas.Get(),nullptr,&atlas_target));
                    }catch(const std::exception& error){
                        if(!lane_index)throw;
                        std::fprintf(stderr,"activity_priority fallback=single reason=%s\n",error.what());
                        lane=Lane{};dual=false;break;
                    }
                    std::fprintf(stderr,"reverse-codec-restart ms=%.3f\n",std::chrono::duration<double,std::milli>(Clock::now()-restart_begin).count());
                    std::fprintf(stderr,"reverse-atlas hardware=%s width=%u height=%u\n",use_shared?"ivshmem-bgra":"mf-hevc",width,height);
                }
                // Never retain WGC's borrowed surface. Owned GPU snapshots are
                // protected while queuing consumers; captured staging snapshots
                // instead carry a lease through readback completion and Unmap.
                std::shared_ptr<Source> direct_source;
                std::unique_lock<std::mutex> direct_lock;
                ID3D11Texture2D* color_surface=atlas.Get();
                ID3D11ShaderResourceView* alpha_surface=atlas_view.Get();
                if(direct_single_surface && frame.tiles.size()==1 && (lane_index || !selected(frame.tiles[0].id,frame.tiles[0].owner))) {
                    const auto& tile=frame.tiles.front();
                    if(vf::resident_rect(tile)==vf::PixelRect{0,0,tile.width,tile.height} && tile.atlas_x==0 && tile.atlas_y==0 && tile.width==width && tile.height==height) {
                        direct_source=app.source_for(tile.id);
                        if(direct_source) {
                            direct_lock=std::unique_lock<std::mutex>(direct_source->mutex);
                            if(((direct_source->texture && (direct_source->texture_view || (lane.readback && direct_source->staging))) || (lane.readback && direct_source->bands)) &&
                               direct_source->frame_width==width && direct_source->frame_height==height &&
                               bool(tile.flags&vf::windows_desktop_output_flag)==direct_source->desktop_output_snapshot) {
                                color_surface=direct_source->texture.Get();alpha_surface=direct_source->texture_view.Get();capture_pts=direct_source->pts;copied_versions[direct_source->id]=direct_source->capture_version;
                                if(vf_diag::metrics())capture_timing[direct_source->id]={direct_source->pts,direct_source->capture_version};
                            } else {direct_lock.unlock();direct_source.reset();}
                        }
                    }
                }
                std::uint64_t copied_pixels=0;
                if(!direct_source) {
                    const float clear[4]={0,0,0,0};app.context->ClearRenderTargetView(atlas_target.Get(),clear);
                    bool complete=true;
                    const auto copy_order=viewflow::activity::ordered_tiles(frame.tiles,preferred_window,schedule.focus);
                    for(const auto* ordered:copy_order) {
                        const auto& tile=*ordered;
                        if(!lane_index && selected(tile.id,tile.owner))continue;
                        auto source=app.source_for(tile.id);if(!source){complete=false;break;}
                        std::lock_guard lock(source->mutex);
                        // A WGC callback can replace the DD snapshot after the
                        // layout lock was released, even at identical extents.
                        // Retry instead of attaching desktop opacity to WGC pixels.
                        if((!source->texture && !source->bands) || source->frame_width!=tile.width || source->frame_height!=tile.height ||
                           bool(tile.flags&vf::windows_desktop_output_flag)!=source->desktop_output_snapshot){complete=false;break;}
                        const auto crop=vf::resident_rect(tile);
                        if(crop.width && crop.height){
                            D3D11_BOX box{crop.x,crop.y,0,crop.x+crop.width,crop.y+crop.height,1};
                            if(source->bands)vf::shm::BandedStaging::copy_region(app.context.Get(),*source->bands,atlas.Get(),tile.atlas_x,tile.atlas_y,box);
                            else app.context->CopySubresourceRegion(atlas.Get(),0,tile.atlas_x,tile.atlas_y,0,source->texture.Get(),0,&box);
                            copied_pixels+=std::uint64_t(crop.width)*crop.height;
                        }
                        capture_pts=source->pts;if(crop.width && crop.height){copied_versions[source->id]=source->capture_version;
                            if(vf_diag::metrics())capture_timing[source->id]={source->pts,source->capture_version};}
                    }
                    // A resize can race the metadata snapshot. Keep the last
                    // presented frame and retry with current geometry instead
                    // of sending a cleared, transparent tile for that window.
                    if(!complete)continue;
                }
                LARGE_INTEGER ticks{},frequency{};QueryPerformanceCounter(&ticks);QueryPerformanceFrequency(&frequency);
                const auto now=ticks.QuadPart/frequency.QuadPart*10000000+(ticks.QuadPart%frequency.QuadPart)*10000000/frequency.QuadPart;
                pts=std::max(pts+1,now);frame.pts=pts;frame.width=width;frame.height=height;
                if(lane.readback) {
                    // Metadata and the exact atlas are kept together until GPU completion.
                    const bool captured_staging=direct_source && bool(direct_source->staging);
                    // Snapshot the selected path while source ownership is locked.
                    // The capture callback can replace bands after adoption unlocks.
                    const bool captured_bands=direct_source && bool(direct_source->bands);
                    lane.readback->progressive=progressive_enabled && progressive_probe.payload_agreed();
                    bool d12_submitted=false,d12_busy=false;
                    if(d12_enabled && !progressive_enabled && !captured_bands && !captured_staging && lane.readback->idle()) {
                        if(!lane.d12_attempted) {
                            lane.d12_attempted=true;
                            try {
                                lane.d12=std::make_unique<vf::d12::Transport>(shared_frames,shared_mapping);
                                const auto initialized=lane.d12->initialize(app.device.Get(),app.context.Get());
                                std::fprintf(stderr,"reverse-d12 initialize lane=%u hr=0x%08lx reason=%s\n",lane_index,static_cast<unsigned long>(initialized),lane.d12->diagnostic());
                            }catch(const std::exception& error){std::fprintf(stderr,"reverse-d12 fallback=cpu-readback reason=%s\n",error.what());}
                        }
                        if(lane.d12 && !lane.d12->disabled()) {
                            static const bool source_pool_enabled=[] {const auto* v=std::getenv("VIEWFLOW_SHM_D12_SOURCE_POOL");return v && std::string_view(v)=="1";}();
                            if(source_pool_enabled && direct_source && !direct_source->desktop_output_snapshot &&
                               !direct_source->fullscreen_suppress && !direct_source->shared_source_attempted) {
                                direct_source->shared_source_attempted=true;
                                try {
                                    auto pool=std::make_unique<vf::d12::SharedCapture>();
                                    const auto hr=pool->initialize(app.device.Get(),app.context.Get(),lane.d12->device(),vf::d12::SharedCapture::Role::wgc_source);
                                    if(SUCCEEDED(hr)) {
                                        direct_source->shared_source_device=lane.d12->device();
                                        direct_source->shared_source_pool=std::move(pool);
                                    }
                                    std::fprintf(stderr,"reverse-d12 source-pool id=%llu enabled=%u hr=0x%08lx lazy=1\n",
                                        static_cast<unsigned long long>(direct_source->id),unsigned(SUCCEEDED(hr)),static_cast<unsigned long>(hr));
                                }catch(const std::bad_alloc&) {
                                    std::fprintf(stderr,"reverse-d12 source-pool allocation fallback id=%llu\n",static_cast<unsigned long long>(direct_source->id));
                                }
                            }
                            static const bool dd_source_pool_enabled=[] {const auto* v=std::getenv("VIEWFLOW_SHM_D12_DD_SOURCE_POOL");return v && std::string_view(v)=="1";}();
                            if(dd_source_pool_enabled && direct_source && direct_source->desktop_output_snapshot && direct_source->fullscreen_capture)
                                direct_source->fullscreen_capture->enable_shared(lane.d12->device());
                            // Cross-activity-lane devices and atlas/padding paths
                            // continue through the original bridge, without an
                            // invalid-adoption retry backoff.
                            const bool adopt=direct_source && direct_source->shared_source_snapshot &&
                                direct_source->shared_snapshot_device.Get()==lane.d12->device();
                            const auto result=adopt?lane.d12->enqueue_owned(direct_source->shared_source_snapshot,frame):lane.d12->enqueue(color_surface,frame);
                            d12_submitted=result==vf::d12::Transport::Enqueue::accepted;
                            if(d12_submitted && direct_source && direct_source->owned_dd_test && direct_source->desktop_output_snapshot)
                                vf_diag::trace("profile_dd_submit pts=%lld id=%llu capture=%lld capture_clock=dxgi-last-present width=%u height=%u shared_source=%u completed=0\n",pts,direct_source->id,direct_source->pts,width,height,unsigned(adopt));
                            d12_busy=result==vf::d12::Transport::Enqueue::busy;
                            if(result==vf::d12::Transport::Enqueue::fallback && lane.d12->disabled())
                                std::fprintf(stderr,"reverse-d12 fallback=cpu-readback hr=0x%08lx reason=%s\n",static_cast<unsigned long>(lane.d12->last_error()),lane.d12->diagnostic());
                        }
                    }
                    if(d12_busy)continue;
                    if(d12_submitted || (captured_bands ? lane.readback->adopt_bands(direct_source->bands,frame) : captured_staging ? lane.readback->adopt(direct_source->staging,frame) : lane.readback->enqueue(app.device.Get(),app.context.Get(),color_surface,frame))) {
                        if(d12_enabled && !d12_submitted)++lane.d12_cpu_frames;
                        if(d12_submitted && lane.d12->submitted==1)std::fprintf(stderr,"reverse-d12 selected=gpu-copy lane=%u width=%u height=%u codec=SHM1 banks=lazy\n",lane_index,width,height);
                        // The GPU copy owns the staging snapshot now. Release
                        // before shell bookkeeping can lock this same source.
                        if(direct_lock.owns_lock())direct_lock.unlock();
                        if(vf_diag::metrics())for(const auto& [id,timing]:capture_timing)
                            vf_diag::trace("profile_shared_capture pts=%lld id=%llu capture=%lld version=%llu enqueued=%lld width=%u height=%u direct=%u captured_staging=%u captured_bands=%u\n",pts,(unsigned long long)id,timing.first,(unsigned long long)timing.second,qpc100ns(),width,height,unsigned(bool(direct_source)),unsigned(captured_staging),unsigned(captured_bands));
                        for(const auto& tile:frame.tiles)if(tile.flags&vf::windows_shell_flag)if(auto source=app.source_for(tile.id)){
                            std::lock_guard lock(source->mutex);if(!source->first_submitted){source->first_submitted=true;
                                std::fprintf(stderr,"reverse-shell-first-submit id=%llu discovery-us=%lld\n",source->id,std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-source->discovered_at).count());
                            }
                        }
                        changes.submitted(frame.tiles,std::move(copied_versions));last_submission=Clock::now();submitted_urgent=urgent;
                        next_frame=std::max(next_frame+std::chrono::nanoseconds(1'000'000'000/target_fps),Clock::now());
                        force_keyframe=false;
                        for(const auto& [window,serial]:completed_moves){std::lock_guard lock(move_mutex);auto found=move_origins.find(window);if(found!=move_origins.end() && found->second.ended && found->second.serial==serial)move_origins.erase(found);}
                        if(weighted_single && background_due)single_budget.submitted_background(viewflow::activity::now_us());
                        // The source lock is released and lane bookkeeping is
                        // committed. Check once without waiting; a not-ready
                        // GPU query retains the normal outer-loop polling.
                        if(immediate_shared_poll)poll_shared(lane);
                    }
                    continue;
                }
                const auto submit_begin=qpc100ns();const auto result=encoder->submit(color_surface,pts,force_keyframe);check(result);const auto submit_end=qpc100ns();
                if(result==S_FALSE){continue;}
                next_frame=std::max(next_frame+std::chrono::nanoseconds(1'000'000'000/target_fps),Clock::now());
                force_keyframe=false;
                // The atlas was cleared to alpha zero. Fewer copied pixels than
                // its area proves transparent padding remains, so skip the GPU
                // all-opaque query and queue the exact full-plane readback now.
                const auto alpha_begin=qpc100ns();const auto queued=alpha->enqueue(alpha_surface,pts,!direct_source && copied_pixels<std::uint64_t(width)*height);check(queued);
                if(queued!=S_OK)throw std::runtime_error("alpha queue ownership mismatch");const auto alpha_end=qpc100ns();
                if(direct_lock.owns_lock())direct_lock.unlock(); // Both GPU consumers have queued ownership.
                changes.submitted(frame.tiles,std::move(copied_versions));last_submission=Clock::now();submitted_urgent=urgent;
                for(const auto& tile:frame.tiles)if(tile.flags&2)if(auto source=app.source_for(tile.id)){
                    std::lock_guard lock(source->mutex);if(!source->first_submitted){source->first_submitted=true;
                        std::fprintf(stderr,"reverse-ime-first-submit id=%llu discovery-us=%lld pending=%zu priority=%u\n",source->id,std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-source->discovered_at).count(),pending.size(),unsigned(ime_priority.active(scheduler_ms())));
                    }
                }
                for(const auto& [window,serial]:completed_moves){
                    std::lock_guard lock(move_mutex);
                    auto found=move_origins.find(window);
                    if(found!=move_origins.end() && found->second.ended && found->second.serial==serial)move_origins.erase(found);
                }
                if(vf_diag::metrics())vf_diag::trace("profile_capture_changes pts=%lld enabled=%u unchanged_skips=%llu periodic=%u\n",pts,unsigned(capture_changes),static_cast<unsigned long long>(unchanged_skips),unsigned(periodic_refresh));
                if(direct_lock.owns_lock())direct_lock.unlock();
                if(vf_diag::metrics())vf_diag::trace("profile_direct pts=%lld used=%u tiles=%zu\n",pts,unsigned(bool(direct_source)),frame.tiles.size());
                if(vf_diag::metrics())vf_diag::trace("profile_submit pts=%lld capture=%lld begin=%lld submit_begin=%lld submit_end=%lld alpha_begin=%lld alpha_end=%lld alpha_pack_end=%lld pending=%zu width=%u height=%u\n",pts,capture_pts,frame_begin,submit_begin,submit_end,alpha_begin,alpha_end,qpc100ns(),pending.size(),width,height);
                pending.emplace(pts,std::move(frame));
                if(weighted_single && background_due)single_budget.submitted_background(viewflow::activity::now_us());
                }
                loop_sample(0,loop_begin);
                const auto sleep_begin=vf_diag::metrics()?Clock::now():Clock::time_point{};
                bool readback_pending=false;
                for(const auto& lane:lanes)if((lane.readback && !lane.readback->idle()) || (lane.d12 && lane.d12->active()))readback_pending=true;
                if(readback_pending || app.capture_wake.wait()==WAIT_FAILED)readback_wait.pause(readback_pending);
                loop_sample(1,sleep_begin);
                if(vf_diag::metrics() && Clock::now()-loop_report>=std::chrono::seconds(5)) {
                    for(unsigned i=0;i<2;++i){auto& l=lanes[i];vf_diag::trace("profile_send_skips lane=%u at=%lld timer=%llu readback=%llu unchanged=%llu\n",i,qpc100ns(),(unsigned long long)l.skips[0],(unsigned long long)l.skips[1],(unsigned long long)l.skips[2]);l.skips={};}
                    for(unsigned i=0;i<2;++i)if(d12_enabled){const auto* d=lanes[i].d12.get();vf_diag::trace("profile_d12 lane=%u submitted=%llu published=%llu fallbacks=%llu busy=%llu cpu_frames=%llu active=%u disabled=%u\n",i,(unsigned long long)(d?d->submitted:0),(unsigned long long)(d?d->published:0),(unsigned long long)(d?d->fallbacks:0),(unsigned long long)(d?d->busy:0),(unsigned long long)lanes[i].d12_cpu_frames,unsigned(d && d->active()),unsigned(d && d->disabled()));}
                    const char* names[]={"work","sleep","inventory"};
                    for(unsigned i=0;i<3;++i)if(!loop_samples[i].empty()) {
                        auto& values=loop_samples[i];std::sort(values.begin(),values.end());
                        vf_diag::trace("profile_loop stage=%s n=%zu p50_ms=%.3f p95_ms=%.3f max_ms=%.3f\n",names[i],values.size(),values[values.size()/2],values[values.size()*95/100],values.back());values.clear();
                    }
                    loop_report=Clock::now();
                }
            }
        }catch(...){app.running=false;CancelSynchronousIo(input.native_handle());input.join();throw;}
        input.join();return 0;
    }catch(const std::exception& error){std::fprintf(stderr,"reverse source: %s\n",error.what());return 1;}
}

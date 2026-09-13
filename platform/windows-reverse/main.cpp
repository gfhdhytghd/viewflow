#include "performance_mode.hpp"
#include "diagnostics.hpp"
#include "frame_changes.hpp"
#include "hardware_encoder.hpp"
#include "alpha_plane.hpp"
#include "touchpad.hpp"
#include "window_inventory.hpp"
#include "../reverse-common/wire.hpp"
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
        if(!hook)std::fprintf(stderr,"reverse native move observer unavailable error=%lu\n",GetLastError());
        while(GetMessageW(&message,nullptr,0,0)>0){TranslateMessage(&message);DispatchMessageW(&message);}
        if(hook)UnhookWinEvent(hook);
        if(desktop)CloseDesktop(desktop);
    }){}
    ~MoveObserver(){
        DWORD id{};while(!(id=thread_id.load(std::memory_order_acquire)))std::this_thread::yield();
        PostThreadMessageW(id,WM_QUIT,0,0);worker.join();
    }
};
struct Source {
    HWND window{};std::uint64_t id{},owner{};DWORD pid{};
    viewflow::windows_capture::WindowCapture capture;
    std::mutex mutex;
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11ShaderResourceView> texture_view;
    viewflow::windows_capture::CaptureGeometry geometry,requested_geometry;
    bool ime_popup{};
    std::uint64_t geometry_ack{};
    std::uint64_t capture_version{};std::int64_t pts{};bool closed{},in_move{},was_resized{};RECT move_origin{};
    Clock::time_point retry_at{},geometry_seen_at{};
    ~Source(){capture.stop();}
};
struct App {
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
    std::map<HWND,std::shared_ptr<Source>> sources;
    std::mutex source_mutex;
    std::atomic<bool> running{true};
    std::uint64_t next_id{1};int left{-6144},top{-780},right{0},bottom{2676};
    std::map<unsigned,INPUT> held_keys,held_buttons;
    std::uint64_t last_input{},touchpad_target{};
    vf::TouchpadAssembler touchpad_frames;
    vf::TouchpadInjector touchpad;
    bool inventory_logged{};
    ~App() {
        // Keep the source map's strong references while stopping callbacks.
        // Otherwise a callback can release the last Source reference after
        // map destruction and run ~Source/stop recursively on the WGC thread.
        for(auto& [_,source]:sources)source->capture.stop();
    }
    void release() {
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
        if(event.kind==vf::InputKind::release){release();return;}
        if(event.kind==vf::InputKind::proxy_drag || event.kind==vf::InputKind::proxy_drag_anchor)throw std::runtime_error("local proxy control arrived on Windows input");
        const bool touchpad_input=event.kind==vf::InputKind::touchpad_contact || event.kind==vf::InputKind::touchpad_frame;
        if(event.kind==vf::InputKind::touchpad_frame && event.c==0){
            touchpad_frames.reset();if(touchpad_target==event.id){touchpad.release();touchpad_target=0;}return;
        }
        auto source=source_for(event.id);if(!source){if(touchpad_input){touchpad_frames.reset();if(touchpad_target==event.id){touchpad.release();touchpad_target=0;}}return;}
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
            const auto x=std::int64_t(event.c==1?0:rect.left)+event.a,y=std::int64_t(event.c==1?0:rect.top)+event.b;
            if(x>=LONG_MIN && x<=LONG_MAX && y>=LONG_MIN && y<=LONG_MAX)SetCursorPos(static_cast<int>(x),static_cast<int>(y));
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
            if(SendInput(1,&native,sizeof(native))==1){if(event.b)held_buttons[event.a]=native;else held_buttons.erase(event.a);}
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
            if(SendInput(1,&native,sizeof(native))==1){if(event.b)held_keys[code]=native;else held_keys.erase(code);}
            break;
        }
        case vf::InputKind::focus:focus(source->window);break;
        case vf::InputKind::geometry: {
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
                vf::Reader length{{prefix,4}};auto size=length.u32();if(size!=40)throw std::runtime_error("reverse input record size");
                std::vector<std::uint8_t> bytes(size);if(fread(bytes.data(),1,size,stdin)!=size)break;
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
        if(!IsWindowVisible(window) || IsIconic(window))return false;
        DWORD pid{};GetWindowThreadProcessId(window,&pid);if(!pid || pid==GetCurrentProcessId())return false;
        const auto selected=std::getenv("VIEWFLOW_PROFILE_SOURCE_PID");if(vf_diag::enabled() && selected && pid!=std::strtoul(selected,nullptr,10))return false;
        wchar_t cls[256]{};GetClassNameW(window,cls,256);
        if(wcsncmp(cls,L"Viewflow",8)==0 || wcscmp(cls,L"Progman")==0 || wcscmp(cls,L"WorkerW")==0 || wcscmp(cls,L"Shell_TrayWnd")==0 || wcscmp(cls,L"Shell_SecondaryTrayWnd")==0)return false;
        DWORD cloaked{};DwmGetWindowAttribute(window,DWMWA_CLOAKED,&cloaked,sizeof(cloaked));if(cloaked)return false;
        const auto rect=bounds(window);
        // Warm a narrow resident strip so an approaching window keeps its WGC
        // texture and proxy identity before the pointer crosses the shared edge.
        constexpr int resident=256;
        if(auto move=observed_move_for(window);move && move->pid==pid &&
            (!move->ended || sources.contains(window)))return true;
        return rect.right>left-resident && rect.left<right+resident && rect.bottom>top-resident && rect.top<bottom+resident && rect.right>rect.left && rect.bottom>rect.top;
    }
    void start_capture(const std::shared_ptr<Source>& source) {
        // Stop outside source_mutex and the callback mutex: stop joins callbacks.
        source->capture.stop();
        {std::lock_guard lock(source->mutex);source->closed=false;source->retry_at=Clock::now()+std::chrono::milliseconds(500);}
            viewflow::windows_capture::FrameCallbacks callbacks;
            callbacks.on_geometry=[weak=std::weak_ptr<Source>(source)](const viewflow::windows_capture::CaptureGeometry& geometry){
                if(auto source=weak.lock()){
                    std::lock_guard lock(source->mutex);
                    if(source->requested_geometry.content_width!=geometry.content_width || source->requested_geometry.content_height!=geometry.content_height)source->geometry_seen_at=Clock::now();
                    source->requested_geometry=geometry;
                    if(vf_diag::enabled())std::fprintf(stderr,"profile_geometry id=%llu at=%lld epoch=%llu width=%u height=%u\n",static_cast<unsigned long long>(source->id),qpc100ns(),static_cast<unsigned long long>(geometry.epoch),geometry.content_width,geometry.content_height);
                }
            };
            callbacks.on_frame=[this,weak=std::weak_ptr<Source>(source)](const viewflow::windows_capture::CapturedFrame& frame) {
                auto source=weak.lock();if(!source)return;
                std::lock_guard lock(source->mutex);
                D3D11_TEXTURE2D_DESC desc{};frame.surface->GetDesc(&desc);
                if(!source->texture || source->geometry.content_width!=frame.geometry.content_width || source->geometry.content_height!=frame.geometry.content_height) {
                    desc.Width=frame.geometry.content_width;desc.Height=frame.geometry.content_height;
                    desc.MipLevels=1;desc.ArraySize=1;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;desc.MiscFlags=0;desc.Usage=D3D11_USAGE_DEFAULT;desc.CPUAccessFlags=0;
                    ComPtr<ID3D11Texture2D> replacement;
                    check(device->CreateTexture2D(&desc,nullptr,&replacement));
                    ComPtr<ID3D11ShaderResourceView> replacement_view;
                    check(device->CreateShaderResourceView(replacement.Get(),nullptr,&replacement_view));
                    source->texture=std::move(replacement);
                    source->texture_view=std::move(replacement_view);
                }
                D3D11_BOX box{0,0,0,frame.geometry.content_width,frame.geometry.content_height,1};
                context->CopySubresourceRegion(source->texture.Get(),0,0,0,0,frame.surface,0,&box);
                source->geometry=frame.geometry;source->pts=frame.system_relative_time_100ns;++source->capture_version;
                if(vf_diag::enabled())std::fprintf(stderr,"profile_capture id=%llu capture=%lld copied=%lld width=%u height=%u\n",source->id,source->pts,qpc100ns(),frame.geometry.content_width,frame.geometry.content_height);
            };
            callbacks.on_terminal=[weak=std::weak_ptr<Source>(source)](auto failure,std::uint32_t hr){
                if(auto source=weak.lock()){std::lock_guard lock(source->mutex);source->closed=true;std::fprintf(stderr,"reverse-capture-terminal id=%llu reason=%u hr=%08x\n",static_cast<unsigned long long>(source->id),static_cast<unsigned>(failure),hr);}
            };
            const auto result=source->capture.start(source->window,{8192,8192,vf::max_pixels},std::move(callbacks),device.Get());
            if(!result){std::lock_guard lock(source->mutex);source->closed=true;std::fprintf(stderr,"reverse-capture-start hwnd=%p hr=%08x retry=true\n",source->window,result.native_hresult);}
    }
    void inventory() {
        const auto found=vf::capture_window_inventory();
        if(!inventory_logged){std::fprintf(stderr,"reverse-inventory windows=%zu viewport=%d,%d,%d,%d\n",found.size(),left,top,right,bottom);inventory_logged=true;}
        std::map<HWND,bool> eligible;
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
        for(auto& source:removed){source->capture.stop();std::fprintf(stderr,"reverse-window-removed id=%llu\n",static_cast<unsigned long long>(source->id));}
        for(const auto [window,ime]:eligible) {
            std::shared_ptr<Source> existing;
            {std::lock_guard lock(source_mutex);if(auto it=sources.find(window);it!=sources.end())existing=it->second;}
            if(existing) {
                bool retry,resize_pending;
                {
                    std::lock_guard lock(existing->mutex);const auto now=Clock::now();
                    resize_pending=existing->texture && existing->requested_geometry.content_width &&
                        (existing->geometry.content_width!=existing->requested_geometry.content_width || existing->geometry.content_height!=existing->requested_geometry.content_height) &&
                        now-existing->geometry_seen_at>=std::chrono::milliseconds(500);
                    retry=(existing->closed || resize_pending) && now>=existing->retry_at;
                }
                // A one-shot resize may produce only the discarded transition
                // frame. Restart this capture if no correctly sized frame follows;
                // retain its last texture/proxy while WGC acquires current pixels.
                if(retry){std::fprintf(stderr,"reverse-capture-retry id=%llu hwnd=%p resize_pending=%u\n",static_cast<unsigned long long>(existing->id),window,unsigned(resize_pending));start_capture(existing);}
                continue;
            }
            auto source=std::make_shared<Source>();source->window=window;source->id=next_id++;GetWindowThreadProcessId(window,&source->pid);
            source->ime_popup=ime;
            start_capture(source);
            {std::lock_guard lock(source_mutex);sources.emplace(window,source);}
            std::fprintf(stderr,"reverse-window-added id=%llu hwnd=%p ime_popup=%u\n",static_cast<unsigned long long>(source->id),window,source->ime_popup);
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
    if(vf_diag::enabled())std::fprintf(stderr,"profile_output pts=%lld pack_begin=%lld pack_end=%lld write_end=%lld color=%zu alpha=%zu bytes=%zu\n",frame.pts,pack_begin,pack_end,qpc100ns(),frame.color.size(),frame.alpha.size(),bytes.size());
}
std::string title(HWND window) {
    wchar_t text[2048]{};const auto count=GetWindowTextW(window,text,2048);if(count<=0)return "Windows";
    const auto size=WideCharToMultiByte(CP_UTF8,0,text,count,nullptr,0,nullptr,nullptr);
    std::string result(size,0);WideCharToMultiByte(CP_UTF8,0,text,count,result.data(),size,nullptr,nullptr);
    if(result.size()>4096)result.resize(4096);return result;
}
}
int main(int argc,char** argv) {
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
        D3D_FEATURE_LEVEL level{};
        check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT|D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
            nullptr,0,D3D11_SDK_VERSION,&app.device,&level,&app.context));
        ComPtr<ID3D11Multithread> mt;check(app.device.As(&mt));mt->SetMultithreadProtected(TRUE);
        std::thread input([&]{app.input_loop();});
        std::unique_ptr<vf::HardwareEncoder> encoder;std::unique_ptr<vf::AlphaPlane> alpha;
        ComPtr<ID3D11Texture2D> atlas;ComPtr<ID3D11ShaderResourceView> atlas_view;ComPtr<ID3D11RenderTargetView> atlas_target;
        wchar_t direct_value[8]{};
        const bool direct_single_surface=GetEnvironmentVariableW(L"VIEWFLOW_REVERSE_DIRECT_SINGLE_SURFACE",direct_value,8)!=1 || direct_value[0]!=L'0';
        std::fprintf(stderr,"reverse_direct_single_surface enabled=%u\n",unsigned(direct_single_surface));
        wchar_t changes_value[8]{};
        const bool capture_changes=GetEnvironmentVariableW(L"VIEWFLOW_REVERSE_CAPTURE_CHANGES",changes_value,8)!=1 || changes_value[0]!=L'0';
        std::fprintf(stderr,"reverse_capture_changes enabled=%u\n",unsigned(capture_changes));
        std::optional<Clock::time_point> unchanged_since;
        vf::FrameChangeTracker changes;std::uint64_t unchanged_skips=0;
        Clock::time_point last_submission{};
        bool force_keyframe=true;
        std::vector<std::uint8_t> raw_alpha,last_raw_alpha,last_encoded_alpha,opaque_encoded_alpha;
        unsigned width=0,height=0;std::map<std::int64_t,vf::Frame> pending;
        auto inventory_at=Clock::now();auto next_frame=Clock::now();std::int64_t pts=0;
        try {
            while(app.running) {
                if(!options.mode_file.empty() && Clock::now()>=mode_check_at){
                    mode_check_at=Clock::now()+std::chrono::milliseconds(250);
                    if(auto mode=vf::read_mode(options.mode_file);mode && *mode!=options.mode){
                        options.mode=*mode;
                        std::fprintf(stderr,"reverse_performance mode=%s max_pending=%u\n",vf::mode_name(options.mode),vf::pending_limit(options.mode));
                    }
                }
                if(Clock::now()>=inventory_at){app.inventory();inventory_at=Clock::now()+std::chrono::milliseconds(native_moves_pending()?8:50);}
                if(encoder) {
                    std::vector<vf::EncodedFrame> encoded;check(encoder->poll(encoded));
                    for(auto& packet:encoded) {
                        auto found=pending.find(packet.timestamp);if(found==pending.end())continue;
                        found->second.color=std::move(packet.bytes);found->second.keyframe=packet.keyframe;
                        if(vf_diag::enabled())std::fprintf(stderr,"profile_color_ready pts=%lld at=%lld\n",packet.timestamp,qpc100ns());
                    }
                }
                if(alpha){
                    for(;;){
                        std::int64_t tag{};bool opaque=false;const auto collect_begin=qpc100ns();
                        const auto result=alpha->poll(tag,raw_alpha,&opaque);check(result);if(result==S_FALSE)break;
                        const auto collect_end=qpc100ns();
                        auto found=pending.find(tag);if(found==pending.end())throw std::runtime_error("alpha metadata missing");
                        if(!opaque && raw_alpha!=last_raw_alpha){last_encoded_alpha=vf::encode_alpha(raw_alpha);last_raw_alpha.swap(raw_alpha);}
                        found->second.alpha=opaque?opaque_encoded_alpha:last_encoded_alpha;
                        if(vf_diag::enabled())std::fprintf(stderr,"profile_alpha_summary pts=%lld opaque=%u bytes=%zu\n",tag,unsigned(opaque),raw_alpha.size());
                        if(vf_diag::enabled())std::fprintf(stderr,"profile_alpha_ready pts=%lld begin=%lld copied=%lld packed=%lld\n",tag,collect_begin,collect_end,qpc100ns());
                    }
                }
                while(!pending.empty() && !pending.begin()->second.color.empty() && !pending.begin()->second.alpha.empty()){
                    write_frame(pending.begin()->second);pending.erase(pending.begin());
                }
                if(pending.size()>=vf::pending_limit(options.mode)){if(encoder)check(encoder->request_output());std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
                if(Clock::now()<next_frame){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
                if(encoder){const auto ready=encoder->can_submit();check(ready);if(ready==S_FALSE){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}}
                std::vector<std::shared_ptr<Source>> sources;
                {std::lock_guard lock(app.source_mutex);for(auto& [_,source]:app.sources)sources.push_back(source);}
                const auto frame_begin=qpc100ns();std::int64_t capture_pts=0;
                vf::Frame frame;std::vector<std::pair<HWND,std::uint64_t>> completed_moves;vf::FrameChangeTracker::Versions observed_versions,copied_versions;unsigned row_x=0,row_y=0,row_height=0,needed_width=192,needed_height=192;
                for(auto& source:sources) {
                    std::lock_guard lock(source->mutex);if(!source->texture)continue; // Keep the last frame and proxy while this capture recovers.
                    const auto w=source->geometry.content_width,h=source->geometry.content_height;
                    if(w>8192 || h>4096)continue;
                    if(row_x+w>8192){row_y+=row_height;row_x=0;row_height=0;}
                    if(row_y+h>4096)continue;
                    DWORD window_pid{};const auto window_thread=GetWindowThreadProcessId(source->window,&window_pid);
                    if(!window_thread || window_pid!=source->pid)continue;
                    const auto rect=App::bounds(source->window);
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
                    frame.tiles.push_back({source->id,source->owner,rect.left,rect.top,w,h,row_x,row_y,frame_title,(native_drag && !source->ime_popup?(known_move?5u:1u):0u)|(source->ime_popup?2u:0u),
                        rect.right-rect.left==static_cast<int>(w) && rect.bottom-rect.top==static_cast<int>(h)?source->geometry_ack:0});
                    if(native_drag && known_move && !source->ime_popup){
                        frame.tiles.back().grab_x=observed_move->grab.x;
                        frame.tiles.back().grab_y=observed_move->grab.y;
                    }
                    if(move_ended)completed_moves.emplace_back(source->window,observed_move->serial);
                    observed_versions[source->id]=source->capture_version;
                    row_x+=w;row_height=std::max(row_height,h);needed_width=std::max(needed_width,row_x);needed_height=std::max(needed_height,row_y+h);
                }
                if(frame.tiles.empty() && !encoder){next_frame=Clock::now()+std::chrono::milliseconds(16);continue;}
                const bool periodic_refresh=Clock::now()-last_submission>=std::chrono::seconds(1);
                if(capture_changes && !changes.needs_frame(frame.tiles,observed_versions,force_keyframe,periodic_refresh)){
                    ++unchanged_skips;if(!unchanged_since)unchanged_since=Clock::now();
                    // Let the next 60 Hz capture arrive before draining a live
                    // pipeline. A static final update still completes locally.
                    if(encoder && !pending.empty() && Clock::now()-*unchanged_since>=std::chrono::milliseconds(20))check(encoder->request_output());
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;
                }
                unchanged_since.reset();
                needed_width=(needed_width+63)&~63u;needed_height=(needed_height+63)&~63u;
                if(needed_width>width || needed_height>height || !encoder) {
                    // Drain ownership before replacing a codec; no old metadata is
                    // ever attached to a frame from the new dimensions.
                    if(!pending.empty()){check(encoder->request_output());continue;}
                    width=std::max(width,needed_width);height=std::max(height,needed_height);
                    force_keyframe=true;last_raw_alpha.clear();last_encoded_alpha.clear();
                    {std::vector<std::uint8_t> pixels(std::size_t(width)*height,255);opaque_encoded_alpha=vf::encode_alpha(pixels);}
                    encoder=std::make_unique<vf::HardwareEncoder>();check(encoder->start(app.device.Get(),width,height,60,2));
                    alpha=std::make_unique<vf::AlphaPlane>();check(alpha->start(app.device.Get(),width,height));
                    atlas_view.Reset();atlas_target.Reset();atlas.Reset();
                    D3D11_TEXTURE2D_DESC desc{};desc.Width=width;desc.Height=height;desc.ArraySize=1;desc.MipLevels=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
                    check(app.device->CreateTexture2D(&desc,nullptr,&atlas));check(app.device->CreateShaderResourceView(atlas.Get(),nullptr,&atlas_view));check(app.device->CreateRenderTargetView(atlas.Get(),nullptr,&atlas_target));
                    std::fprintf(stderr,"reverse-atlas hardware=mf-hevc width=%u height=%u\n",width,height);
                }
                // WGC frames are still copied during their callback. This path
                // uses our own texture and holds its producer mutex until both
                // the video conversion and alpha reads are queued on the same
                // immediate context, before the next capture may overwrite it.
                std::shared_ptr<Source> direct_source;
                std::unique_lock<std::mutex> direct_lock;
                ID3D11Texture2D* color_surface=atlas.Get();
                ID3D11ShaderResourceView* alpha_surface=atlas_view.Get();
                if(direct_single_surface && frame.tiles.size()==1) {
                    const auto& tile=frame.tiles.front();
                    if(tile.atlas_x==0 && tile.atlas_y==0 && tile.width==width && tile.height==height) {
                        direct_source=app.source_for(tile.id);
                        if(direct_source) {
                            direct_lock=std::unique_lock<std::mutex>(direct_source->mutex);
                            if(direct_source->texture && direct_source->texture_view &&
                               direct_source->geometry.content_width==width && direct_source->geometry.content_height==height) {
                                color_surface=direct_source->texture.Get();alpha_surface=direct_source->texture_view.Get();capture_pts=direct_source->pts;copied_versions[direct_source->id]=direct_source->capture_version;
                            } else {direct_lock.unlock();direct_source.reset();}
                        }
                    }
                }
                if(!direct_source) {
                    const float clear[4]={0,0,0,0};app.context->ClearRenderTargetView(atlas_target.Get(),clear);
                    bool complete=true;
                    for(auto& tile:frame.tiles) {
                        auto source=app.source_for(tile.id);if(!source){complete=false;break;}
                        std::lock_guard lock(source->mutex);
                        if(!source->texture || source->geometry.content_width!=tile.width || source->geometry.content_height!=tile.height){complete=false;break;}
                        app.context->CopySubresourceRegion(atlas.Get(),0,tile.atlas_x,tile.atlas_y,0,source->texture.Get(),0,nullptr);capture_pts=source->pts;copied_versions[source->id]=source->capture_version;
                    }
                    // A resize can race the metadata snapshot. Keep the last
                    // presented frame and retry with current geometry instead
                    // of sending a cleared, transparent tile for that window.
                    if(!complete)continue;
                }
                LARGE_INTEGER ticks{},frequency{};QueryPerformanceCounter(&ticks);QueryPerformanceFrequency(&frequency);
                const auto now=ticks.QuadPart/frequency.QuadPart*10000000+(ticks.QuadPart%frequency.QuadPart)*10000000/frequency.QuadPart;
                pts=std::max(pts+1,now);frame.pts=pts;frame.width=width;frame.height=height;
                const auto submit_begin=qpc100ns();const auto result=encoder->submit(color_surface,pts,force_keyframe);check(result);const auto submit_end=qpc100ns();
                if(result==S_FALSE){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
                next_frame=std::max(next_frame+std::chrono::nanoseconds(1'000'000'000/60),Clock::now());
                force_keyframe=false;
                const auto alpha_begin=qpc100ns();const auto queued=alpha->enqueue(alpha_surface,pts);check(queued);
                if(queued!=S_OK)throw std::runtime_error("alpha queue ownership mismatch");const auto alpha_end=qpc100ns();
                changes.submitted(frame.tiles,std::move(copied_versions));last_submission=Clock::now();
                for(const auto& [window,serial]:completed_moves){
                    std::lock_guard lock(move_mutex);
                    auto found=move_origins.find(window);
                    if(found!=move_origins.end() && found->second.ended && found->second.serial==serial)move_origins.erase(found);
                }
                if(vf_diag::enabled())std::fprintf(stderr,"profile_capture_changes pts=%lld enabled=%u unchanged_skips=%llu periodic=%u\n",pts,unsigned(capture_changes),static_cast<unsigned long long>(unchanged_skips),unsigned(periodic_refresh));
                if(direct_lock.owns_lock())direct_lock.unlock();
                if(vf_diag::enabled())std::fprintf(stderr,"profile_direct pts=%lld used=%u tiles=%zu\n",pts,unsigned(bool(direct_source)),frame.tiles.size());
                if(vf_diag::enabled())std::fprintf(stderr,"profile_submit pts=%lld capture=%lld begin=%lld submit_begin=%lld submit_end=%lld alpha_begin=%lld alpha_end=%lld alpha_pack_end=%lld pending=%zu width=%u height=%u\n",pts,capture_pts,frame_begin,submit_begin,submit_end,alpha_begin,alpha_end,qpc100ns(),pending.size(),width,height);
                pending.emplace(pts,std::move(frame));
            }
        }catch(...){app.running=false;CancelSynchronousIo(input.native_handle());input.join();throw;}
        input.join();return 0;
    }catch(const std::exception& error){std::fprintf(stderr,"reverse source: %s\n",error.what());return 1;}
}

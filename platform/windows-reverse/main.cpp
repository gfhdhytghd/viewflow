#include "hardware_encoder.hpp"
#include "alpha_plane.hpp"
#include "touchpad.hpp"
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
#include <cstring>
#include <map>
#include <mutex>
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
struct Source {
    HWND window{};std::uint64_t id{},owner{};DWORD pid{};
    viewflow::windows_capture::WindowCapture capture;
    std::mutex mutex;
    ComPtr<ID3D11Texture2D> texture;
    viewflow::windows_capture::CaptureGeometry geometry;
    std::uint64_t geometry_ack{};
    std::int64_t pts{};bool dirty{},closed{},in_move{},was_resized{};RECT move_origin{};
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
        if(event.kind==vf::InputKind::proxy_drag)throw std::runtime_error("local proxy control arrived on Windows input");
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
            if(event.b)focus(source->window);
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
    bool candidate(HWND window) {
        if(!IsWindowVisible(window) || IsIconic(window))return false;
        DWORD pid{};GetWindowThreadProcessId(window,&pid);if(!pid || pid==GetCurrentProcessId())return false;
        wchar_t cls[256]{};GetClassNameW(window,cls,256);
        if(wcsncmp(cls,L"Viewflow",8)==0 || wcscmp(cls,L"Progman")==0 || wcscmp(cls,L"WorkerW")==0 || wcscmp(cls,L"Shell_TrayWnd")==0 || wcscmp(cls,L"Shell_SecondaryTrayWnd")==0)return false;
        DWORD cloaked{};DwmGetWindowAttribute(window,DWMWA_CLOAKED,&cloaked,sizeof(cloaked));if(cloaked)return false;
        const auto rect=bounds(window);
        return rect.right>left && rect.left<right && rect.bottom>top && rect.top<bottom && rect.right>rect.left && rect.bottom>rect.top;
    }
    void inventory() {
        std::vector<HWND> found;
        EnumWindows([](HWND w,LPARAM p)->BOOL {auto* out=reinterpret_cast<std::vector<HWND>*>(p);out->push_back(w);return TRUE;},reinterpret_cast<LPARAM>(&found));
        if(!inventory_logged){std::fprintf(stderr,"reverse-inventory windows=%zu viewport=%d,%d,%d,%d\n",found.size(),left,top,right,bottom);inventory_logged=true;}
        std::set<HWND> eligible;
        for(auto window:found)if(candidate(window) && eligible.size()<16)eligible.insert(window);
        std::vector<std::shared_ptr<Source>> removed;
        {
            std::lock_guard lock(source_mutex);
            for(auto it=sources.begin();it!=sources.end();) {
                if(!eligible.contains(it->first)){removed.push_back(it->second);it=sources.erase(it);}else ++it;
            }
        }
        for(auto& source:removed){source->capture.stop();std::fprintf(stderr,"reverse-window-removed id=%llu\n",static_cast<unsigned long long>(source->id));}
        for(auto window:eligible) {
            {std::lock_guard lock(source_mutex);if(sources.contains(window))continue;}
            auto source=std::make_shared<Source>();source->window=window;source->id=next_id++;GetWindowThreadProcessId(window,&source->pid);
            const auto owner=GetWindow(window,GW_OWNER);
            {std::lock_guard lock(source_mutex);if(sources.contains(owner))source->owner=sources.at(owner)->id;}
            viewflow::windows_capture::FrameCallbacks callbacks;
            callbacks.on_frame=[this,weak=std::weak_ptr<Source>(source)](const viewflow::windows_capture::CapturedFrame& frame) {
                auto source=weak.lock();if(!source)return;
                std::lock_guard lock(source->mutex);
                D3D11_TEXTURE2D_DESC desc{};frame.surface->GetDesc(&desc);
                if(!source->texture || source->geometry.content_width!=frame.geometry.content_width || source->geometry.content_height!=frame.geometry.content_height) {
                    source->texture.Reset();desc.Width=frame.geometry.content_width;desc.Height=frame.geometry.content_height;
                    desc.MipLevels=1;desc.ArraySize=1;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;desc.MiscFlags=0;desc.Usage=D3D11_USAGE_DEFAULT;desc.CPUAccessFlags=0;
                    check(device->CreateTexture2D(&desc,nullptr,&source->texture));
                }
                D3D11_BOX box{0,0,0,frame.geometry.content_width,frame.geometry.content_height,1};
                context->CopySubresourceRegion(source->texture.Get(),0,0,0,0,frame.surface,0,&box);
                source->geometry=frame.geometry;source->pts=frame.system_relative_time_100ns;source->dirty=true;
            };
            callbacks.on_terminal=[weak=std::weak_ptr<Source>(source)](auto failure,std::uint32_t hr){
                if(auto source=weak.lock()){std::lock_guard lock(source->mutex);source->closed=true;std::fprintf(stderr,"reverse-capture-terminal id=%llu reason=%u hr=%08x\n",static_cast<unsigned long long>(source->id),static_cast<unsigned>(failure),hr);}
            };
            const auto result=source->capture.start(window,{8192,8192,vf::max_pixels},std::move(callbacks),device.Get());
            if(!result){std::fprintf(stderr,"reverse-capture-start hwnd=%p hr=%08x\n",window,result.native_hresult);continue;}
            {std::lock_guard lock(source_mutex);sources.emplace(window,source);}
            std::fprintf(stderr,"reverse-window-added id=%llu hwnd=%p\n",static_cast<unsigned long long>(source->id),window);
        }
    }
};
void write_frame(const vf::Frame& frame) {
    auto bytes=vf::pack_frame(frame);vf::Writer prefix;prefix.u32(static_cast<std::uint32_t>(bytes.size()));
    if(fwrite(prefix.bytes.data(),1,4,stdout)!=4 || fwrite(bytes.data(),1,bytes.size(),stdout)!=bytes.size() || fflush(stdout)!=0)throw std::runtime_error("reverse output closed");
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
        _setmode(_fileno(stdin),_O_BINARY);_setmode(_fileno(stdout),_O_BINARY);
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        const auto input_desktop=OpenInputDesktop(0,FALSE,GENERIC_ALL);
        if(!input_desktop || !SetThreadDesktop(input_desktop))throw std::runtime_error("reverse capture input desktop unavailable="+std::to_string(GetLastError()));
        // Keep the bound desktop handle alive for this process's capture lifetime.
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        TimerResolution timer_resolution;
        App app;
        if(argc==5){app.left=std::stoi(argv[1]);app.top=std::stoi(argv[2]);app.right=std::stoi(argv[3]);app.bottom=std::stoi(argv[4]);}
        D3D_FEATURE_LEVEL level{};
        check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT|D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
            nullptr,0,D3D11_SDK_VERSION,&app.device,&level,&app.context));
        ComPtr<ID3D11Multithread> mt;check(app.device.As(&mt));mt->SetMultithreadProtected(TRUE);
        std::thread input([&]{app.input_loop();});
        std::unique_ptr<vf::HardwareEncoder> encoder;std::unique_ptr<vf::AlphaPlane> alpha;
        ComPtr<ID3D11Texture2D> atlas;ComPtr<ID3D11ShaderResourceView> atlas_view;ComPtr<ID3D11RenderTargetView> atlas_target;
        bool force_keyframe=true;
        std::vector<std::uint8_t> last_raw_alpha,last_encoded_alpha;
        unsigned width=0,height=0;std::map<std::int64_t,vf::Frame> pending;
        auto inventory_at=Clock::now();auto next_frame=Clock::now();std::int64_t pts=0;
        try {
            while(app.running) {
                if(Clock::now()>=inventory_at){app.inventory();inventory_at=Clock::now()+std::chrono::milliseconds(50);}
                if(encoder) {
                    std::vector<vf::EncodedFrame> encoded;check(encoder->poll(encoded));
                    for(auto& packet:encoded) {
                        auto found=pending.find(packet.timestamp);if(found==pending.end())continue;
                        found->second.color=std::move(packet.bytes);found->second.keyframe=packet.keyframe;write_frame(found->second);
                        pending.erase(found);
                    }
                }
                if(Clock::now()<next_frame || pending.size()>=4){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
                std::vector<std::shared_ptr<Source>> sources;
                {std::lock_guard lock(app.source_mutex);for(auto& [_,source]:app.sources)sources.push_back(source);}
                vf::Frame frame;unsigned row_x=0,row_y=0,row_height=0,needed_width=192,needed_height=192;
                for(auto& source:sources) {
                    std::lock_guard lock(source->mutex);if(!source->texture || source->closed)continue;
                    const auto w=source->geometry.content_width,h=source->geometry.content_height;
                    if(w>8192 || h>4096)continue;
                    if(row_x+w>8192){row_y+=row_height;row_x=0;row_height=0;}
                    if(row_y+h>4096)continue;
                    const auto rect=App::bounds(source->window);
                    GUITHREADINFO gui{};gui.cbSize=sizeof(gui);
                    const bool moving=GetGUIThreadInfo(GetWindowThreadProcessId(source->window,nullptr),&gui) &&
                        (gui.flags&GUI_INMOVESIZE) && gui.hwndMoveSize==source->window;
                    if(moving && !source->in_move){source->move_origin=rect;source->was_resized=false;}
                    if(moving && (rect.right-rect.left!=source->move_origin.right-source->move_origin.left ||
                        rect.bottom-rect.top!=source->move_origin.bottom-source->move_origin.top))source->was_resized=true;
                    source->in_move=moving;
                    const bool native_drag=moving && !source->was_resized &&
                        (rect.left!=source->move_origin.left || rect.top!=source->move_origin.top);
                    frame.tiles.push_back({source->id,source->owner,rect.left,rect.top,w,h,row_x,row_y,title(source->window),native_drag?1u:0u,
                        rect.right-rect.left==static_cast<int>(w) && rect.bottom-rect.top==static_cast<int>(h)?source->geometry_ack:0});
                    row_x+=w;row_height=std::max(row_height,h);needed_width=std::max(needed_width,row_x);needed_height=std::max(needed_height,row_y+h);
                }
                if(frame.tiles.empty() && !encoder){next_frame=Clock::now()+std::chrono::milliseconds(16);continue;}
                needed_width=(needed_width+63)&~63u;needed_height=(needed_height+63)&~63u;
                if(needed_width>width || needed_height>height || !encoder) {
                    // Drain ownership before replacing a codec; no old metadata is
                    // ever attached to a frame from the new dimensions.
                    if(!pending.empty())continue;
                    width=std::max(width,needed_width);height=std::max(height,needed_height);
                    force_keyframe=true;last_raw_alpha.clear();last_encoded_alpha.clear();
                    encoder=std::make_unique<vf::HardwareEncoder>();check(encoder->start(app.device.Get(),width,height,60,2));
                    alpha=std::make_unique<vf::AlphaPlane>();check(alpha->start(app.device.Get(),width,height));
                    atlas_view.Reset();atlas_target.Reset();atlas.Reset();
                    D3D11_TEXTURE2D_DESC desc{};desc.Width=width;desc.Height=height;desc.ArraySize=1;desc.MipLevels=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
                    check(app.device->CreateTexture2D(&desc,nullptr,&atlas));check(app.device->CreateShaderResourceView(atlas.Get(),nullptr,&atlas_view));check(app.device->CreateRenderTargetView(atlas.Get(),nullptr,&atlas_target));
                    std::fprintf(stderr,"reverse-atlas hardware=mf-hevc width=%u height=%u\n",width,height);
                }
                const float clear[4]={0,0,0,0};app.context->ClearRenderTargetView(atlas_target.Get(),clear);
                for(auto& tile:frame.tiles) {
                    auto source=app.source_for(tile.id);if(!source)continue;
                    std::lock_guard lock(source->mutex);
                    if(!source->texture || source->geometry.content_width!=tile.width || source->geometry.content_height!=tile.height)continue;
                    app.context->CopySubresourceRegion(atlas.Get(),0,tile.atlas_x,tile.atlas_y,0,source->texture.Get(),0,nullptr);
                }
                LARGE_INTEGER ticks{},frequency{};QueryPerformanceCounter(&ticks);QueryPerformanceFrequency(&frequency);
                const auto now=ticks.QuadPart/frequency.QuadPart*10000000+(ticks.QuadPart%frequency.QuadPart)*10000000/frequency.QuadPart;
                pts=std::max(pts+1,now);frame.pts=pts;frame.width=width;frame.height=height;
                const auto result=encoder->submit(atlas.Get(),pts,force_keyframe);check(result);
                if(result==S_FALSE){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
                next_frame=std::max(next_frame+std::chrono::nanoseconds(1'000'000'000/60),Clock::now());
                force_keyframe=false;
                std::vector<std::uint8_t> raw_alpha;check(alpha->read(atlas_view.Get(),raw_alpha));
                if(raw_alpha!=last_raw_alpha){last_encoded_alpha=vf::encode_alpha(raw_alpha);last_raw_alpha=std::move(raw_alpha);}
                frame.alpha=last_encoded_alpha;
                pending.emplace(pts,std::move(frame));
            }
        }catch(...){app.running=false;CancelSynchronousIo(input.native_handle());input.join();throw;}
        input.join();return 0;
    }catch(const std::exception& error){std::fprintf(stderr,"reverse source: %s\n",error.what());return 1;}
}

#include "backdrop_client.hpp"
#include "gpu_decoder.hpp"
#include "../reverse-common/wire.hpp"
#include "../reverse-common/native_touchpad.hpp"
#include "../reverse-common/window_surface.hpp"
#include "../hyprland-plugin/src/touchpad_capture.hpp"
#include "../reverse-common/geometry_sync.hpp"
#include "xdg-shell-client-protocol.h"
#include "viewporter-client-protocol.h"
#include <wayland-client.h>
#include <wayland-egl.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
extern "C" {
#include <libavutil/frame.h>
}
#include <nlohmann/json.hpp>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/eventfd.h>
#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <xkbcommon/xkbcommon.h>
#include <csignal>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <thread>
#include <cmath>
#include <algorithm>
#include <optional>
#include <array>
#include <sstream>

namespace vf=viewflow::reverse;
using Clock=std::chrono::steady_clock;
namespace {
bool read_all(int fd,void* data,std::size_t size) {
    auto* bytes=static_cast<std::uint8_t*>(data);
    while(size){const auto count=::read(fd,bytes,size);if(count<0 && errno==EINTR)continue;if(count<=0)return false;bytes+=count;size-=count;}return true;
}
void write_all(int fd,std::span<const std::uint8_t> data) {
    while(!data.empty()){const auto count=::write(fd,data.data(),data.size());if(count<0 && errno==EINTR)continue;if(count<=0)throw std::runtime_error("reverse input pipe closed");data=data.subspan(count);}
}
std::string ipc(const std::string& command) {
    const auto* runtime=getenv("XDG_RUNTIME_DIR"),*signature=getenv("HYPRLAND_INSTANCE_SIGNATURE");
    if(!runtime || !signature)throw std::runtime_error("Hyprland IPC environment missing");
    const std::string path=std::string(runtime)+"/hypr/"+signature+"/.socket.sock";
    sockaddr_un addr{};addr.sun_family=AF_UNIX;if(path.size()>=sizeof(addr.sun_path))throw std::runtime_error("Hyprland IPC path too long");
    std::memcpy(addr.sun_path,path.c_str(),path.size()+1);
    const int fd=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0);if(fd<0)throw std::runtime_error("Hyprland socket failed");
    const timeval timeout{1,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    std::string result;
    try {
        if(connect(fd,reinterpret_cast<sockaddr*>(&addr),sizeof(addr))<0)throw std::runtime_error("Hyprland IPC connect failed");
        write_all(fd,{reinterpret_cast<const std::uint8_t*>(command.data()),command.size()});
        char buffer[8192];for(;;){const auto size=::read(fd,buffer,sizeof(buffer));if(size<0 && errno==EINTR)continue;if(size<=0)break;result.append(buffer,size);if(result.size()>4*1024*1024)throw std::runtime_error("Hyprland IPC reply too large");}
    }catch(...){close(fd);throw;}close(fd);return result;
}
void eval(const std::string& expression) {
    auto result=ipc("/eval "+expression);
    if(result.find("error")!=std::string::npos || result.find("Error")!=std::string::npos)throw std::runtime_error("Hyprland reverse geometry: "+result);
}
struct App;
struct Window {
    App* app{};std::uint64_t id{};vf::Tile tile;
    std::unique_ptr<vf::BackdropClient> backdrop;
    wl_surface* surface{};xdg_surface* shell{};xdg_toplevel* top{};wp_viewport* viewport{};
    wl_egl_window* native{};EGLSurface egl{EGL_NO_SURFACE};
    bool configured{},placed{},source_fullscreen{},fullscreen_pending{};vf::GeometrySync geometry_sync;
    int logical_width{},logical_height{},region_width{},region_height{};
    std::int32_t drag_grab_x{},drag_grab_y{};bool drag_has_anchor{};
    std::uint64_t alpha_revision{},native_address{};std::array<unsigned,8> alpha_rect{};bool drag_announced{},drag_start_pending{};
    ~Window();
    bool ime_popup() const {return (tile.flags&2)!=0;}
    std::string app_id() const;
};
struct App {
    wl_display* display{};wl_registry* registry{};wl_compositor* compositor{};xdg_wm_base* wm{};
    wl_subcompositor* subcompositor{};
    wp_viewporter* viewporter{};wl_seat* seat{};wl_pointer* pointer{};wl_keyboard* keyboard{};
    EGLDisplay egl_display{EGL_NO_DISPLAY};EGLConfig config{};EGLContext context{EGL_NO_CONTEXT};EGLSurface pbuffer{EGL_NO_SURFACE};
    std::unique_ptr<vf::GpuDecoder> decoder;
    GLuint program{},alpha_texture{};unsigned codec{},atlas_width{},atlas_height{};
    std::map<std::uint64_t,std::unique_ptr<Window>> windows;
    std::map<std::int64_t,vf::Frame> pending;
    std::unique_ptr<viewflow::hyprland::TouchpadCapture> touchpad;
    std::uint64_t touchpad_target{};
    vf::NativeTouchpadEncoder native_touchpad;
    bool native_gesture{};
    std::uint32_t axis_source=UINT32_MAX;
    std::uint64_t pointer_window{},keyboard_window{},sequence{};double pointer_x{},pointer_y{};
    xkb_context* key_context=xkb_context_new(XKB_CONTEXT_NO_FLAGS);xkb_keymap* key_map{};
    std::set<std::uint32_t> held_super,pending_super;bool super_drag{};
    std::map<std::uint32_t,std::uint64_t> forwarded_buttons;
    std::uint64_t pointer_anchor_window{};
    vf::PointerAnchor pointer_anchor_x,pointer_anchor_y;
    vf::NativeMoveConfirmation native_move_confirmation;
    std::uint64_t native_move_candidate{},local_titlebar_window{};
    std::uint32_t native_move_serial{};
    double native_move_grab_x{},native_move_grab_y{};
    bool local_titlebar_seen{};
    std::optional<std::uint32_t> repeating_key;Clock::time_point repeat_at{};int repeat_rate{25},repeat_delay{600};
    int scale{2},origin_x{3072},origin_y{390};
    bool mac_shadow=std::getenv("VIEWFLOW_REVERSE_MAC_SHADOW")!=nullptr;
    double axes[2]{};int axis120[2]{};
    std::atomic<bool> running{true};std::atomic<bool> input_done{false};bool validate_only{};unsigned decoded_count{};
    int wake=eventfd(0,EFD_CLOEXEC|EFD_NONBLOCK);
    std::mutex queue_mutex;std::condition_variable queue_changed;std::deque<vf::Frame> queue;
    std::vector<std::uint8_t> latest_alpha,encoded_alpha;std::uint64_t alpha_revision{};
    ~App() {
        windows.clear();decoder.reset();
        if(key_map)xkb_keymap_unref(key_map);if(key_context)xkb_context_unref(key_context);
        if(egl_display!=EGL_NO_DISPLAY){eglMakeCurrent(egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);if(pbuffer!=EGL_NO_SURFACE)eglDestroySurface(egl_display,pbuffer);if(context!=EGL_NO_CONTEXT)eglDestroyContext(egl_display,context);eglTerminate(egl_display);}
        if(keyboard)wl_keyboard_release(keyboard);if(pointer)wl_pointer_release(pointer);if(seat)wl_seat_release(seat);
        if(viewporter)wp_viewporter_destroy(viewporter);if(wm)xdg_wm_base_destroy(wm);if(compositor)wl_compositor_destroy(compositor);
        if(registry)wl_registry_destroy(registry);if(display)wl_display_disconnect(display);if(wake>=0)close(wake);
    }
    std::mutex output_mutex;
    std::uint64_t send(std::uint64_t id,vf::InputKind kind,int a=0,int b=0,int c=0,int d=0) {
        std::lock_guard lock(output_mutex);
        auto bytes=vf::pack_input({id,++sequence,kind,a,b,c,d});vf::Writer prefix;prefix.u32(static_cast<std::uint32_t>(bytes.size()));
        write_all(STDOUT_FILENO,prefix.bytes);write_all(STDOUT_FILENO,bytes);return sequence;
    }
    bool hid_ready() const {
        const auto it=windows.find(pointer_window);
        return it!=windows.end() && (it->second->tile.flags&8);
    }
    void send_native(std::uint64_t target,const vf::NativeTouchpadReport& report) {
        for(unsigned offset=0;offset<72;offset+=12) {
            std::array<std::uint32_t,3> words{};
            for(unsigned j=0;j<3;++j)for(unsigned k=0;k<4;++k)words[j]|=std::uint32_t(report[offset+4*j+k])<<(8*k);
            send(target,vf::InputKind::native_touchpad_chunk,offset,words[0],words[1],words[2]);
        }
        send(target,vf::InputKind::native_touchpad_commit,72);
    }
    void drain_touchpad() {
        if(!touchpad)return;
        const auto target=super_drag || local_titlebar_window || (mac_shadow && !hid_ready())?0:pointer_window;
        const auto ticks=std::chrono::duration_cast<std::chrono::microseconds>(Clock::now().time_since_epoch()).count()/100;
        if(touchpad_target && touchpad_target!=target){
            auto frame=touchpad->current();frame.count=0;
            if(mac_shadow)native_touchpad.frame(frame,ticks,[&](const auto& report){send_native(touchpad_target,report);});
            else send(touchpad_target,vf::InputKind::touchpad_frame,frame.width,frame.height,0);
            native_gesture=false;
            touchpad->drain(false,[](const auto&){});
        }
        touchpad_target=target;
        touchpad->drain(target!=0,[&](const auto& frame){
            if(mac_shadow) {
                if(native_touchpad.routes(frame.count) && !native_gesture)forward_pointer();
                native_gesture=native_touchpad.routes(frame.count);
                native_touchpad.frame(frame,ticks,[&](const auto& report){send_native(target,report);});
            } else {
                for(unsigned i=0;i<frame.count;++i){const auto& c=frame.contacts[i];send(target,vf::InputKind::touchpad_contact,c.id,c.x,c.y);}
                send(target,vf::InputKind::touchpad_frame,frame.width,frame.height,frame.count);
            }
        });
    }
    std::uint64_t identify(wl_surface* surface) {for(auto& [id,w]:windows)if(w->surface==surface)return id;return 0;}
    void forward_pointer(bool begin_drag=false) {
        if(!pointer_window || local_titlebar_window)return;
        const auto& window=*windows.at(pointer_window);
        if(window.tile.flags&16) {
            const auto surface=vf::body_surface(window.logical_width,window.logical_height);
            if(begin_drag || pointer_anchor_window==pointer_window) {
                const auto position=nlohmann::json::parse(ipc("j/cursorpos"));
                const auto x=position.at("x").get<double>(),y=position.at("y").get<double>();
                if(begin_drag && pointer_anchor_window!=pointer_window) {
                    pointer_anchor_window=pointer_window;
                    pointer_anchor_x={x,vf::body_pointer(pointer_x,surface.x,window.logical_width,window.tile.logical_width,window.tile.x,scale),double(window.tile.logical_width)*scale/std::max(1,window.logical_width)};
                    pointer_anchor_y={y,vf::body_pointer(pointer_y,surface.y,window.logical_height,window.tile.logical_height,window.tile.y,scale),double(window.tile.logical_height)*scale/std::max(1,window.logical_height)};
                }
                send(pointer_window,vf::InputKind::pointer,
                    static_cast<int>(std::lround(pointer_anchor_x.at(x))),
                    static_cast<int>(std::lround(pointer_anchor_y.at(y))),1);
                return;
            }
            // Native framing is outside the body. Map the visible body point
            // through its displayed size before entering the Mac desktop space.
            send(pointer_window,vf::InputKind::pointer,
                static_cast<int>(std::lround(vf::body_pointer(pointer_x,surface.x,window.logical_width,window.tile.logical_width,window.tile.x,scale))),
                static_cast<int>(std::lround(vf::body_pointer(pointer_y,surface.y,window.logical_height,window.tile.logical_height,window.tile.y,scale))),1);
            return;
        }
        // Surface coordinates are relative to a moving proxy. Resolve the actual
        // desktop pointer, so a delayed Windows position never adds drag motion twice.
        const auto position=nlohmann::json::parse(ipc("j/cursorpos"));
        send(pointer_window,vf::InputKind::pointer,
            static_cast<int>(std::lround((position.at("x").get<double>()-origin_x)*scale)),
            static_cast<int>(std::lround((position.at("y").get<double>()-origin_y)*scale)),1);
    }
    static void pointer_enter(void* data,wl_pointer*,std::uint32_t,wl_surface* surface,wl_fixed_t x,wl_fixed_t y) {
        auto& a=*static_cast<App*>(data);a.pointer_window=a.identify(surface);a.pointer_x=wl_fixed_to_double(x);a.pointer_y=wl_fixed_to_double(y);
        a.forward_pointer();
    }
    static void pointer_leave(void* data,wl_pointer*,std::uint32_t,wl_surface*) {static_cast<App*>(data)->pointer_window=0;}
    static void pointer_motion(void* data,wl_pointer*,std::uint32_t,wl_fixed_t x,wl_fixed_t y) {
        auto& a=*static_cast<App*>(data);a.pointer_x=wl_fixed_to_double(x);a.pointer_y=wl_fixed_to_double(y);
        a.forward_pointer();
    }
    static void pointer_button(void* data,wl_pointer*,std::uint32_t serial,std::uint32_t,std::uint32_t button,std::uint32_t state) {
        auto& a=*static_cast<App*>(data);
        if(state==WL_POINTER_BUTTON_STATE_RELEASED) {
            if(button==272) {
                a.native_move_confirmation.cancel();a.native_move_candidate=0;
                a.local_titlebar_window=0;a.local_titlebar_seen=false;
            }
            auto held=a.forwarded_buttons.find(button);
            if(held!=a.forwarded_buttons.end()) {
                a.send(held->second,vf::InputKind::button,static_cast<int>(button),0);
                a.forwarded_buttons.erase(held);
            }
            if(a.forwarded_buttons.empty())a.pointer_anchor_window=0;
            return;
        }
        if(!a.windows.contains(a.pointer_window))return;
        const auto& window=*a.windows.at(a.pointer_window);
        if(!vf::body_point(vf::body_surface(window.logical_width,window.logical_height),a.pointer_x,a.pointer_y))return;
        if(button==272 && state==WL_POINTER_BUTTON_STATE_PRESSED && !a.held_super.empty() && a.windows.contains(a.pointer_window) && !a.windows.at(a.pointer_window)->ime_popup()) {
            a.super_drag=true;a.pending_super.clear();a.pointer_anchor_window=0;a.send(a.pointer_window,vf::InputKind::release);
            xdg_toplevel_move(a.windows.at(a.pointer_window)->top,a.seat,serial);return;
        }
        if(a.super_drag && button==272)return;
        if(a.pointer_window) {
            a.forward_pointer(true);
            if(button==273)std::fprintf(stderr,"Mac/window secondary button id=%llu down=%u\n",static_cast<unsigned long long>(a.pointer_window),unsigned(state==WL_POINTER_BUTTON_STATE_PRESSED));
            a.send(a.pointer_window,vf::InputKind::button,static_cast<int>(button),state==WL_POINTER_BUTTON_STATE_PRESSED);
            a.forwarded_buttons[button]=a.pointer_window;
            if(button==272 && (window.tile.flags&16) && !window.ime_popup() && window.placed &&
               (!window.geometry_sync.pending || window.tile.geometry_ack>=window.geometry_sync.pending)) {
                a.native_move_candidate=window.id;a.native_move_serial=serial;
                a.native_move_grab_x=a.pointer_anchor_x.desktop-window.geometry_sync.observed.x;
                a.native_move_grab_y=a.pointer_anchor_y.desktop-window.geometry_sync.observed.y;
                a.native_move_confirmation.begin({window.tile.x,window.tile.y,
                    static_cast<int>(window.tile.logical_width),static_cast<int>(window.tile.logical_height)},window.tile.geometry_ack);
            }
        }
    }
    void take_local_titlebar(Window& window) {
        if(native_move_candidate!=window.id || pointer_window!=window.id || local_titlebar_window || !native_move_confirmation.armed)return;
        const auto button=forwarded_buttons.find(272);
        if(button==forwarded_buttons.end() || button->second!=window.id)return;
        const auto& tile=window.tile;
        const auto pointer=nlohmann::json::parse(ipc("j/cursorpos"));
        const auto x=pointer.at("x").get<double>(),y=pointer.at("y").get<double>();
        if(x==pointer_anchor_x.desktop && y==pointer_anchor_y.desktop)return;
        if(!native_move_confirmation.observe({tile.x,tile.y,static_cast<int>(tile.logical_width),
                static_cast<int>(tile.logical_height)},tile.geometry_ack))return;
        // Align the proxy to the original physical grab point, rather than
        // preserving the offset introduced by the first delayed Mac frame.
        auto local=window.geometry_sync.observed;
        if(window.geometry_sync.floating) {
            local.x=static_cast<int>(std::lround(x-native_move_grab_x));
            local.y=static_cast<int>(std::lround(y-native_move_grab_y));
            const std::string selector="'address:0x"+[] (std::uint64_t address) {
                std::ostringstream text;text<<std::hex<<address;return text.str();
            }(window.native_address)+"'";
            eval("hl.dispatch(hl.dsp.window.move({x="+std::to_string(local.x)+",y="+std::to_string(local.y)+",window="+selector+"}))");
        }
        // End the source mouse drag before ordered geometry updates take over.
        send(window.id,vf::InputKind::button,272,0);
        forwarded_buttons.erase(button);pointer_anchor_window=0;
        native_move_candidate=0;local_titlebar_window=window.id;local_titlebar_seen=false;
        xdg_toplevel_move(window.top,seat,native_move_serial);
        wl_display_flush(display);
        window.geometry_sync.sent(send(window.id,vf::InputKind::geometry,
            (local.x-origin_x)*scale,(local.y-origin_y)*scale,local.width*scale,local.height*scale));
        std::fprintf(stderr,"Mac titlebar local requested id=%llu\n",static_cast<unsigned long long>(window.id));
    }
    static void pointer_axis(void* data,wl_pointer*,std::uint32_t,std::uint32_t axis,wl_fixed_t value) {if(axis<2)static_cast<App*>(data)->axes[axis]+=wl_fixed_to_double(value);}
    static void pointer_frame(void* data,wl_pointer*) {
        auto& a=*static_cast<App*>(data);for(unsigned i=0;i<2;++i){const auto delta=a.axis120[i]?a.axis120[i]:static_cast<int>(std::lround(a.axes[i]*12));if(delta && a.pointer_window && !(a.touchpad && a.touchpad->available() && (!a.mac_shadow || a.hid_ready()) && a.axis_source==WL_POINTER_AXIS_SOURCE_FINGER))a.send(a.pointer_window,vf::InputKind::wheel,i,i?-delta:-delta);a.axes[i]=0;a.axis120[i]=0;}a.axis_source=UINT32_MAX;
    }
    static void pointer_axis_source(void* data,wl_pointer*,std::uint32_t source){static_cast<App*>(data)->axis_source=source;}
    static void pointer_axis_stop(void*,wl_pointer*,std::uint32_t,std::uint32_t){}
    static void pointer_axis_discrete(void*,wl_pointer*,std::uint32_t,std::int32_t){}
    static void pointer_value120(void* data,wl_pointer*,std::uint32_t axis,std::int32_t value){if(axis<2)static_cast<App*>(data)->axis120[axis]+=value;}
    static void pointer_direction(void*,wl_pointer*,std::uint32_t,std::uint32_t){}
    static constexpr wl_pointer_listener pointer_listener={pointer_enter,pointer_leave,pointer_motion,pointer_button,pointer_axis,pointer_frame,pointer_axis_source,pointer_axis_stop,pointer_axis_discrete,pointer_value120,pointer_direction};
    static void keymap(void* data,wl_keyboard*,std::uint32_t format,int fd,std::uint32_t size){
        auto& a=*static_cast<App*>(data);
        if(format==WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 && size>0 && size<=4*1024*1024 && a.key_context) {
            void* bytes=mmap(nullptr,size,PROT_READ,MAP_PRIVATE,fd,0);
            if(bytes!=MAP_FAILED) {
                if(static_cast<const char*>(bytes)[size-1]==0) {
                    auto* map=xkb_keymap_new_from_string(a.key_context,static_cast<const char*>(bytes),XKB_KEYMAP_FORMAT_TEXT_V1,XKB_KEYMAP_COMPILE_NO_FLAGS);
                    if(map){if(a.key_map)xkb_keymap_unref(a.key_map);a.key_map=map;}
                }
                munmap(bytes,size);
            }
        }
        close(fd);
    }
    static void key_enter(void* data,wl_keyboard*,std::uint32_t,wl_surface* surface,wl_array* keys) {
        auto& a=*static_cast<App*>(data);a.keyboard_window=a.identify(surface);a.repeating_key.reset();
        if(a.keyboard_window){
            a.send(a.keyboard_window,vf::InputKind::focus);
            for(std::size_t i=0;i<keys->size/sizeof(std::uint32_t);++i){const auto code=static_cast<const std::uint32_t*>(keys->data)[i];
                if(code==125 || code==126){a.held_super.insert(code);a.pending_super.insert(code);}
                else if(code==29 || code==97 || code==42 || code==54 || code==56 || code==100)
                    a.send(a.keyboard_window,vf::InputKind::key,code,1);
            }
        }
    }
    static void key_leave(void* data,wl_keyboard*,std::uint32_t,wl_surface*) {
        auto& a=*static_cast<App*>(data);a.send(a.keyboard_window,vf::InputKind::release);if(a.pointer_anchor_window==a.keyboard_window)a.pointer_anchor_window=0;a.keyboard_window=0;a.repeating_key.reset();a.held_super.clear();a.pending_super.clear();a.super_drag=false;
    }
    static void key(void* data,wl_keyboard*,std::uint32_t,std::uint32_t,std::uint32_t code,std::uint32_t state) {
        auto& a=*static_cast<App*>(data);const bool pressed=state==WL_KEYBOARD_KEY_STATE_PRESSED;
        if(code==125 || code==126) {
            if(pressed){a.held_super.insert(code);a.pending_super.insert(code);}
            else {
                if(a.pending_super.erase(code) && !a.super_drag && a.keyboard_window)a.send(a.keyboard_window,vf::InputKind::key,code,1);
                if(a.keyboard_window && !a.super_drag)a.send(a.keyboard_window,vf::InputKind::key,code,0);
                a.held_super.erase(code);if(a.held_super.empty())a.super_drag=false;
            }
            return;
        }
        for(const auto pending:a.pending_super)if(a.keyboard_window)a.send(a.keyboard_window,vf::InputKind::key,pending,1);
        a.pending_super.clear();
        if(a.keyboard_window)a.send(a.keyboard_window,vf::InputKind::key,static_cast<int>(code),pressed);
        if(pressed && a.keyboard_window && a.repeat_rate>0 && a.key_map && xkb_keymap_key_repeats(a.key_map,code+8)) {
            a.repeating_key=code;a.repeat_at=Clock::now()+std::chrono::milliseconds(a.repeat_delay);
        } else if(!pressed && a.repeating_key==code)a.repeating_key.reset();
    }
    static void modifiers(void*,wl_keyboard*,std::uint32_t,std::uint32_t,std::uint32_t,std::uint32_t,std::uint32_t){}
    static void repeat(void* data,wl_keyboard*,std::int32_t rate,std::int32_t delay){auto& a=*static_cast<App*>(data);a.repeat_rate=std::clamp(rate,0,1000);a.repeat_delay=std::clamp(delay,0,10000);if(rate<=0)a.repeating_key.reset();}
    void repeat_keys() {
        if(repeating_key && keyboard_window && repeat_rate>0 && Clock::now()>=repeat_at){
            send(keyboard_window,vf::InputKind::key,*repeating_key,1);
            repeat_at=std::max(repeat_at+std::chrono::nanoseconds(1'000'000'000/repeat_rate),Clock::now());
        }
    }
    static constexpr wl_keyboard_listener keyboard_listener={keymap,key_enter,key_leave,key,modifiers,repeat};
    static void capabilities(void* data,wl_seat* seat,std::uint32_t caps) {
        auto& a=*static_cast<App*>(data);
        if((caps&WL_SEAT_CAPABILITY_POINTER) && !a.pointer){a.pointer=wl_seat_get_pointer(seat);wl_pointer_add_listener(a.pointer,&pointer_listener,&a);}
        if((caps&WL_SEAT_CAPABILITY_KEYBOARD) && !a.keyboard){a.keyboard=wl_seat_get_keyboard(seat);wl_keyboard_add_listener(a.keyboard,&keyboard_listener,&a);}
    }
    static void seat_name(void*,wl_seat*,const char*){}
    static constexpr wl_seat_listener seat_listener={capabilities,seat_name};
    static void ping(void*,xdg_wm_base* wm,std::uint32_t serial){xdg_wm_base_pong(wm,serial);}
    static constexpr xdg_wm_base_listener wm_listener={ping};
    static void global(void* data,wl_registry* registry,std::uint32_t id,const char* name,std::uint32_t version) {
        auto& a=*static_cast<App*>(data);
        if(std::strcmp(name,wl_compositor_interface.name)==0)a.compositor=static_cast<wl_compositor*>(wl_registry_bind(registry,id,&wl_compositor_interface,std::min(version,4u)));
        if(std::strcmp(name,wl_subcompositor_interface.name)==0)a.subcompositor=static_cast<wl_subcompositor*>(wl_registry_bind(registry,id,&wl_subcompositor_interface,1));
        else if(std::strcmp(name,xdg_wm_base_interface.name)==0){a.wm=static_cast<xdg_wm_base*>(wl_registry_bind(registry,id,&xdg_wm_base_interface,std::min(version,3u)));xdg_wm_base_add_listener(a.wm,&wm_listener,&a);}
        else if(std::strcmp(name,wp_viewporter_interface.name)==0)a.viewporter=static_cast<wp_viewporter*>(wl_registry_bind(registry,id,&wp_viewporter_interface,1));
        else if(std::strcmp(name,wl_seat_interface.name)==0 && !a.seat){a.seat=static_cast<wl_seat*>(wl_registry_bind(registry,id,&wl_seat_interface,std::min(version,9u)));wl_seat_add_listener(a.seat,&seat_listener,&a);}
    }
    static void removed(void*,wl_registry*,std::uint32_t){}
    static constexpr wl_registry_listener registry_listener={global,removed};
    static void configured(void* data,xdg_surface* surface,std::uint32_t serial) {auto& w=*static_cast<Window*>(data);xdg_surface_ack_configure(surface,serial);w.configured=true;}
    static constexpr xdg_surface_listener surface_listener={configured};
    static void top_configure(void* data,xdg_toplevel*,std::int32_t width,std::int32_t height,wl_array*) {
        auto& w=*static_cast<Window*>(data);
        if(width>0)w.logical_width=width;
        if(height>0)w.logical_height=height;
    }
    static void top_close(void* data,xdg_toplevel*) {auto& w=*static_cast<Window*>(data);w.app->send(w.id,vf::InputKind::close);}
    static void bounds(void*,xdg_toplevel*,std::int32_t,std::int32_t){}
    static void wm_caps(void*,xdg_toplevel*,wl_array*){}
    static constexpr xdg_toplevel_listener top_listener={top_configure,top_close,bounds,wm_caps};
    void start() {
        display=wl_display_connect(nullptr);if(!display)throw std::runtime_error("Wayland unavailable");
        registry=wl_display_get_registry(display);wl_registry_add_listener(registry,&registry_listener,this);
        if(wl_display_roundtrip(display)<0 || !compositor || !wm || !viewporter)throw std::runtime_error("required Wayland globals unavailable");
        egl_display=eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR,display,nullptr);
        if(egl_display==EGL_NO_DISPLAY || !eglInitialize(egl_display,nullptr,nullptr) || !eglBindAPI(EGL_OPENGL_ES_API))throw std::runtime_error("Wayland EGL unavailable");
        const EGLint attrs[]={EGL_SURFACE_TYPE,EGL_WINDOW_BIT|EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
        EGLint count{};if(!eglChooseConfig(egl_display,attrs,&config,1,&count) || !count)throw std::runtime_error("Wayland RGBA EGL config unavailable");
        const EGLint version[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};context=eglCreateContext(egl_display,config,EGL_NO_CONTEXT,version);
        const EGLint size[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE};pbuffer=eglCreatePbufferSurface(egl_display,config,size);
        make_current(pbuffer);
        const char* vertex=R"(#version 300 es
out vec2 uv;
void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);uv=p;gl_Position=vec4(p*vec2(2,-2)+vec2(-1,1),0,1);})";
        const char* fragment=R"(#version 300 es
precision highp float;
in vec2 uv;out vec4 color;uniform sampler2D luma;uniform sampler2D chroma;uniform sampler2D opacity;uniform vec4 tile;uniform bool straight_alpha;
void main(){vec2 p=tile.xy+uv*tile.zw;float y=(texture(luma,p).r-16.0/255.0)*255.0/219.0;vec2 c=(texture(chroma,p).rg-vec2(128.0/255.0))*255.0/224.0;
float a=texture(opacity,p).r;vec3 rgb=vec3(y+1.5748*c.y,y-0.187324*c.x-0.468124*c.y,y+1.8556*c.x);color=vec4(straight_alpha ? clamp(rgb,vec3(0),vec3(1))*a : clamp(rgb,vec3(0),vec3(a)),a);})";
        auto compile=[](GLenum type,const char* source){const auto shader=glCreateShader(type);glShaderSource(shader,1,&source,nullptr);glCompileShader(shader);GLint okay{};glGetShaderiv(shader,GL_COMPILE_STATUS,&okay);if(!okay){char log[2048]{};glGetShaderInfoLog(shader,sizeof(log),nullptr,log);throw std::runtime_error(log);}return shader;};
        const auto vs=compile(GL_VERTEX_SHADER,vertex),fs=compile(GL_FRAGMENT_SHADER,fragment);
        program=glCreateProgram();glAttachShader(program,vs);glAttachShader(program,fs);glLinkProgram(program);glDeleteShader(vs);glDeleteShader(fs);
        GLint okay{};glGetProgramiv(program,GL_LINK_STATUS,&okay);if(!okay)throw std::runtime_error("reverse shader link failed");
        glGenTextures(1,&alpha_texture);glBindTexture(GL_TEXTURE_2D,alpha_texture);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
        eval("hl.window_rule({name='viewflow-windows-reverse',match={class='^ViewflowReverse-.*$'},float=true,no_initial_focus=true,decorate=false,border_size=0,no_shadow=true,rounding=0,no_blur=true,no_anim=true})");
        // The compositor animates tiled layout goals locally; only the final
        // goal from j/clients is mirrored to Windows, never animation samples.
        eval("hl.window_rule({name='viewflow-windows-reverse-tiled-animation',match={class='^ViewflowReverse-.*$',float=false},no_anim=false})");
        // no_focus also removes pointer hit testing in Hyprland. Popups must
        // accept input outside their parent; no_initial_focus avoids focus theft.
        eval("hl.window_rule({name='viewflow-windows-reverse-ime',match={class='^ViewflowReverse-IME-.*$'},float=true,no_initial_focus=true,no_focus=false,decorate=false,border_size=0,no_shadow=true,rounding=0,no_blur=true,no_anim=true})");
        if(mac_shadow)eval("hl.window_rule({name='viewflow-mac-shadow',match={class='^ViewflowReverse-Mac-.*$'},decorate=true,border_size=0,no_shadow=true,rounding=0})");
        if(mac_shadow)eval("hl.window_rule({name='viewflow-mac-native-decoration',match={class='^ViewflowReverse-MacNative-.*$'},decorate=true,border_size=0,no_shadow=true,rounding=16,rounding_power=2})");
        std::fprintf(stderr,"reverse-presenter ready renderer=%s\n",glGetString(GL_RENDERER));
    }
    void make_current(EGLSurface surface) {if(!eglMakeCurrent(egl_display,surface,surface,context))throw std::runtime_error("reverse EGL make current failed");}
    Window& create(const vf::Tile& tile) {
        auto w=std::make_unique<Window>();w->app=this;w->id=tile.id;w->tile=tile;
        if(tile.flags&16)std::fprintf(stderr,"Mac native frame id=%llu pixels=%ux%u body=%u,%u %ux%u logical=%ux%u scale=%u\n",
            static_cast<unsigned long long>(tile.id),tile.width,tile.height,tile.body_x,tile.body_y,
            tile.body_width,tile.body_height,tile.logical_width,tile.logical_height,tile.pixel_scale);
        w->logical_width=vf::logical_width(tile,scale);w->logical_height=vf::logical_height(tile,scale);
        w->surface=wl_compositor_create_surface(compositor);w->viewport=wp_viewporter_get_viewport(viewporter,w->surface);
        w->shell=xdg_wm_base_get_xdg_surface(wm,w->surface);xdg_surface_add_listener(w->shell,&surface_listener,w.get());
        w->top=xdg_surface_get_toplevel(w->shell);xdg_toplevel_add_listener(w->top,&top_listener,w.get());
        xdg_toplevel_set_app_id(w->top,w->app_id().c_str());xdg_toplevel_set_title(w->top,tile.title.c_str());
        if(tile.owner && windows.contains(tile.owner))xdg_toplevel_set_parent(w->top,windows.at(tile.owner)->top);
        wl_surface_commit(w->surface);
        auto& result=*w;windows.emplace(tile.id,std::move(w));
        // ABI 2 capability query uses an existing input kind. Older Mac sources
        // ignore it and retain wheel scrolling; other presenters see no new flags.
        if(mac_shadow)send(tile.id,vf::InputKind::touchpad_frame,0,0,0,2);
        return result;
    }
    void region(Window& window) {
        const auto t=vf::body_tile(window.tile);
        const auto surface=vf::body_surface(window.logical_width,window.logical_height);
        const std::array<unsigned,8> bounds{t.atlas_x,t.atlas_y,t.width,t.height,t.body_x,t.body_y,t.body_width,t.body_height};
        if(window.alpha_revision==alpha_revision && window.alpha_rect==bounds && window.region_width==surface.width && window.region_height==surface.height)return;
        window.alpha_revision=alpha_revision;window.alpha_rect=bounds;window.region_width=surface.width;window.region_height=surface.height;
        auto* region=wl_compositor_create_region(compositor);
        const auto add_region=[&](unsigned left,unsigned top,unsigned right){
            const int x0=std::max(surface.x,int(std::uint64_t(left)*surface.width/t.width)),x1=std::min(surface.x+surface.body_width,int((std::uint64_t(right)*surface.width+t.width-1)/t.width));
            const int y0=std::max(surface.y,int(std::uint64_t(top)*surface.height/t.height)),y1=std::min(surface.y+surface.body_height,int((std::uint64_t(std::min(top+scale,t.height))*surface.height+t.height-1)/t.height));
            if(x1>x0 && y1>y0)wl_region_add(region,x0,y0,x1-x0,y1-y0);
        };
        for(unsigned y=0;y<t.height;y+=scale) {
            unsigned start=0;bool inside=false;
            for(unsigned x=0;x<=t.width;x+=scale) {
                const bool opaque=x<t.width && vf::body_pixel(t,x,y) && latest_alpha[std::size_t(t.atlas_y+y)*atlas_width+t.atlas_x+x]>8;
                if(opaque && !inside){start=x;inside=true;}
                if(!opaque && inside){add_region(start,y,x);inside=false;}
                if(x<t.width && x+scale>t.width){if(inside)add_region(start,y,t.width);break;}
            }
        }
        wl_surface_set_input_region(window.surface,region);wl_region_destroy(region);
    }
    void draw(Window& w) {
        if(!w.configured || !decoder || !atlas_width)return;
        const auto surface=vf::body_surface(w.logical_width,w.logical_height);
        if(!w.native){w.native=wl_egl_window_create(w.surface,surface.width*scale,surface.height*scale);w.egl=eglCreateWindowSurface(egl_display,config,reinterpret_cast<EGLNativeWindowType>(w.native),nullptr);}
        if(w.egl==EGL_NO_SURFACE)throw std::runtime_error("reverse EGL window failed");
        wl_egl_window_resize(w.native,surface.width*scale,surface.height*scale,0,0);
        wp_viewport_set_destination(w.viewport,surface.width,surface.height);
        xdg_surface_set_window_geometry(w.shell,surface.x,surface.y,surface.body_width,surface.body_height);
        make_current(w.egl);eglSwapInterval(egl_display,0);
        glViewport(0,0,surface.width*scale,surface.height*scale);
        if(w.ime_popup() && !w.placed) {
            wl_region* empty=wl_compositor_create_region(compositor);wl_surface_set_input_region(w.surface,empty);wl_region_destroy(empty);
            glClearColor(0,0,0,0);glClear(GL_COLOR_BUFFER_BIT);eglSwapBuffers(egl_display,w.egl);return;
        }
        glDisable(GL_BLEND);glUseProgram(program);
        // Mac split_planes sends straight RGB; Wayland requires premultiplied RGBA.
        glUniform1i(glGetUniformLocation(program,"straight_alpha"),mac_shadow?1:0);
        const GLuint textures[]={decoder->y_texture(),decoder->uv_texture(),alpha_texture};
        const char* names[]={"luma","chroma","opacity"};
        for(unsigned i=0;i<3;++i){glActiveTexture(GL_TEXTURE0+i);glBindTexture(GL_TEXTURE_2D,textures[i]);glUniform1i(glGetUniformLocation(program,names[i]),i);}
        const auto t=vf::body_tile(w.tile);glUniform4f(glGetUniformLocation(program,"tile"),float(t.atlas_x)/atlas_width,float(t.atlas_y)/atlas_height,float(t.width)/atlas_width,float(t.height)/atlas_height);
        region(w);glDrawArrays(GL_TRIANGLES,0,3);
        if(!eglSwapBuffers(egl_display,w.egl))throw std::runtime_error("reverse Wayland swap failed");
    }
    void accept(vf::Frame frame) {
        make_current(pbuffer);
        if(!decoder || codec!=frame.codec){decoder=std::make_unique<vf::GpuDecoder>();decoder->start(frame.codec);codec=frame.codec;pending.clear();}
        const auto pts=frame.pts;
        auto color=std::move(frame.color);pending.emplace(pts,std::move(frame));
        auto decoded=decoder->submit(color,pts);
        for(auto& image:decoded) {
            const auto found=pending.find(image->pts);if(found==pending.end())throw std::runtime_error("reverse decoded metadata missing");
            auto current=std::move(found->second);pending.erase(pending.begin(),std::next(found));
            if(image->width!=static_cast<int>(current.width) || image->height!=static_cast<int>(current.height))throw std::runtime_error("reverse decoded dimensions mismatch");
            decoder->upload(image);
            const bool resized=atlas_width!=current.width || atlas_height!=current.height;
            atlas_width=current.width;atlas_height=current.height;
            if(resized || encoded_alpha!=current.alpha) {
                latest_alpha=vf::decode_alpha(current.alpha,std::size_t(atlas_width)*atlas_height);
                encoded_alpha=std::move(current.alpha);++alpha_revision;
                glActiveTexture(GL_TEXTURE2);glBindTexture(GL_TEXTURE_2D,alpha_texture);glPixelStorei(GL_UNPACK_ALIGNMENT,1);
                if(resized)glTexImage2D(GL_TEXTURE_2D,0,GL_R8,atlas_width,atlas_height,0,GL_RED,GL_UNSIGNED_BYTE,latest_alpha.data());
                else glTexSubImage2D(GL_TEXTURE_2D,0,0,0,atlas_width,atlas_height,GL_RED,GL_UNSIGNED_BYTE,latest_alpha.data());
            }
            ++decoded_count;
            if(validate_only){std::fprintf(stderr,"reverse-validated frame=%u tiles=%zu width=%u height=%u\n",decoded_count,current.tiles.size(),atlas_width,atlas_height);continue;}
            std::set<std::uint64_t> ids;
            for(auto& tile:current.tiles) {
                if(mac_shadow && (tile.flags&16))scale=tile.pixel_scale;
                ids.insert(tile.id);auto& w=windows.contains(tile.id)?*windows.at(tile.id):create(tile);
                const bool native_changed=((w.tile.flags^tile.flags)&16)!=0;
                const bool fullscreen = !w.ime_popup() && (tile.flags & vf::fullscreen_flag);
                if (fullscreen != w.source_fullscreen) {
                    w.source_fullscreen = fullscreen;
                    w.fullscreen_pending = true;
                    w.geometry_sync = {};
                    if (fullscreen) xdg_toplevel_set_fullscreen(w.top, nullptr);
                    else xdg_toplevel_unset_fullscreen(w.top);
                    wl_surface_commit(w.surface);
                    std::fprintf(stderr,"Mac source fullscreen id=%llu state=%u\n",(unsigned long long)w.id,unsigned(fullscreen));
                }
                w.tile=tile;
                try {take_local_titlebar(w);}
                catch(const std::exception& error) {
                    native_move_confirmation.cancel();native_move_candidate=0;
                    std::fprintf(stderr,"Mac titlebar takeover unavailable: %s\n",error.what());
                }
                if(native_changed)xdg_toplevel_set_app_id(w.top,w.app_id().c_str());
                if((tile.flags&1)!=0 && !w.drag_announced){
                    w.drag_start_pending=true;w.drag_has_anchor=(tile.flags&4)!=0;
                    w.drag_grab_x=tile.grab_x;w.drag_grab_y=tile.grab_y;
                }
                xdg_toplevel_set_title(w.top,tile.title.c_str());
            }
            if(!ids.contains(native_move_candidate)){native_move_candidate=0;native_move_confirmation.cancel();}
            if(!ids.contains(local_titlebar_window)){local_titlebar_window=0;local_titlebar_seen=false;}
            if(!ids.contains(pointer_anchor_window))pointer_anchor_window=0;
            for(auto it=windows.begin();it!=windows.end();) {
                if(!ids.contains(it->first)){if(it->second->drag_announced)send(it->first,vf::InputKind::proxy_drag,getpid(),0,static_cast<int>(it->second->native_address),static_cast<int>(it->second->native_address>>32));if(pointer_window==it->first)pointer_window=0;if(keyboard_window==it->first){send(it->first,vf::InputKind::release);keyboard_window=0;}it=windows.erase(it);}else ++it;
            }
            for(auto& [_,w]:windows) {
                xdg_toplevel_set_parent(w->top,w->tile.owner && windows.contains(w->tile.owner)?windows.at(w->tile.owner)->top:nullptr);
                draw(*w);
            }
            // Publish every decoded drag transition before a later queued frame
            // can replace it, including the first mapped frame after crossing.
            if(drag_transition_pending())synchronize_geometry();
        }
        if(pending.size()>16)throw std::runtime_error("reverse decoder produced no frames");
    }
    bool drag_transition_pending() const {
        return std::any_of(windows.begin(),windows.end(),[](const auto& item){
            const auto& w=*item.second;
            return w.drag_start_pending || w.drag_announced!=((w.tile.flags&1)!=0);
        });
    }
    void synchronize_geometry() {
        if(windows.empty())return;
        nlohmann::json clients,monitors;
        try {clients=nlohmann::json::parse(ipc("j/clients"));monitors=nlohmann::json::parse(ipc("j/monitors"));}
        catch(const std::exception& error){std::fprintf(stderr,"reverse geometry inventory retry: %s\n",error.what());return;}
        std::uint64_t local_drag_window=0;
        std::optional<bool> buttons_held;
        try {
            const auto status=nlohmann::json::parse(ipc("repl return hl.plugin.viewflow.capture_status()"));
            local_drag_window=status.value("native_drag_window",std::uint64_t{});
            if(status.contains("held_buttons")) {
                const auto& held=status.at("held_buttons");
                buttons_held=held.is_boolean()?held.get<bool>():held.get<int>()!=0;
            }
        } catch(const std::exception&) {} // Older plugins retain receipt-based synchronization.
        if(local_titlebar_window && windows.contains(local_titlebar_window)) {
            if(local_drag_window==windows.at(local_titlebar_window)->native_address) {
                if(!local_titlebar_seen)std::fprintf(stderr,"Mac titlebar local active id=%llu\n",static_cast<unsigned long long>(local_titlebar_window));
                local_titlebar_seen=true;
            }
            else if(local_titlebar_seen || (buttons_held && !*buttons_held)) {
                std::fprintf(stderr,"Mac titlebar local end id=%llu\n",static_cast<unsigned long long>(local_titlebar_window));
                local_titlebar_window=0;local_titlebar_seen=false;
            }
        }
        for(const auto& client:clients) {
            const auto name=client.value("class",std::string{});if(!name.starts_with("ViewflowReverse-") || !client.value("mapped",false) || client.value("pid",0)!=getpid())continue;
            std::uint64_t id{};try{id=std::stoull(name.substr(name.find_last_of('-')+1));}catch(...){continue;}
            auto found=windows.find(id);if(found==windows.end())continue;auto& w=*found->second;
            const auto address=client.at("address").get<std::string>();
            if(!address.starts_with("0x") || address.size()>18 || address.find_first_not_of("0123456789abcdefABCDEF",2)!=std::string::npos)throw std::runtime_error("invalid local Hyprland address");
            w.native_address=std::stoull(address,nullptr,16);
            if(!w.ime_popup() && (w.tile.flags&vf::backdrop_capability)) {
                const auto sx=static_cast<int32_t>(std::lround(double(w.tile.x)*1000/scale));
                const auto sy=static_cast<int32_t>(std::lround(double(w.tile.y)*1000/scale));
                if(w.backdrop)w.backdrop->update(sx,sy);
                else try {
                    w.backdrop=std::make_unique<vf::BackdropClient>(w.id,w.native_address,sx,sy,[this](std::vector<uint8_t> bytes){
                        vf::Writer prefix;prefix.u32(static_cast<uint32_t>(bytes.size()));
                        std::lock_guard lock(output_mutex);write_all(STDOUT_FILENO,prefix.bytes);write_all(STDOUT_FILENO,bytes);
                    });
                } catch(const std::exception& error){std::fprintf(stderr,"popup backdrop setup retry: %s\n",error.what());}
            } else w.backdrop.reset();
            const int x=client.at("at").at(0),y=client.at("at").at(1),width=client.at("size").at(0),height=client.at("size").at(1);
            const int target_x=static_cast<int>(std::lround(double(w.tile.x)/scale))+origin_x,target_y=static_cast<int>(std::lround(double(w.tile.y)/scale))+origin_y;
            const int target_width=vf::logical_width(w.tile,scale),target_height=vf::logical_height(w.tile,scale);
            // A new surface can inherit the focused workspace on another
            // output. Assign its initial workspace from the remote rectangle,
            // without following it or overriding later user workspace moves.
            bool refresh_workspace=false;
            if(!w.placed) {
                for(const auto& monitor:monitors) {
                    const double monitor_scale=monitor.value("scale",1.0);
                    const bool rotated=monitor.value("transform",0)%2!=0;
                    const double mx=monitor.at("x"),my=monitor.at("y");
                    const double mw=monitor.at(rotated?"height":"width").get<double>()/monitor_scale;
                    const double mh=monitor.at(rotated?"width":"height").get<double>()/monitor_scale;
                    const double cx=target_x+target_width/2.0,cy=target_y+target_height/2.0;
                    if(cx<mx || cy<my || cx>=mx+mw || cy>=my+mh)continue;
                    const int workspace=monitor.at("activeWorkspace").at("id");
                    if(workspace!=client.at("workspace").at("id").get<int>()) {
                        try {
                            eval("hl.dispatch(hl.dsp.window.move({workspace="+std::to_string(workspace)+",follow=false,window='address:"+address+"'}))");
                        } catch(const std::exception& error) {
                            std::fprintf(stderr,"reverse initial workspace retry: %s\n",error.what());
                            refresh_workspace=true;
                            break;
                        }
                        // Moving workspace can translate coordinates; refresh
                        // the client inventory before geometry synchronization.
                        refresh_workspace=true;
                        break;
                    }
                    break;
                }
            }
            if(refresh_workspace)continue;
            // no_initial_focus can suppress the initial xdg fullscreen request.
            // Reconcile after mapping, using the exact proxy rather than focus.
            if (w.fullscreen_pending) {
                const bool actual_fullscreen=client.value("fullscreen",0)==2;
                if (actual_fullscreen!=w.source_fullscreen) {
                    try {
                        eval("hl.dispatch(hl.dsp.window.fullscreen({mode='fullscreen',action='"+
                             std::string(w.source_fullscreen?"set":"unset")+"',layout_aware=false,window='address:"+address+"'}))");
                    } catch(const std::exception& error) {
                        std::fprintf(stderr,"reverse fullscreen retry id=%llu: %s\n",(unsigned long long)id,error.what());
                    }
                    continue; // Confirm with fresh compositor inventory.
                }
                w.fullscreen_pending=false;
                std::fprintf(stderr,"Mac fullscreen confirmed id=%llu state=%u\n",(unsigned long long)id,unsigned(actual_fullscreen));
            }
            // Fullscreen size belongs to the Linux output. Never send it back
            // as an AX resize, or apply the Mac display size over the compositor.
            // Wait through exit until the compositor has restored normal geometry.
            if (w.source_fullscreen || client.value("fullscreen",0) != 0) { w.placed=true; continue; }
            // xdg window geometry and compositor inventory describe the body;
            // captured shadow padding belongs only to the underlying surface.
            const int body_width=width,body_height=height;
            const vf::Geometry local{x,y,width,height},remote{target_x,target_y,target_width,target_height};
            const auto action=w.ime_popup()?(local==remote?vf::GeometryAction::none:vf::GeometryAction::apply_remote):w.geometry_sync.observe(local,remote,w.tile.geometry_ack,client.value("floating",false),local_drag_window==w.native_address || local_titlebar_window==id);
            if(action==vf::GeometryAction::send_local) {
                if(!held_super.empty() && !super_drag){super_drag=true;pending_super.clear();send(id,vf::InputKind::release);}
                auto backing=vf::Geometry{x,y,body_width,body_height};
                if(!client.value("floating",false)) {
                    for(const auto& monitor:monitors) {
                        if(monitor.value("id",-1)!=client.value("monitor",-2))continue;
                        const double monitor_scale=monitor.value("scale",1.0);
                        const bool rotated=monitor.value("transform",0)%2!=0;
                        const int mw=monitor.at(rotated?"height":"width"),mh=monitor.at(rotated?"width":"height");
                        backing=vf::tiled_backing_geometry(backing,{monitor.at("x"),monitor.at("y"),
                            static_cast<int>(std::lround(mw/monitor_scale)),static_cast<int>(std::lround(mh/monitor_scale))});
                        break;
                    }
                }
                w.geometry_sync.sent(send(id,vf::InputKind::geometry,(backing.x-origin_x)*scale,(backing.y-origin_y)*scale,body_width*scale,body_height*scale));
            } else if(action==vf::GeometryAction::apply_remote) {
                const std::string selector="'address:"+address+"'";
                try {
                eval("hl.dispatch(hl.dsp.window.resize({x="+std::to_string(target_width)+",y="+std::to_string(target_height)+",window="+selector+"}));hl.dispatch(hl.dsp.window.move({x="+std::to_string(target_x)+",y="+std::to_string(target_y)+",window="+selector+"}))");
                } catch(const std::exception& error) {
                    std::fprintf(stderr,"reverse geometry retry id=%llu: %s\n",static_cast<unsigned long long>(id),error.what());
                    continue;
                }
                w.geometry_sync.applied(remote);
            }
            const bool reveal=!w.placed;
            w.placed=true;
            if(reveal && w.ime_popup()){w.alpha_revision=0;draw(w);std::fprintf(stderr,"popup first-visible id=%llu at=%d,%d\n",(unsigned long long)id,target_x,target_y);}
            const bool native_drag=w.drag_start_pending || (w.tile.flags&1)!=0;
            if(w.placed && w.drag_announced!=native_drag) {
                if(native_drag && w.drag_has_anchor)send(id,vf::InputKind::proxy_drag_anchor,
                    static_cast<int>(std::lround(double(w.drag_grab_x)*1000/scale)),
                    static_cast<int>(std::lround(double(w.drag_grab_y)*1000/scale)),getpid());
                send(id,vf::InputKind::proxy_drag,getpid(),native_drag,static_cast<int>(w.native_address),static_cast<int>(w.native_address>>32));
                w.drag_announced=native_drag;
                w.drag_start_pending=false;
            }
        }
    }
    void reader() {
        try {
            while(running) {
                std::uint8_t prefix[4];if(!read_all(STDIN_FILENO,prefix,4))break;
                vf::Reader length{{prefix,4}};const auto size=length.u32();if(size>vf::max_record || size<32)throw std::runtime_error("reverse frame record size");
                std::vector<std::uint8_t> bytes(size);if(!read_all(STDIN_FILENO,bytes.data(),size))break;
                auto frame=vf::unpack_frame(bytes);
                std::unique_lock lock(queue_mutex);queue_changed.wait(lock,[&]{return queue.size()<2 || !running;});if(!running)break;queue.push_back(std::move(frame));lock.unlock();
                const std::uint64_t one=1;::write(wake,&one,sizeof(one));
            }
        }catch(const std::exception& error){std::fprintf(stderr,"reverse reader: %s\n",error.what());}
        input_done=true;const std::uint64_t one=1;::write(wake,&one,sizeof(one));
    }
    void run() {
        // NativeTouchpadEncoder admits only two contacts and never
        // sends physical buttons. Single-finger motion/clicks stay on Wayland.
        if(!validate_only)touchpad=viewflow::hyprland::TouchpadCapture::discover();
        if(mac_shadow)std::fprintf(stderr,"Mac proxy native HID physical touchpad=%s; remote capability required\n",touchpad && touchpad->available()?"available":"unavailable (wheel fallback)");
        std::thread receiver([&]{reader();});auto geometry_at=Clock::now();
        try {
            while(running) {
                if(wl_display_dispatch_pending(display)<0)break;
                repeat_keys();
                drain_touchpad();
                std::optional<vf::Frame> frame;
                {std::lock_guard lock(queue_mutex);if(!queue.empty()){frame=std::move(queue.front());queue.pop_front();queue_changed.notify_all();}}
                if(frame)accept(std::move(*frame));
                if(!frame && input_done)break;
                for(auto& [_,w]:windows)if(w->configured && !w->native)draw(*w);
                if(Clock::now()>=geometry_at || drag_transition_pending()){synchronize_geometry();geometry_at=Clock::now()+std::chrono::milliseconds(local_titlebar_window?16:33);}
                while(wl_display_prepare_read(display)!=0)if(wl_display_dispatch_pending(display)<0)throw std::runtime_error("Wayland dispatch failed");
                wl_display_flush(display);
                pollfd fds[]={{wl_display_get_fd(display),POLLIN,0},{wake,POLLIN,0},{touchpad?touchpad->fd():-1,POLLIN,0}};
                const int status=poll(fds,3,frame?0:8);
                if(status<0 && errno!=EINTR){wl_display_cancel_read(display);break;}
                if(fds[0].revents&POLLIN){if(wl_display_read_events(display)<0)break;}else wl_display_cancel_read(display);
                if(fds[1].revents&POLLIN){std::uint64_t value;::read(wake,&value,sizeof(value));}
            }
        }catch(...){running=false;queue_changed.notify_all();pthread_cancel(receiver.native_handle());receiver.join();throw;}
        running=false;queue_changed.notify_all();pthread_cancel(receiver.native_handle());receiver.join();
        send(0,vf::InputKind::release);
    }
};
std::string Window::app_id() const {return std::string(ime_popup()?"ViewflowReverse-IME-":app->mac_shadow?((tile.flags&16)?"ViewflowReverse-MacNative-":"ViewflowReverse-Mac-"):"ViewflowReverse-")+std::to_string(id);}
Window::~Window() {
    backdrop.reset();
    if(egl!=EGL_NO_SURFACE){eglMakeCurrent(app->egl_display,app->pbuffer,app->pbuffer,app->context);eglDestroySurface(app->egl_display,egl);}
    if(native)wl_egl_window_destroy(native);if(viewport)wp_viewport_destroy(viewport);if(top)xdg_toplevel_destroy(top);if(shell)xdg_surface_destroy(shell);if(surface)wl_surface_destroy(surface);
}
}
int main(int argc,char** argv) {
    signal(SIGPIPE,SIG_IGN);
    try {App app;if(argc==2 && std::strcmp(argv[1],"--validate")==0)app.validate_only=true;if(argc==4){app.origin_x=std::stoi(argv[1]);app.origin_y=std::stoi(argv[2]);app.scale=std::stoi(argv[3]);if(app.scale<1 || app.scale>4)throw std::runtime_error("invalid reverse scale");}app.start();app.run();return 0;}
    catch(const std::exception& error){std::fprintf(stderr,"reverse presenter: %s\n",error.what());return 1;}
}

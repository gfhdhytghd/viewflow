#include "../reverse-common/diagnostics.hpp"
#include "../reverse-common/fixture_stamp.hpp"
#include "../reverse-common/activity_hint.hpp"
#include "../reverse-common/activity_presentation.hpp"
#include "../reverse-common/activity_frame_queue.hpp"
#include "../reverse-common/activity_feedback.hpp"
#include "../reverse-common/activity_input.hpp"
#include "backdrop_client.hpp"
#include "gpu_decoder.hpp"
#include "bgra_alpha.hpp"
#include "alpha_upload_overlap.hpp"
#include "gpu_alpha.hpp"
#include "presentation_timing.hpp"
#include "retained_surface.hpp"
#include "retained_shaders.hpp"
#include "desktop_output.hpp"
#include "shared_mapping.hpp"
#include "workspace_visibility.hpp"
#include "../reverse-common/wire.hpp"
#include "../reverse-common/native_touchpad.hpp"
#include "../reverse-common/window_surface.hpp"
#include "../reverse-common/window_resize.hpp"
#include "../reverse-common/shadow_corner.hpp"
#include "../reverse-common/window_residency.hpp"
#include "../hyprland-plugin/src/touchpad_capture.hpp"
#include "../reverse-common/geometry_sync.hpp"
#include "../reverse-common/fullscreen_backing.hpp"
#include "xdg-shell-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-toplevel-icon-v1-client-protocol.h"
#include <png.h>
#include <filesystem>
#include <fstream>
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
#include <ctime>
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
void trace_host_frame(const char* stage,std::int64_t pts) {
    if(!std::getenv("VIEWFLOW_HOST_FRAME_TRACE"))return;
    timespec now{};if(clock_gettime(CLOCK_MONOTONIC,&now)!=0)return;
    const auto ns=std::uint64_t(now.tv_sec)*1'000'000'000+now.tv_nsec;
    vf_diag::trace("ivshmem-host-frame stage=%s pts=%lld monotonic_ns=%llu\n",stage,static_cast<long long>(pts),static_cast<unsigned long long>(ns));
}
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
    if(std::getenv("VIEWFLOW_REVERSE_TRACE_DISPATCH"))std::fprintf(stderr,"reverse dispatch: %s\n",expression.c_str());
    auto result=ipc("/eval "+expression);
    if(result.find("error")!=std::string::npos || result.find("Error")!=std::string::npos)throw std::runtime_error("Hyprland reverse geometry: "+result);
}
struct App;
// Mac native tiles use logical points; Windows native tiles retain physical
// body dimensions. The receiver scale applies only to the latter.
int receiver_body_width(const vf::Tile& tile,unsigned scale,bool mac) {
    return (tile.flags&16) ? (mac?int(tile.logical_width):int((tile.logical_width+scale-1)/scale)) : vf::logical_width(tile,scale);
}
int receiver_body_height(const vf::Tile& tile,unsigned scale,bool mac) {
    return (tile.flags&16) ? (mac?int(tile.logical_height):int((tile.logical_height+scale-1)/scale)) : vf::logical_height(tile,scale);
}
vf::SurfaceGeometry receiver_surface(const vf::Tile& tile,int width,int height,bool mac) {
    (void)tile;(void)mac;return vf::body_surface(width,height);
}
std::pair<int,int> shell_popup_position(int guest_x,int guest_y,const vf::Tile& owner,int host_x,int host_y,unsigned scale) {
    return {host_x+static_cast<int>(std::lround((double(guest_x)-owner.x)/scale)),
            host_y+static_cast<int>(std::lround((double(guest_y)-owner.y)/scale))};
}
void padded_geometry_self_test() {
    vf::Tile tile;tile.flags=16;tile.width=960;tile.height=700;tile.body_x=48;tile.body_y=32;
    tile.body_width=800;tile.body_height=600;tile.logical_width=800;tile.logical_height=600;tile.pixel_scale=1;
    const int width=receiver_body_width(tile,2,false),height=receiver_body_height(tile,2,false);
    const auto surface=receiver_surface(tile,width,height,false);
    if(width!=400 || height!=300 || surface.width!=400 || surface.height!=300 || surface.x!=0 || surface.y!=0 ||
        surface.body_width!=400 || surface.body_height!=300 || vf::body_point(surface,400,300) || !vf::body_point(surface,399,299))
        throw std::runtime_error("Windows padded geometry mismatch");
    if(receiver_body_width(tile,2,true)!=800 || receiver_surface(tile,400,300,true).x!=0 || receiver_surface(tile,400,300,true).width!=400)
        throw std::runtime_error("Mac native body semantics changed");
    // Body geometry sent by the existing local->source path remains physical.
    if(width*2!=int(tile.logical_width) || height*2!=int(tile.logical_height))throw std::runtime_error("Windows geometry scale mismatch");
    vf::Tile shell;shell.x=2218;shell.y=1601;
    if(shell_popup_position(2318,1781,shell,38,56,2)!=std::pair{88,146} ||
       shell_popup_position(2118,1561,shell,-1000,-200,2)!=std::pair{-1050,-220} ||
       shell_popup_position(2318,1781,shell,38,56,1)!=std::pair{138,236})
        throw std::runtime_error("Shell IME crop/scale/negative-origin mismatch");
    std::fprintf(stderr,"reverse padded geometry and shell IME self-test passed; no display or input\n");
}
struct Window {
    App* app{};std::uint64_t id{};vf::Tile tile;
    std::unique_ptr<vf::BackdropClient> backdrop;
    std::string source_app_id, icon_name;std::vector<uint8_t> icon_png;
    std::vector<std::filesystem::path> icon_entries;
    wl_surface* surface{};xdg_surface* shell{};xdg_toplevel* top{};wp_viewport* viewport{};
    wl_egl_window* native{};EGLSurface egl{EGL_NO_SURFACE};
    bool configured{},placed{},workspace_assigned{},source_fullscreen{},fullscreen_pending{};vf::GeometrySync geometry_sync;vf::FullscreenBacking fullscreen_backing;vf::FullscreenRouteControl fullscreen_route;
    vf::WindowResize resize;
    int logical_width{},logical_height{},region_width{},region_height{};bool desktop_region{},snapshot_desktop_output{};
    std::optional<std::array<int,8>> committed_surface_geometry;
    std::int32_t drag_grab_x{},drag_grab_y{};bool drag_has_anchor{};
    std::optional<unsigned> shadow_corner;std::uint64_t shadow_alpha_revision{};std::array<unsigned,12> shadow_geometry{};
    std::uint64_t alpha_revision{},native_address{};std::array<unsigned,12> alpha_rect{};std::optional<vf::PixelRect> residency;unsigned residency_width{},residency_height{};bool drag_announced{},drag_start_pending{};
    unsigned media_lane{},media_width{},media_height{};
    vf::DecodedFrame pixels,snapshot_frame;
    vf::RetainedSurface snapshot;vf::RetainedAlpha snapshot_alpha;
    std::uint64_t snapshot_revision{};
    std::shared_ptr<const std::vector<std::uint8_t>> media_alpha;
    std::uint64_t media_alpha_revision{},media_alpha_generation{};
    ~Window();
    bool ime_popup() const {return (tile.flags&2)!=0;}
    std::string app_id() const;
};
struct App {
    wl_display* display{};wl_registry* registry{};wl_compositor* compositor{};xdg_wm_base* wm{};
    wl_subcompositor* subcompositor{};
    wl_shm* shm{};xdg_toplevel_icon_manager_v1* icon_manager{};
    wp_viewporter* viewporter{};wl_seat* seat{};wl_pointer* pointer{};wl_keyboard* keyboard{};
    EGLDisplay egl_display{EGL_NO_DISPLAY};EGLConfig config{};EGLContext context{EGL_NO_CONTEXT};EGLSurface pbuffer{EGL_NO_SURFACE};
    struct DecodeLane {
        std::unique_ptr<vf::GpuDecoder> decoder,progressive_decoder;
        std::optional<vf::Frame> progressive_frame;
        GLuint alpha_texture{};unsigned codec{},atlas_width{},atlas_height{};
        std::map<std::int64_t,vf::Frame> pending;
        std::vector<std::uint8_t> encoded_alpha;
        std::shared_ptr<const std::vector<std::uint8_t>> latest_alpha;
        std::array<std::shared_ptr<std::vector<std::uint8_t>>,3> raw_alpha_buffers;unsigned next_alpha_buffer{};
        std::uint64_t alpha_revision{};vf::GpuAlpha gpu_alpha;bool gpu_alpha_disabled{};
        vf::GpuAlphaAsync async_alpha;bool async_alpha_disabled{},desktop_only{};
        std::vector<std::uint64_t> alpha_layout;
        std::uint64_t alpha_generation{},alpha_version{},alpha_applied_version{},alpha_job_generation{},alpha_submitted_version{};
        vf::DecodedFrame uploaded;
        std::shared_ptr<const std::vector<std::uint8_t>> uploaded_alpha;
        unsigned uploaded_width{},uploaded_height{};
    };
    std::unique_ptr<vf::AlphaUploadOverlap> alpha_upload_overlap;bool alpha_overlap_unavailable{};
    std::shared_ptr<vf::RawUploadCache> upload_cache=vf::GpuDecoder::make_upload_cache();
    DecodeLane lanes[2];GLuint program{};vf::PresentationTiming presentation;
    std::optional<vf::Frame> raw_ready[2];
    bool progressive_enabled{};
    std::string shared_memory_path=std::getenv("VIEWFLOW_IVSHMEM")?std::getenv("VIEWFLOW_IVSHMEM"):"";
    viewflow::activity::Presentation activity_presentation;
    std::map<std::uint64_t,std::unique_ptr<Window>> windows;
    std::unique_ptr<viewflow::hyprland::TouchpadCapture> touchpad;
    std::uint64_t touchpad_target{};
    bool windows_local_gesture{};
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
    viewflow::activity::FrameQueue activity_queues[2];
    Clock::time_point last_background{};
    ~App() {
        windows.clear();for(auto& lane:lanes){lane.progressive_decoder.reset();lane.progressive_frame.reset();lane.uploaded.reset();lane.decoder.reset();lane.gpu_alpha.reset();lane.async_alpha.reset();if(lane.alpha_texture)glDeleteTextures(1,&lane.alpha_texture);}
        if(key_map)xkb_keymap_unref(key_map);if(key_context)xkb_context_unref(key_context);
        if(egl_display!=EGL_NO_DISPLAY){eglMakeCurrent(egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);if(pbuffer!=EGL_NO_SURFACE)eglDestroySurface(egl_display,pbuffer);if(context!=EGL_NO_CONTEXT)eglDestroyContext(egl_display,context);eglTerminate(egl_display);}
        if(keyboard)wl_keyboard_release(keyboard);if(pointer)wl_pointer_release(pointer);if(seat)wl_seat_release(seat);
        if(viewporter)wp_viewporter_destroy(viewporter);if(wm)xdg_wm_base_destroy(wm);if(compositor)wl_compositor_destroy(compositor);
        if(icon_manager)xdg_toplevel_icon_manager_v1_destroy(icon_manager);if(shm)wl_shm_destroy(shm);
        presentation.reset();
        if(registry)wl_registry_destroy(registry);if(display)wl_display_disconnect(display);if(wake>=0)close(wake);
    }
    std::mutex output_mutex;
    void interaction(std::uint64_t window,bool active){
        if(!window || !viewflow::activity::negotiated())return;
        const auto bytes=viewflow::activity::pack_hint({window,1,active});vf::Writer prefix;prefix.u32(bytes.size());
        std::lock_guard lock(output_mutex);write_all(STDOUT_FILENO,prefix.bytes);write_all(STDOUT_FILENO,bytes);
    }
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
                if(frame.count>=3) {
                    if(!windows_local_gesture)send(target,vf::InputKind::touchpad_frame,frame.width,frame.height,0);
                    windows_local_gesture=true;
                    return;
                }
                if(windows_local_gesture) {
                    if(!frame.count)windows_local_gesture=false;
                    return;
                }
                for(unsigned i=0;i<frame.count;++i){const auto& c=frame.contacts[i];send(target,vf::InputKind::touchpad_contact,c.id,c.x,c.y);}
                send(target,vf::InputKind::touchpad_frame,frame.width,frame.height,frame.count);
            }
        });
    }
    std::uint64_t identify(wl_surface* surface) {for(auto& [id,w]:windows)if(w->surface==surface)return id;return 0;}
    vf::SurfaceGeometry content_surface(const Window& window) const {
        return mac_shadow?vf::fitted_body(window.logical_width,window.logical_height,
            window.snapshot.width(),window.snapshot.height()):vf::body_surface(window.logical_width,window.logical_height);
    }
    void forward_pointer(bool begin_drag=false) {
        if(!pointer_window || local_titlebar_window)return;
        const auto& window=*windows.at(pointer_window);
        if((window.tile.flags&vf::windows_shell_flag) || window.fullscreen_backing.active) {
            // Fullscreen backing keeps its guest origin and uses output pixels,
            // which need not match the global host-to-guest desktop scale.
            // Keep this mapping until the restored backing is acknowledged.
            const auto surface=receiver_surface(window.tile,window.logical_width,window.logical_height,mac_shadow);
            const auto source_width=(window.tile.flags&16)?window.tile.logical_width:window.tile.width;
            const auto source_height=(window.tile.flags&16)?window.tile.logical_height:window.tile.height;
            send(pointer_window,vf::InputKind::pointer,
                int(std::lround(vf::body_pointer(pointer_x,surface.x,window.logical_width,source_width,window.tile.x,1))),
                int(std::lround(vf::body_pointer(pointer_y,surface.y,window.logical_height,source_height,window.tile.y,1))),1);
            return;
        }
        if(mac_shadow) {
            const auto content=content_surface(window);
            if(!content.body_width || !content.body_height)return;
            if(forwarded_buttons.empty() && !vf::body_point(content,pointer_x,pointer_y))return;
            if(begin_drag) {
                const auto position=nlohmann::json::parse(ipc("j/cursorpos"));
                pointer_anchor_x.desktop=position.at("x").get<double>();
                pointer_anchor_y.desktop=position.at("y").get<double>();
            }
            // Wayland positions already exclude compositor gaps and borders.
            // Body-local pixels carry their own frame extent through resize lag.
            send(pointer_window,vf::InputKind::pointer,
                int(std::lround((pointer_x-content.x)*window.snapshot.width()/content.body_width)),
                int(std::lround((pointer_y-content.y)*window.snapshot.height()/content.body_height)),0,
                vf::pointer_extent(window.snapshot.width(),window.snapshot.height()));
            return;
        }
        // Surface coordinates are relative to a moving proxy. Resolve the actual
        // desktop pointer, so a delayed Windows position never adds drag motion twice.
        const auto position=nlohmann::json::parse(ipc("j/cursorpos"));
        if(begin_drag) {
            pointer_anchor_window=pointer_window;
            pointer_anchor_x.desktop=position.at("x").get<double>();
            pointer_anchor_y.desktop=position.at("y").get<double>();
        }
        send(pointer_window,vf::InputKind::pointer,
            static_cast<int>(std::lround((position.at("x").get<double>()-origin_x)*scale)),
            static_cast<int>(std::lround((position.at("y").get<double>()-origin_y)*scale)),1);
    }
    static void pointer_enter(void* data,wl_pointer*,std::uint32_t,wl_surface* surface,wl_fixed_t x,wl_fixed_t y) {
        auto& a=*static_cast<App*>(data);a.pointer_window=a.identify(surface);a.pointer_x=wl_fixed_to_double(x);a.pointer_y=wl_fixed_to_double(y);
        if(a.pointer_window && (a.windows.at(a.pointer_window)->tile.flags&vf::windows_shell_flag))
            std::fprintf(stderr,"reverse-shell-pointer-enter id=%llu local=%.1f,%.1f\n",(unsigned long long)a.pointer_window,a.pointer_x,a.pointer_y);
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
                a.interaction(a.local_titlebar_window,false);a.local_titlebar_window=0;a.local_titlebar_seen=false;
            }
            auto held=a.forwarded_buttons.find(button);
            if(held!=a.forwarded_buttons.end()) {
                a.send(held->second,vf::InputKind::button,static_cast<int>(button),0);
                a.forwarded_buttons.erase(held);
            }
            if(a.forwarded_buttons.empty())a.pointer_anchor_window=0;
            return;
        }
        // Native two-finger HID already produces the secondary click/tap.
        // Forwarding libinput's BTN_RIGHT as well opens then dismisses menus.
        // Releases above still finish a button admitted before HID was ready.
        if(button==273 && a.mac_shadow && a.touchpad && a.touchpad->available() && a.hid_ready())return;
        if(!a.windows.contains(a.pointer_window))return;
        const auto& window=*a.windows.at(a.pointer_window);
        if(!vf::body_point(a.content_surface(window),a.pointer_x,a.pointer_y))return;
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
            if(button==272 && !window.ime_popup() && window.placed &&
               (!window.geometry_sync.pending || window.tile.geometry_ack>=window.geometry_sync.pending)) {
                a.native_move_candidate=window.id;a.native_move_serial=serial;
                a.native_move_grab_x=a.pointer_anchor_x.desktop-window.geometry_sync.observed.x;
                a.native_move_grab_y=a.pointer_anchor_y.desktop-window.geometry_sync.observed.y;
                a.native_move_confirmation.begin({window.tile.x,window.tile.y,
                    static_cast<int>((window.tile.flags&16)?window.tile.logical_width:window.tile.width),
                    static_cast<int>((window.tile.flags&16)?window.tile.logical_height:window.tile.height)},window.tile.geometry_ack);
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
        if(!native_move_confirmation.observe({tile.x,tile.y,static_cast<int>((tile.flags&16)?tile.logical_width:tile.width),
                static_cast<int>((tile.flags&16)?tile.logical_height:tile.height)},tile.geometry_ack))return;
        // Align the proxy to the original physical grab point, rather than
        // preserving the offset introduced by the first delayed source frame.
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
        native_move_candidate=0;local_titlebar_window=window.id;local_titlebar_seen=false;interaction(window.id,true);
        xdg_toplevel_move(window.top,seat,native_move_serial);
        wl_display_flush(display);
        window.geometry_sync.sent(send(window.id,vf::InputKind::geometry,
            (local.x-origin_x)*scale,(local.y-origin_y)*scale,local.width*scale,local.height*scale));
        std::fprintf(stderr,"Remote titlebar local requested id=%llu\n",static_cast<unsigned long long>(window.id));
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
    static void icon_size(void*,xdg_toplevel_icon_manager_v1*,int32_t){}
    static void icon_done(void*,xdg_toplevel_icon_manager_v1*){}
    static constexpr xdg_toplevel_icon_manager_v1_listener icon_listener={icon_size,icon_done};
    void apply_icon(Window& window,const vf::Tile& tile,bool app_id_changed) {
        const bool changed=(tile.flags&vf::application_icon_flag) && window.icon_png!=tile.icon_png;
        if(changed){window.icon_png=tile.icon_png;window.source_app_id=tile.app_id;}
        if(window.icon_png.empty() || (!changed && !app_id_changed))return;
        try {
            // Desktop entry fallback also supplies launchers which don't consume
            // the Wayland per-toplevel icon. Names contain only locally generated IDs.
            uint64_t hash=0xcbf29ce484222325ULL;for(auto byte:window.icon_png)hash=(hash^byte)*0x100000001b3ULL;
            window.icon_name="viewflow-remote-"+std::to_string(hash);
            const char* xdg=std::getenv("XDG_DATA_HOME");const char* home=std::getenv("HOME");
            if(xdg || home) {
                const auto data=xdg?std::filesystem::path(xdg):std::filesystem::path(home)/".local/share";
                const auto icons=data/"icons/hicolor/128x128/apps";const auto apps=data/"applications";
                std::filesystem::create_directories(icons);std::filesystem::create_directories(apps);
                const auto png=icons/(window.icon_name+".png");
                if(!std::filesystem::exists(png)){std::ofstream out(png,std::ios::binary);out.write(reinterpret_cast<const char*>(window.icon_png.data()),window.icon_png.size());}
                const auto entry=apps/(window.app_id()+".desktop");
                std::string title=tile.title;std::replace(title.begin(),title.end(),'\n',' ');std::replace(title.begin(),title.end(),'\r',' ');
                std::ofstream out(entry);out<<"[Desktop Entry]\nType=Application\nName="<<title<<"\nIcon="<<png.string()<<"\nNoDisplay=true\nStartupWMClass="<<window.app_id()<<"\n";
                if(std::find(window.icon_entries.begin(),window.icon_entries.end(),entry)==window.icon_entries.end())window.icon_entries.push_back(entry);
            }
            if(icon_manager && shm && changed) {
                png_image decoded{};decoded.version=PNG_IMAGE_VERSION;
                if(!png_image_begin_read_from_memory(&decoded,window.icon_png.data(),window.icon_png.size()))return;
                decoded.format=PNG_FORMAT_RGBA;std::vector<uint8_t> pixels(PNG_IMAGE_SIZE(decoded));
                if(!png_image_finish_read(&decoded,nullptr,pixels.data(),0,nullptr)){png_image_free(&decoded);return;}
                // Protocol requires square buffers. Center the original artwork.
                const unsigned size=std::max(decoded.width,decoded.height);const size_t bytes=size_t(size)*size*4;
                int fd=memfd_create("viewflow-window-icon",MFD_CLOEXEC);
                if(fd<0){png_image_free(&decoded);return;}
                if(ftruncate(fd,bytes)!=0){close(fd);png_image_free(&decoded);return;}
                auto* memory=static_cast<uint8_t*>(mmap(nullptr,bytes,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0));
                if(memory==MAP_FAILED){close(fd);png_image_free(&decoded);return;}
                memset(memory,0,bytes);
                for(unsigned y=0;y<decoded.height;++y)for(unsigned x=0;x<decoded.width;++x){
                    const auto* p=&pixels[(size_t(y)*decoded.width+x)*4];auto* q=memory+((size_t(y+(size-decoded.height)/2)*size)+x+(size-decoded.width)/2)*4;
                    q[0]=(unsigned(p[2])*p[3]+127)/255;q[1]=(unsigned(p[1])*p[3]+127)/255;q[2]=(unsigned(p[0])*p[3]+127)/255;q[3]=p[3];
                }
                auto* pool=wl_shm_create_pool(shm,fd,bytes);auto* buffer=wl_shm_pool_create_buffer(pool,0,size,size,size*4,WL_SHM_FORMAT_ARGB8888);
                auto* icon=xdg_toplevel_icon_manager_v1_create_icon(icon_manager);
                xdg_toplevel_icon_v1_set_name(icon,window.icon_name.c_str());xdg_toplevel_icon_v1_add_buffer(icon,buffer,1);
                xdg_toplevel_icon_manager_v1_set_icon(icon_manager,window.top,icon);
                xdg_toplevel_icon_v1_destroy(icon);wl_buffer_destroy(buffer);wl_shm_pool_destroy(pool);munmap(memory,bytes);close(fd);png_image_free(&decoded);
                wl_surface_commit(window.surface);
            }
            std::fprintf(stderr,"application-icon-applied window=%llu app=%s wayland=%u\n",static_cast<unsigned long long>(window.id),window.source_app_id.c_str(),unsigned(icon_manager!=nullptr));
        }catch(const std::exception& error){std::fprintf(stderr,"application icon: %s\n",error.what());}
    }
    static void global(void* data,wl_registry* registry,std::uint32_t id,const char* name,std::uint32_t version) {
        auto& a=*static_cast<App*>(data);
        if(std::strcmp(name,wl_compositor_interface.name)==0)a.compositor=static_cast<wl_compositor*>(wl_registry_bind(registry,id,&wl_compositor_interface,std::min(version,4u)));
        if(std::strcmp(name,wl_subcompositor_interface.name)==0)a.subcompositor=static_cast<wl_subcompositor*>(wl_registry_bind(registry,id,&wl_subcompositor_interface,1));
        else if(std::strcmp(name,xdg_wm_base_interface.name)==0){a.wm=static_cast<xdg_wm_base*>(wl_registry_bind(registry,id,&xdg_wm_base_interface,std::min(version,3u)));xdg_wm_base_add_listener(a.wm,&wm_listener,&a);}
        else if(std::strcmp(name,wl_shm_interface.name)==0)a.shm=static_cast<wl_shm*>(wl_registry_bind(registry,id,&wl_shm_interface,1));
        else if(std::strcmp(name,xdg_toplevel_icon_manager_v1_interface.name)==0){a.icon_manager=static_cast<xdg_toplevel_icon_manager_v1*>(wl_registry_bind(registry,id,&xdg_toplevel_icon_manager_v1_interface,1));xdg_toplevel_icon_manager_v1_add_listener(a.icon_manager,&icon_listener,&a);}
        else if(std::strcmp(name,wl_output_interface.name)==0)a.presentation.bind_output(registry,id,version);
        else if(std::strcmp(name,wp_presentation_interface.name)==0)a.presentation.bind(registry,id);
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
        const auto* vertex=vf::retained_vertex;const auto* fragment=vf::retained_fragment;
        auto compile=[](GLenum type,const char* source){const auto shader=glCreateShader(type);glShaderSource(shader,1,&source,nullptr);glCompileShader(shader);GLint okay{};glGetShaderiv(shader,GL_COMPILE_STATUS,&okay);if(!okay){char log[2048]{};glGetShaderInfoLog(shader,sizeof(log),nullptr,log);throw std::runtime_error(log);}return shader;};
        const auto vs=compile(GL_VERTEX_SHADER,vertex),fs=compile(GL_FRAGMENT_SHADER,fragment);
        program=glCreateProgram();glAttachShader(program,vs);glAttachShader(program,fs);glLinkProgram(program);glDeleteShader(vs);glDeleteShader(fs);
        GLint okay{};glGetProgramiv(program,GL_LINK_STATUS,&okay);if(!okay)throw std::runtime_error("reverse shader link failed");
        for(auto& lane:lanes){auto& alpha_texture=lane.alpha_texture;
        glGenTextures(1,&alpha_texture);glBindTexture(GL_TEXTURE_2D,alpha_texture);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
        }
        eval("hl.window_rule({name='viewflow-windows-reverse',match={class='^ViewflowReverse-.*$'},float=true,no_initial_focus=true,decorate=false,border_size=0,no_shadow=true,rounding=0,no_blur=true,no_anim=true})");
        // The compositor animates tiled layout goals locally; only the final
        // goal from j/clients is mirrored to Windows, never animation samples.
        eval("hl.window_rule({name='viewflow-windows-reverse-tiled-animation',match={class='^ViewflowReverse-.*$',float=false},no_anim=false})");
        // no_focus also removes pointer hit testing in Hyprland. Popups must
        // accept input outside their parent; no_initial_focus avoids focus theft.
        eval("hl.window_rule({name='viewflow-windows-reverse-ime',match={class='^ViewflowReverse-IME-.*$'},float=true,no_initial_focus=true,no_focus=true,decorate=false,border_size=0,no_shadow=true,rounding=0,no_blur=true,no_anim=true})");
        eval("hl.window_rule({name='viewflow-windows-native-decoration',match={class='^ViewflowReverse-WindowsNative-.*$'},decorate=true,border_size=0,no_shadow=true,rounding=0})");
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
        w->logical_width=receiver_body_width(tile,scale,mac_shadow);w->logical_height=receiver_body_height(tile,scale,mac_shadow);
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
    static std::vector<std::uint64_t> alpha_layout_key(const vf::Frame& frame) {
        std::vector<std::uint64_t> key{frame.width,frame.height,frame.codec,std::uint64_t(bool(frame.shared_bgra)),std::uint64_t(bool(frame.progressive_bgra))};
        for(const auto& t:frame.tiles) {
            const auto r=vf::resident_rect(t);
            key.insert(key.end(),{t.id,t.owner,t.flags,t.width,t.height,t.atlas_x,t.atlas_y,
                t.body_x,t.body_y,t.body_width,t.body_height,t.logical_width,t.logical_height,t.pixel_scale,
                r.x,r.y,r.width,r.height});
        }
        return key;
    }
    void update_alpha_metadata(Window& w,unsigned atlas_width,std::span<const uint8_t> alpha,bool same_source=false) {
        if(vf::desktop_output(w.tile)) {
            // A composed desktop is intrinsically opaque. Do not allocate or
            // scan a full-size CPU alpha plane for this tile.
            // Retain the prior WGC metadata until its replacement color draw
            // succeeds; draw() clears it when the DD snapshot is installed.
            return;
        }
        w.snapshot_alpha.update(atlas_width,w.tile,alpha,same_source);
    }
    bool update_shadow_metadata(Window& w,bool native_changed=false) {
        bool shadow_changed=false;
        const auto& tile=w.tile;
        if(vf::desktop_output(tile)!=w.snapshot_desktop_output)return false;
        const auto shadow_resident=vf::resident_rect(tile);
        const std::array<unsigned,12> shadow_geometry{tile.atlas_x,tile.atlas_y,tile.body_x,tile.body_y,tile.body_width,tile.body_height,tile.logical_width,tile.logical_height,shadow_resident.x,shadow_resident.y,shadow_resident.width,shadow_resident.height};
        if(w.snapshot_desktop_output) {
            shadow_changed=w.shadow_corner.has_value();w.shadow_corner.reset();
        } else if(!mac_shadow && (tile.flags&16) && (w.shadow_alpha_revision!=w.snapshot_alpha.revision || native_changed || w.shadow_geometry!=shadow_geometry)) {
            auto retained_tile=tile;retained_tile.atlas_x=retained_tile.atlas_y=retained_tile.body_x=retained_tile.body_y=0;
            retained_tile.width=retained_tile.body_width=w.snapshot_alpha.width;retained_tile.height=retained_tile.body_height=w.snapshot_alpha.height;
            retained_tile.flags&=~vf::resident_crop_flag;
            const auto corner=((tile.flags&vf::windows_popup_flag)?vf::popup_shadow_corner:vf::shadow_corner)(w.snapshot_alpha.width,retained_tile,w.snapshot_alpha.pixels,receiver_body_width(tile,scale,false),receiver_body_height(tile,scale,false));
            shadow_changed=corner!=w.shadow_corner;w.shadow_corner=corner;w.shadow_alpha_revision=w.snapshot_alpha.revision;w.shadow_geometry=shadow_geometry;
        }
        if(native_changed || shadow_changed)xdg_toplevel_set_app_id(w.top,w.app_id().c_str());
        return shadow_changed;
    }
    bool poll_async_alpha() {
        static const bool enabled=[] {const auto* value=std::getenv("VIEWFLOW_GPU_ALPHA_ASYNC");return value && std::strcmp(value,"1")==0;}();
        if(!enabled)return false;
        make_current(pbuffer);bool pending=false;
        for(unsigned index=0;index<2;++index) {
            auto& lane=lanes[index];
            if(lane.async_alpha_disabled)continue;
            try {
                if(auto result=lane.async_alpha.poll()) {
                    if(lane.alpha_job_generation==lane.alpha_generation && result->width==lane.atlas_width &&
                       result->height==lane.atlas_height && result->version>lane.alpha_applied_version && result->pixels) {
                        lane.alpha_applied_version=result->version;
                        if(result->changed) {
                            lane.latest_alpha=result->pixels;++lane.alpha_revision;
                            for(auto& [_,window]:windows) {
                                auto& w=*window;if(w.media_lane!=index || w.media_alpha_generation!=lane.alpha_generation)continue;
                                w.media_alpha=lane.latest_alpha;w.media_alpha_revision=lane.alpha_revision*2+index;
                                update_alpha_metadata(w,lane.atlas_width,*lane.latest_alpha,false);
                                if(update_shadow_metadata(w))apply_icon(w,w.tile,true);
                                region(w);
                                // Apply new input/shadow metadata using the retained
                                // displayed buffer; do not redraw an older color frame.
                                wl_surface_commit(w.surface);
                            }
                        }
                    }
                }
                if(lane.alpha_submitted_version && lane.alpha_version>lane.alpha_submitted_version && !lane.async_alpha.pending() && lane.decoder) {
                    if(lane.async_alpha.submit(lane.decoder->y_texture(),lane.atlas_width,lane.atlas_height,lane.alpha_version)) {
                        lane.alpha_submitted_version=lane.alpha_version;lane.alpha_job_generation=lane.alpha_generation;
                    }
                }
                pending=pending || lane.async_alpha.pending();
            }catch(const std::exception& error) {
                lane.async_alpha_disabled=true;lane.async_alpha.reset();lane.gpu_alpha.reset();
                std::fprintf(stderr,"GPU async alpha fallback=synchronous reason=%s\n",error.what());
            }
        }
        return pending;
    }
    void region(Window& window) {
        if(mac_shadow) {
            wl_surface_set_input_region(window.surface,nullptr);
            return; // Letterbox clicks are consumed locally by pointer_button.
        }
        if(window.snapshot_desktop_output) {
            const auto surface=receiver_surface(window.tile,window.logical_width,window.logical_height,mac_shadow);
            if(!window.desktop_region || window.region_width!=surface.width || window.region_height!=surface.height) {
                auto* rectangle=wl_compositor_create_region(compositor);
                wl_region_add(rectangle,surface.x,surface.y,surface.body_width,surface.body_height);
                wl_surface_set_input_region(window.surface,rectangle);wl_surface_set_opaque_region(window.surface,rectangle);
                wl_region_destroy(rectangle);window.desktop_region=true;
                window.region_width=surface.width;window.region_height=surface.height;
            }
            return;
        }
        if(window.desktop_region) {
            wl_surface_set_opaque_region(window.surface,nullptr);window.desktop_region=false;
            window.region_width=window.region_height=0;
        }
        if(window.snapshot_alpha.pixels.empty())return;
        const auto& latest_alpha=window.snapshot_alpha.pixels;const auto atlas_width=window.snapshot_alpha.width;
        const auto alpha_revision=window.snapshot_alpha.revision;
        auto t=vf::body_tile(window.tile);t.atlas_x=t.atlas_y=0;t.flags&=~vf::resident_crop_flag;
        const auto surface=receiver_surface(window.tile,window.logical_width,window.logical_height,mac_shadow);
        const auto resident=vf::resident_rect(window.tile);
        const std::array<unsigned,12> bounds{t.atlas_x,t.atlas_y,t.width,t.height,t.body_x,t.body_y,t.body_width,t.body_height,resident.x,resident.y,resident.width,resident.height};
        if(window.alpha_revision==alpha_revision && window.alpha_rect==bounds && window.region_width==surface.width && window.region_height==surface.height)return;
        window.alpha_revision=alpha_revision;window.alpha_rect=bounds;window.region_width=surface.width;window.region_height=surface.height;
        auto* region=wl_compositor_create_region(compositor);
        const auto add_region=[&](unsigned left,unsigned top,unsigned right){
            const int x0=std::max(surface.x,surface.x+int(std::uint64_t(left)*surface.body_width/t.width)),x1=std::min(surface.x+surface.body_width,surface.x+int((std::uint64_t(right)*surface.body_width+t.width-1)/t.width));
            const int y0=std::max(surface.y,surface.y+int(std::uint64_t(top)*surface.body_height/t.height)),y1=std::min(surface.y+surface.body_height,surface.y+int((std::uint64_t(std::min(top+scale,t.height))*surface.body_height+t.height-1)/t.height));
            if(x1>x0 && y1>y0)wl_region_add(region,x0,y0,x1-x0,y1-y0);
        };
        for(unsigned y=0;y<t.height;y+=scale) {
            unsigned start=0;bool inside=false;
            for(unsigned x=0;x<=t.width;x+=scale) {
                const bool opaque=x<t.width && vf::body_pixel(t,x,y) && vf::tile_alpha(atlas_width,t,latest_alpha,x,y)>8;
                if(opaque && !inside){start=x;inside=true;}
                if(!opaque && inside){add_region(start,y,x);inside=false;}
                if(x<t.width && x+scale>t.width){if(inside)add_region(start,y,t.width);break;}
            }
        }
        wl_surface_set_input_region(window.surface,region);wl_region_destroy(region);
    }
    void draw(Window& w) {
        const auto draw_started=Clock::now();const auto presentation_started=presentation.now();
        auto& lane=lanes[w.media_lane];auto& decoder=lane.decoder;
        const auto atlas_width=w.media_width,atlas_height=w.media_height;
        const auto alpha_texture=lane.alpha_texture;
        if(!decoder || !atlas_width || !w.pixels || !w.media_alpha)return;
        make_current(pbuffer);
        const auto& t=w.tile;const bool crop_body=(t.flags&16)!=0;
        const unsigned snapshot_width=crop_body?t.body_width:t.width,snapshot_height=crop_body?t.body_height:t.height;
        const auto update=vf::retained_update_rect(t);
        if(!w.snapshot.width() && (!update.width || !update.height))return;
        const bool resized=w.snapshot.bind(snapshot_width,snapshot_height);
        if((resized || w.snapshot_frame!=w.pixels) && (w.pixels->format!=AV_PIX_FMT_BGRA || w.pixels->data[0])) {
            if(update.width && update.height) {
                if(lane.uploaded!=w.pixels){decoder->upload(w.pixels);lane.uploaded=w.pixels;}
                if(w.pixels->format!=AV_PIX_FMT_BGRA && lane.uploaded_alpha!=w.media_alpha){
                    glActiveTexture(GL_TEXTURE2);glBindTexture(GL_TEXTURE_2D,alpha_texture);glPixelStorei(GL_UNPACK_ALIGNMENT,1);
                    if(lane.uploaded_width!=atlas_width || lane.uploaded_height!=atlas_height)
                        glTexImage2D(GL_TEXTURE_2D,0,GL_R8,atlas_width,atlas_height,0,GL_RED,GL_UNSIGNED_BYTE,w.media_alpha->data());
                    else glTexSubImage2D(GL_TEXTURE_2D,0,0,0,atlas_width,atlas_height,GL_RED,GL_UNSIGNED_BYTE,w.media_alpha->data());
                    lane.uploaded_alpha=w.media_alpha;lane.uploaded_width=atlas_width;lane.uploaded_height=atlas_height;
                }
                glEnable(GL_SCISSOR_TEST);
                glScissor(update.x,snapshot_height-update.y-update.height,update.width,update.height);
                glViewport(0,0,snapshot_width,snapshot_height);
                glDisable(GL_BLEND);glUseProgram(program);
                // Mac split_planes sends straight RGB; Wayland requires premultiplied RGBA.
                glUniform1i(glGetUniformLocation(program,"straight_alpha"),mac_shadow?1:0);
                glUniform1i(glGetUniformLocation(program,"raw_bgra"),w.pixels->format==AV_PIX_FMT_BGRA?1:0);
                glUniform1i(glGetUniformLocation(program,"desktop_opaque"),vf::desktop_output(t)?1:0);
                const GLuint textures[]={decoder->y_texture(),decoder->uv_texture(),alpha_texture};
                const char* names[]={"luma","chroma","opacity"};
                for(unsigned i=0;i<3;++i){glActiveTexture(GL_TEXTURE0+i);glBindTexture(GL_TEXTURE_2D,textures[i]);glUniform1i(glGetUniformLocation(program,names[i]),i);}
                const auto resident=vf::resident_rect(t);
                glUniform4f(glGetUniformLocation(program,"tile"),float(t.atlas_x)/atlas_width,float(t.atlas_y)/atlas_height,1.f/atlas_width,1.f/atlas_height);
                glUniform4f(glGetUniformLocation(program,"resident"),resident.x,resident.y,resident.width,resident.height);
                glUniform4f(glGetUniformLocation(program,"body"),crop_body?t.body_x:0,crop_body?t.body_y:0,crop_body?t.body_width:t.width,crop_body?t.body_height:t.height);
                glDrawArrays(GL_TRIANGLES,0,3);
                glDisable(GL_SCISSOR_TEST);
                const bool desktop=vf::desktop_output(t);
                if(w.snapshot_desktop_output!=desktop) {
                    if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("desktop opacity snapshot draw failed");
                    // Commit semantic opacity only with a real replacement
                    // color snapshot, never from metadata alone. Subsequent
                    // surface commit/swap carries its matching input region.
                    w.snapshot_desktop_output=desktop;
                    if(desktop)w.snapshot_alpha={};
                    update_shadow_metadata(w,true);apply_icon(w,w.tile,true);
                }
            }
            if(resized || (update.width && update.height))++w.snapshot_revision;
            w.snapshot_frame=w.pixels;
        }
        glBindFramebuffer(GL_FRAMEBUFFER,0);
        if(!w.configured)return;
        const auto surface=receiver_surface(w.tile,w.logical_width,w.logical_height,mac_shadow);
        int buffer_width=surface.width*int(scale),buffer_height=surface.height*int(scale);
        if(w.fullscreen_backing.active && w.fullscreen_backing.fullscreen && w.fullscreen_backing.target) {
            // Different outputs can have different/fractional scales. Match
            // the actual output pixels instead of up/downsampling via the
            // session's ordinary desktop scale.
            buffer_width=w.fullscreen_backing.target->width;buffer_height=w.fullscreen_backing.target->height;
        }
        if(!w.native){w.native=wl_egl_window_create(w.surface,buffer_width,buffer_height);w.egl=eglCreateWindowSurface(egl_display,config,reinterpret_cast<EGLNativeWindowType>(w.native),nullptr);}
        if(w.egl==EGL_NO_SURFACE)throw std::runtime_error("reverse EGL window failed");
        const std::array<int,8> geometry{buffer_width,buffer_height,
            surface.width,surface.height,surface.x,surface.y,surface.body_width,surface.body_height};
        if(!w.committed_surface_geometry || *w.committed_surface_geometry!=geometry){
            wl_egl_window_resize(w.native,geometry[0],geometry[1],0,0);
            wp_viewport_set_destination(w.viewport,surface.width,surface.height);
            xdg_surface_set_window_geometry(w.shell,surface.x,surface.y,surface.body_width,surface.body_height);
            w.committed_surface_geometry=geometry;
        }
        make_current(w.egl);eglSwapInterval(egl_display,0);
        glViewport(0,0,buffer_width,buffer_height);
        if(w.ime_popup() && !w.placed) {
            wl_region* empty=wl_compositor_create_region(compositor);wl_surface_set_input_region(w.surface,empty);wl_region_destroy(empty);
            glClearColor(0,0,0,0);glClear(GL_COLOR_BUFFER_BIT);eglSwapBuffers(egl_display,w.egl);return;
        }
        region(w);
        if(mac_shadow) {
            const auto content=content_surface(w);
            w.snapshot.present(buffer_width,buffer_height,
                content.x*buffer_width/surface.width,content.y*buffer_height/surface.height,
                content.body_width*buffer_width/surface.width,content.body_height*buffer_height/surface.height);
        } else w.snapshot.present(buffer_width,buffer_height);
        // Diagnostic A/B only: distinguish queued client GPU work from the
        // compositor's presentation wait. Normal submission stays asynchronous.
        static const bool finish_before_swap=[] {const auto* value=std::getenv("VIEWFLOW_FINISH_BEFORE_SWAP");return value && std::string_view(value)=="1";}();
        if(finish_before_swap && w.pixels->format==AV_PIX_FMT_BGRA)glFinish();
        if(w.pixels->format==AV_PIX_FMT_BGRA)presentation.request(w.surface,presentation_started,w.pixels->pts,w.id);
        if(!eglSwapBuffers(egl_display,w.egl))throw std::runtime_error("reverse Wayland swap failed");
        // Send the surface commit before synchronous geometry IPC. A queued
        // Wayland request must not miss vblank while querying window placement.
        wl_display_flush(display);
        if(w.pixels->format==AV_PIX_FMT_BGRA) {
            // Local submission timing, not GPU completion or capture-to-photon.
            // Bounded samples and one report per five seconds avoid frame I/O.
            static auto report_at=Clock::now();
            static std::vector<double> samples;
            static std::uint64_t swaps{},over_target{};
            const auto ms=std::chrono::duration<double,std::milli>(Clock::now()-draw_started).count();
            ++swaps;over_target+=ms>(1000./60.);
            if(samples.size()<4096)samples.push_back(ms);
            if(swaps==1 || Clock::now()-report_at>=std::chrono::seconds(5)) {
                std::sort(samples.begin(),samples.end());
                std::fprintf(stderr,"ivshmem-present swaps=%llu windows=%zu draw_submit_p50_ms=%.3f draw_submit_p95_ms=%.3f over_16_7ms=%llu scope=host-draw-to-egl-swap\n",
                    static_cast<unsigned long long>(swaps),windows.size(),samples[samples.size()/2],samples[samples.size()*95/100],static_cast<unsigned long long>(over_target));
                samples.clear();report_at=Clock::now();
            }
        }
    }
    void accept(vf::Frame frame,bool preuploaded=false) {
        if(frame.shared_bgra)trace_host_frame("accept_begin",frame.pts);
        const auto lane_index=frame.activity_epoch?frame.activity_lane:0;
        auto& lane=lanes[lane_index];auto& decoder=lane.decoder;auto& codec=lane.codec;auto& pending=lane.pending;
        if(!preuploaded && lane.progressive_frame){
            trace_host_frame("replaced_by_ordinary",lane.progressive_frame->pts);
            make_current(pbuffer);lane.progressive_decoder->cancel_progressive();lane.progressive_frame.reset();
        }
        auto& atlas_width=lane.atlas_width;auto& atlas_height=lane.atlas_height;
        auto& encoded_alpha=lane.encoded_alpha;
        make_current(pbuffer);
        if(!decoder || codec!=frame.codec){lane.async_alpha.reset();lane.alpha_layout.clear();lane.alpha_submitted_version=0;decoder=std::make_unique<vf::GpuDecoder>(upload_cache);decoder->start(frame.codec);codec=frame.codec;pending.clear();lane.uploaded.reset();lane.uploaded_alpha.reset();}
        const auto pts=frame.pts;
        auto color=std::move(frame.color);auto raw=frame.shared_bgra;const auto raw_width=frame.width,raw_height=frame.height;
        pending.emplace(pts,std::move(frame));
        auto decoded=raw?std::vector<vf::DecodedFrame>{decoder->raw_bgra(raw,raw_width,raw_height,pts)}:decoder->submit(color,pts);
        for(auto& image:decoded) {
            const auto found=pending.find(image->pts);if(found==pending.end())throw std::runtime_error("reverse decoded metadata missing");
            auto current=std::move(found->second);pending.erase(pending.begin(),std::next(found));
            if(image->width!=static_cast<int>(current.width) || image->height!=static_cast<int>(current.height))throw std::runtime_error("reverse decoded dimensions mismatch");
            if(!activity_presentation.admit(current))continue;
            static const bool async_option=[] {const auto* value=std::getenv("VIEWFLOW_GPU_ALPHA_ASYNC");return value && std::strcmp(value,"1")==0;}();
            bool alpha_layout_changed=false;
            if(async_option) {
                auto layout=alpha_layout_key(current);alpha_layout_changed=layout!=lane.alpha_layout;
                if(alpha_layout_changed) {
                    lane.alpha_layout=std::move(layout);++lane.alpha_generation;lane.async_alpha.reset();lane.alpha_submitted_version=0;
                }
                ++lane.alpha_version;
            }
            if(preuploaded)lane.uploaded=image;
            const auto accept_begin=Clock::now();bool alpha_overlapped=false,alpha_from_gpu=false,alpha_unchanged=false;
            double alpha_upload_ms=0,alpha_extract_ms=0;
            const bool resized=atlas_width!=current.width || atlas_height!=current.height;
            atlas_width=current.width;atlas_height=current.height;
            const bool desktop_only=current.shared_bgra && vf::desktop_output_only(current);
            if(desktop_only!=lane.desktop_only) {
                lane.gpu_alpha.reset();lane.async_alpha.reset();lane.alpha_submitted_version=0;
                lane.desktop_only=desktop_only;
            }
            if(desktop_only) {
                // The empty immutable metadata plane is deliberate: each DD
                // tile uses a rectangle and the color pass forces alpha to 1.
                if(!lane.latest_alpha || !lane.latest_alpha->empty()) {
                    lane.latest_alpha=std::make_shared<const std::vector<uint8_t>>();++lane.alpha_revision;
                }
                encoded_alpha=std::move(current.alpha);alpha_unchanged=true;
            } else if(current.shared_bgra || resized || encoded_alpha!=current.alpha || !lane.latest_alpha) {
                if(current.shared_bgra) {
                    auto& alpha=lane.raw_alpha_buffers[lane.next_alpha_buffer++%lane.raw_alpha_buffers.size()];
                    const auto pixels=std::size_t(atlas_width)*atlas_height;
                    const auto* gpu_alpha_mode=std::getenv("VIEWFLOW_GPU_ALPHA");
                    const bool gpu_requested=pixels>=4*1024*1024 && gpu_alpha_mode && std::strcmp(gpu_alpha_mode,"1")==0 && !lane.gpu_alpha_disabled;
                    const bool async_requested=async_option && gpu_requested && !lane.async_alpha_disabled;
                    const bool reuse_alpha=async_requested && !alpha_layout_changed && lane.latest_alpha && !lane.latest_alpha->empty();
                    if(!reuse_alpha) {
                        if(!alpha || alpha.use_count()!=1)alpha=std::make_shared<std::vector<std::uint8_t>>();
                        alpha->resize(pixels);
                    }
                    if(gpu_requested) {
                        try {
                            const auto upload_begin=Clock::now();
                            if(lane.uploaded!=image)decoder->upload(image);lane.uploaded=image;
                            const auto upload_end=Clock::now();
                            alpha_upload_ms=std::chrono::duration<double,std::milli>(upload_end-upload_begin).count();
                            if(reuse_alpha)alpha_unchanged=true;
                            else {
                                alpha_unchanged=!lane.gpu_alpha.extract(decoder->y_texture(),atlas_width,atlas_height,*alpha,bool(lane.latest_alpha) && !lane.latest_alpha->empty() && !alpha_layout_changed);
                                lane.alpha_applied_version=lane.alpha_version;
                            }
                            if(async_requested && lane.async_alpha.submit(decoder->y_texture(),atlas_width,atlas_height,lane.alpha_version)) {
                                lane.alpha_submitted_version=lane.alpha_version;lane.alpha_job_generation=lane.alpha_generation;
                            }
                            alpha_extract_ms=std::chrono::duration<double,std::milli>(Clock::now()-upload_end).count();
                            alpha_from_gpu=true;
                        }catch(const std::exception& error) {
                            lane.gpu_alpha_disabled=true;lane.gpu_alpha.reset();lane.async_alpha.reset();lane.alpha_submitted_version=0;
                            if(!alpha || alpha.use_count()!=1)alpha=std::make_shared<std::vector<std::uint8_t>>();
                            alpha->resize(pixels);alpha_unchanged=false;
                            std::fprintf(stderr,"GPU alpha fallback=CPU reason=%s\n",error.what());
                        }
                    }
                    const bool overlap=!alpha_from_gpu && pixels>=4*1024*1024 && !std::getenv("VIEWFLOW_DISABLE_ALPHA_OVERLAP");
                    if(overlap && !alpha_upload_overlap && !alpha_overlap_unavailable) {
                        try {alpha_upload_overlap=std::make_unique<vf::AlphaUploadOverlap>();}
                        catch(const std::exception& error) {alpha_overlap_unavailable=true;std::fprintf(stderr,"alpha overlap fallback=serial reason=%s\n",error.what());}
                    }
                    if(overlap && alpha_upload_overlap) {
                        alpha_upload_overlap->run(current.shared_bgra->bytes,*alpha,[&]{if(lane.uploaded!=image)decoder->upload(image);lane.uploaded=image;});
                        alpha_overlapped=true;
                    }else if(!alpha_from_gpu)vf::extract_bgra_alpha(current.shared_bgra->bytes,*alpha);
                    if(!alpha_unchanged)lane.latest_alpha=alpha;
                }else lane.latest_alpha=std::make_shared<const std::vector<std::uint8_t>>(vf::decode_alpha(current.alpha,std::size_t(atlas_width)*atlas_height));
                encoded_alpha=std::move(current.alpha);if(!alpha_unchanged)++lane.alpha_revision;
            }
            const auto alpha_done=Clock::now();
            const auto& latest_alpha=*lane.latest_alpha;
            const auto alpha_revision=lane.alpha_revision*2+lane_index;
            ++decoded_count;
            if(validate_only){if(lane.uploaded!=image)decoder->upload(image);std::fprintf(stderr,"reverse-validated frame=%u tiles=%zu width=%u height=%u pts=%lld\n",decoded_count,current.tiles.size(),atlas_width,atlas_height,static_cast<long long>(image->pts));continue;}
            auto ids=activity_presentation.members(current);
            // Start and Search overlap during handoff but form one host popup.
            // Retain its Wayland surface/keyboard seat and update guest routing.
            std::uint64_t shell_id=0;
            for(const auto& tile:current.tiles)
                if((tile.flags&vf::windows_shell_flag) && activity_presentation.accepts(current,tile))shell_id=std::max(shell_id,tile.id);
            for(const auto& [id,w]:windows)
                if(shell_id && (w->tile.flags&vf::windows_shell_flag) && id!=shell_id)ids.erase(id);
            for(const auto& tile:current.tiles)
                if((tile.flags&vf::windows_shell_flag) && tile.id!=shell_id)ids.erase(tile.id);
            for(auto& tile:current.tiles) {
                if(!activity_presentation.accepts(current,tile) || ((tile.flags&vf::windows_shell_flag) && tile.id!=shell_id))continue;
                if((tile.flags&vf::windows_shell_flag) && !windows.contains(tile.id)) {
                    for(auto it=windows.begin();it!=windows.end();++it) {
                        if(!(it->second->tile.flags&vf::windows_shell_flag))continue;
                        const auto previous=it->first;
                        auto node=windows.extract(it);node.key()=tile.id;node.mapped()->id=tile.id;
                        node.mapped()->residency.reset();node.mapped()->backdrop.reset();
                        xdg_toplevel_set_app_id(node.mapped()->top,node.mapped()->app_id().c_str());
                        windows.insert(std::move(node));
                        if(keyboard_window==previous)keyboard_window=tile.id;
                        if(pointer_window==previous)pointer_window=tile.id;
                        if(pointer_anchor_window==previous)pointer_anchor_window=tile.id;
                        for(auto& [button,target]:forwarded_buttons)if(target==previous)target=tile.id;
                        std::fprintf(stderr,"reverse-shell-handoff from=%llu to=%llu keyboard=%u surface=retained\n",
                            (unsigned long long)previous,(unsigned long long)tile.id,unsigned(keyboard_window==tile.id));
                        break;
                    }
                }
                if(mac_shadow && (tile.flags&16))scale=tile.pixel_scale;
                auto& w=windows.contains(tile.id)?*windows.at(tile.id):create(tile);
                const bool same_alpha=w.media_alpha==lane.latest_alpha;
                w.media_lane=lane_index;w.media_width=atlas_width;w.media_height=atlas_height;w.media_alpha_generation=lane.alpha_generation;
                w.pixels=image;w.media_alpha=lane.latest_alpha;w.media_alpha_revision=alpha_revision;
                const bool native_changed=((w.tile.flags^tile.flags)&(16|vf::windows_shell_flag|vf::windows_popup_flag|vf::windows_desktop_output_flag))!=0;
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
                update_alpha_metadata(w,atlas_width,latest_alpha,same_alpha);
                try {take_local_titlebar(w);}
                catch(const std::exception& error) {
                    native_move_confirmation.cancel();native_move_candidate=0;
                    std::fprintf(stderr,"Remote titlebar takeover unavailable: %s\n",error.what());
                }
                const bool shadow_changed=update_shadow_metadata(w,native_changed);
                apply_icon(w,tile,native_changed||shadow_changed);
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
            const auto prepare_done=Clock::now();
            for(auto& [_,w]:windows) {
                xdg_toplevel_set_parent(w->top,w->tile.owner && windows.contains(w->tile.owner)?windows.at(w->tile.owner)->top:nullptr);
                if(w->pixels==image)draw(*w);
            }
            if(current.shared_bgra) {
                static auto report_at=Clock::now();static std::vector<std::array<double,6>> samples;
                const auto end=Clock::now();
                if(samples.size()<4096)samples.push_back({std::chrono::duration<double,std::milli>(alpha_done-accept_begin).count(),std::chrono::duration<double,std::milli>(prepare_done-alpha_done).count(),std::chrono::duration<double,std::milli>(end-prepare_done).count(),std::chrono::duration<double,std::milli>(end-accept_begin).count(),alpha_upload_ms,alpha_extract_ms});
                if(end-report_at>=std::chrono::seconds(5)) {
                    std::array<double,6> median{},p95{};
                    for(unsigned i=0;i<6;++i){std::vector<double> values;for(const auto& sample:samples)values.push_back(sample[i]);std::sort(values.begin(),values.end());median[i]=values[values.size()/2];p95[i]=values[values.size()*95/100];}
                    std::fprintf(stderr,"ivshmem-accept frames=%zu width=%u height=%u interval_ms=%.3f accepted_fps=%.3f alpha_p50_ms=%.3f alpha_p95_ms=%.3f prepare_p50_ms=%.3f prepare_p95_ms=%.3f draw_p50_ms=%.3f draw_p95_ms=%.3f total_p50_ms=%.3f total_p95_ms=%.3f overlap=%u gpu_alpha=%u scope=CPU-submit\n",samples.size(),current.width,current.height,std::chrono::duration<double,std::milli>(end-report_at).count(),samples.size()/std::chrono::duration<double>(end-report_at).count(),median[0],p95[0],median[1],p95[1],median[2],p95[2],median[3],p95[3],unsigned(alpha_overlapped),unsigned(alpha_from_gpu));
                    std::fprintf(stderr,"ivshmem-alpha-stages samples=%zu upload_p50_ms=%.3f upload_p95_ms=%.3f extract_p50_ms=%.3f extract_p95_ms=%.3f gpu_alpha=%u scope=CPU-wall-including-synchronization\n",samples.size(),median[4],p95[4],median[5],p95[5],unsigned(alpha_from_gpu));
                    samples.clear();report_at=end;
                }
            }
            if(current.shared_bgra)trace_host_frame("accept_end",current.pts);
            // All received tiles now own GPU snapshots. Do not let inactive
            // windows or lane.uploaded keep shared slots hostage indefinitely.
            if(current.shared_bgra && (std::getenv("VIEWFLOW_SHM_LEASE") || current.shared_bgra->storage_owner)) {
                av_buffer_unref(&image->buf[0]);image->data[0]=nullptr;image->opaque=nullptr;
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
                if(!local_titlebar_seen)std::fprintf(stderr,"Remote titlebar local active id=%llu\n",static_cast<unsigned long long>(local_titlebar_window));
                local_titlebar_seen=true;
            }
            else if(local_titlebar_seen || (buttons_held && !*buttons_held)) {
                std::fprintf(stderr,"Remote titlebar local end id=%llu\n",static_cast<unsigned long long>(local_titlebar_window));
                interaction(local_titlebar_window,false);local_titlebar_window=0;local_titlebar_seen=false;
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
            int target_x=static_cast<int>(std::lround(double(w.tile.x)/scale))+origin_x,target_y=static_cast<int>(std::lround(double(w.tile.y)/scale))+origin_y;
            // IME coordinates are guest screen coordinates. A host-anchored
            // Start/Search menu has a different origin, including its crop.
            bool shell_ime=false;
            if(w.ime_popup() && w.tile.owner && windows.contains(w.tile.owner)) {
                const auto& owner=*windows.at(w.tile.owner);
                if(owner.tile.flags&vf::windows_shell_flag) {
                    for(const auto& parent:clients) {
                        if(parent.value("class",std::string{})!=owner.app_id() || !parent.value("mapped",false))continue;
                        std::tie(target_x,target_y)=shell_popup_position(w.tile.x,w.tile.y,owner.tile,
                            parent.at("at").at(0).get<int>(),parent.at("at").at(1).get<int>(),scale);
                        shell_ime=true;
                        break;
                    }
                }
            }
            const int target_width=receiver_body_width(w.tile,scale,mac_shadow),target_height=receiver_body_height(w.tile,scale,mac_shadow);
            // A new surface can inherit the focused workspace on another
            // output. Assign its initial workspace from the remote rectangle,
            // without following it or overriding later user workspace moves.
            bool refresh_workspace=false;
            // Shell popups belong to the bar's host anchor from their first
            // map. Their source rectangle is only a capture/input coordinate.
            if(w.tile.flags&vf::windows_shell_flag)w.workspace_assigned=true;
            if(!w.workspace_assigned) {
                const auto* selected=vf::initial_workspace_monitor(monitors,target_x,target_y,target_width,target_height);
                for(const auto& monitor:monitors) {
                    if(&monitor!=selected)continue;
                    if(vf::outbound_parking_monitor(monitor))continue;
                    const int workspace=monitor.at("activeWorkspace").at("id");
                    if(workspace!=client.at("workspace").at("id").get<int>()) {
                        try {
                            const auto selector=vf::workspace_selector(workspace,monitor.at("activeWorkspace").at("name").get<std::string>());
                            eval("hl.dispatch(hl.dsp.window.move({workspace="+nlohmann::json(selector).dump()+",follow=false,window='address:"+address+"'}))");
                            // The dispatch completed. Do not reassign from a
                            // later inventory: the user may already have moved
                            // the window again before geometry is initialized.
                            w.workspace_assigned=true;
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
                if(!refresh_workspace)w.workspace_assigned=true;
            }
            if(refresh_workspace)continue;
            // Workspace placement clears Hyprland's pin bit. The user-facing
            // Start controller and this initial placement run independently,
            // so the receiver must restore pin after either moves the popup.
            // Address only this receiver's shell surface; never change focus.
            if(((w.tile.flags&vf::windows_shell_flag) || shell_ime) && !client.value("pinned",false)) {
                try {
                    eval("hl.dispatch(hl.dsp.window.pin({action='set',window='address:"+address+"'}))");
                } catch(const std::exception& error) {
                    std::fprintf(stderr,"reverse shell pin retry id=%llu: %s\n",(unsigned long long)id,error.what());
                }
            }
            // Demand is based on the destination viewport, never the source
            // desktop's stacking: independent remote windows can interleave.
            if((w.tile.flags & vf::residency_capability) && width>0 && height>0 && vf::has_destination_monitor(monitors)) {
                double left=1e30,top=1e30,right=-1e30,bottom=-1e30;
                for(const auto& monitor:monitors) {
                    if(vf::outbound_parking_monitor(monitor))continue;
                    const double ms=monitor.value("scale",1.0);const bool rotated=monitor.value("transform",0)%2!=0;
                    const double mx=monitor.at("x"),my=monitor.at("y");
                    left=std::min(left,mx);top=std::min(top,my);
                    right=std::max(right,mx+monitor.at(rotated?"height":"width").get<double>()/ms);
                    bottom=std::max(bottom,my+monitor.at(rotated?"width":"height").get<double>()/ms);
                }
                const auto& tile=w.tile;
                const double bx=(tile.flags&16)?tile.body_x:0,by=(tile.flags&16)?tile.body_y:0;
                const auto content=content_surface(w);
                const double sx=double((tile.flags&16)?tile.body_width:tile.width)/std::max(1,content.body_width);
                const double sy=double((tile.flags&16)?tile.body_height:tile.height)/std::max(1,content.body_height);
                const auto demand=vf::workspace_visible(client,monitors)
                    ? vf::align_resident(vf::viewport_resident(tile.width,tile.height,bx+(left-x-content.x)*sx,by+(top-y-content.y)*sy,bx+(right-x-content.x)*sx,by+(bottom-y-content.y)*sy),tile.width,tile.height)
                    : vf::PixelRect{};
                if(!w.residency || *w.residency!=demand || w.residency_width!=tile.width || w.residency_height!=tile.height) {
                    if(std::getenv("VIEWFLOW_PRESENTATION_TRACE"))std::fprintf(stderr,"ivshmem-residency id=%llu demand=%u,%u,%u,%u client=%s monitors=%s\n",(unsigned long long)id,demand.x,demand.y,demand.width,demand.height,client.dump().c_str(),monitors.dump().c_str());
                    if(send(id,vf::InputKind::visibility,demand.x,demand.y,demand.width,demand.height)) {
                        w.residency=demand;w.residency_width=tile.width;w.residency_height=tile.height;
                    }
                }
            }
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
            // Ordinary Windows IVSHMEM uses WGC backing at destination pixel
            // size. The explicitly enabled route request instead gives Windows
            // ownership of a DD lease or its WGC fallback, without changing focus.
            static const bool fullscreen_dma=[] {const auto* value=std::getenv("VIEWFLOW_FULLSCREEN_DMA");return value && std::strcmp(value,"1")==0;}();
            const bool fullscreen_control_eligible=vf::windows_fullscreen_backing_enabled(mac_shadow,!shared_memory_path.empty(),w.ime_popup(),
                (w.tile.flags&vf::windows_shell_flag)!=0,(w.tile.flags&vf::windows_popup_flag)!=0);
            // If a formerly ordinary source changes type, release its old
            // route without ever requesting a new popup/menu fullscreen lease.
            if(fullscreen_dma && !fullscreen_control_eligible && w.fullscreen_route.engaged) {
                const auto now_ms=std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();
                if(const auto request=w.fullscreen_route.observe(false,std::nullopt,now_ms))
                    w.fullscreen_route.sent(send(id,vf::InputKind::fullscreen_route,request->mode,1,0,0));
            }
            if(!fullscreen_control_eligible)w.fullscreen_backing={};
            if(fullscreen_control_eligible) {
                const bool fullscreen=client.value("fullscreen",0)==2;
                const vf::Geometry actual{w.tile.x,w.tile.y,
                    static_cast<int>((w.tile.flags&16)?w.tile.logical_width:w.tile.width),
                    static_cast<int>((w.tile.flags&16)?w.tile.logical_height:w.tile.height)};
                auto backing=vf::Geometry{x,y,width,height};
                std::optional<vf::Geometry> desired;
                if(fullscreen) {
                    for(const auto& monitor:monitors) {
                        if(monitor.value("id",-1)!=client.value("monitor",-2))continue;
                        desired=vf::fullscreen_backing_extent(actual,monitor.at("width"),monitor.at("height"),monitor.value("transform",0));
                        break;
                    }
                } else {
                    if(!client.value("floating",false)) {
                        for(const auto& monitor:monitors) {
                            if(monitor.value("id",-1)!=client.value("monitor",-2))continue;
                            const double ms=monitor.value("scale",1.0);
                            const bool rotated=monitor.value("transform",0)%2!=0;
                            if(ms>0)backing=vf::tiled_backing_geometry(backing,{monitor.at("x"),monitor.at("y"),
                                static_cast<int>(std::lround(monitor.at(rotated?"height":"width").get<double>()/ms)),
                                static_cast<int>(std::lround(monitor.at(rotated?"width":"height").get<double>()/ms))});
                            break;
                        }
                    }
                    const auto candidate=vf::Geometry{(backing.x-origin_x)*int(scale),(backing.y-origin_y)*int(scale),width*int(scale),height*int(scale)};
                    if(candidate.width>0 && candidate.height>0 && candidate.width<=16384 && candidate.height<=16384)desired=candidate;
                }
                const auto now_ms=std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();
                if(fullscreen_dma) {
                    if(const auto request=w.fullscreen_route.observe(fullscreen,desired,now_ms)) {
                        const auto epoch=send(id,vf::InputKind::fullscreen_route,request->mode,1,request->width,request->height);
                        w.fullscreen_route.sent(epoch);
                    }
                }
                const auto decision=w.fullscreen_backing.observe(fullscreen,desired,actual,w.tile.geometry_ack,now_ms);
                if(decision.consume) {
                    // Suppress stale fullscreen source geometry throughout
                    // restoration, including delayed receipts and tiling edits.
                    w.geometry_sync.initialized=true;w.geometry_sync.observed={x,y,width,height};
                    w.geometry_sync.floating=client.value("floating",false);
                    // With route control enabled, Windows alone owns the
                    // backing during mode 2 (DD lease or WGC fallback). On exit
                    // route 0 precedes the restoring geometry on this stream.
                    if(decision.send && (!fullscreen_dma || (!fullscreen && w.fullscreen_route.exit_delivered()))) {
                        const auto& target=decision.target;
                        const auto sequence=send(id,vf::InputKind::geometry,target.x,target.y,target.width,target.height);
                        w.fullscreen_backing.sent(sequence,now_ms);
                        if(sequence)w.geometry_sync.sent(sequence);
                    }
                    if(!w.fullscreen_backing.active)w.geometry_sync.pending=0;
                    w.placed=true;continue;
                }
            }
            // Fullscreen size belongs to the Linux output. Never send it back
            // as an AX resize, or apply the Mac display size over the compositor.
            // Wait through exit until the compositor has restored normal geometry.
            if (w.source_fullscreen || client.value("fullscreen",0) != 0) { w.resize.cancel();w.placed=true; continue; }
            // xdg window geometry and compositor inventory describe the body;
            // captured shadow padding belongs only to the underlying surface.
            const int body_width=width,body_height=height;
            // Start/Search are host-positioned popups. Moving their proxies
            // must not move/resize Windows' full-display shell backing HWND.
            if(w.tile.flags&vf::windows_shell_flag){w.placed=true;continue;}
            const vf::Geometry local{x,y,width,height},remote{target_x,target_y,target_width,target_height};
            const bool same_local_size=w.geometry_sync.initialized &&
                w.geometry_sync.observed.width==width && w.geometry_sync.observed.height==height;
            const auto action=w.ime_popup()?(local==remote?vf::GeometryAction::none:vf::GeometryAction::apply_remote):w.geometry_sync.observe(local,remote,w.tile.geometry_ack,client.value("floating",false),local_drag_window==w.native_address || local_titlebar_window==id);
            const auto resize_now=std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();
            // Moving keeps size unchanged and must follow immediately. Only
            // actual resize/configure churn uses the existing AX debounce.
            const bool mac_move=mac_shadow && same_local_size;
            if(mac_shadow && action==vf::GeometryAction::send_local) {
                w.resize.queue(local,resize_now,mac_move);
            }
            const bool mac_resize_ready=mac_shadow && w.resize.ready(resize_now);
            if((!mac_shadow && action==vf::GeometryAction::send_local) || mac_resize_ready) {
                w.resize.cancel();
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
            } else if(action==vf::GeometryAction::apply_remote && !w.resize.candidate) {
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
                    static_cast<int>(std::lround(vf::drag_grab_points(w.tile,w.drag_grab_x,scale)*1000)),
                    static_cast<int>(std::lround(vf::drag_grab_points(w.tile,w.drag_grab_y,scale)*1000)),getpid());
                send(id,vf::InputKind::proxy_drag,getpid(),native_drag,static_cast<int>(w.native_address),static_cast<int>(w.native_address>>32));
                w.drag_announced=native_drag;
                w.drag_start_pending=false;
            }
        }
    }
    void begin_progressive(vf::Frame frame){
        const auto index=frame.activity_epoch?frame.activity_lane:0;auto& lane=lanes[index];
        make_current(pbuffer);
        if(!lane.progressive_decoder){lane.progressive_decoder=std::make_unique<vf::GpuDecoder>(upload_cache);lane.progressive_decoder->start(3);}
        if(lane.progressive_frame){trace_host_frame("superseded_active",lane.progressive_frame->pts);lane.progressive_decoder->cancel_progressive();}
        lane.progressive_frame.reset();
        static const bool completion_notify=[] {const auto* v=std::getenv("VIEWFLOW_PROGRESSIVE_NOTIFY");return v && std::string_view(v)=="1";}();
        lane.progressive_decoder->begin_progressive(frame.progressive_bgra->lease,completion_notify?wake:-1,frame.pts);
        lane.progressive_frame=std::move(frame);
    }
    bool poll_raw_dma(){
        // GPU reads may outlive submission and the AVFrame. Retire the slot
        // lease even when no new frames arrive (e.g. a now-static window).
        make_current(pbuffer);
        bool pending=false;
        for(auto& lane:lanes) {
            if(lane.decoder){lane.decoder->poll_raw_dma();pending|=lane.decoder->raw_dma_pending();}
            if(lane.progressive_decoder){lane.progressive_decoder->poll_raw_dma();pending|=lane.progressive_decoder->raw_dma_pending();}
        }
        return pending;
    }
    bool poll_progressive(){
        bool pending=false;
        for(auto& lane:lanes){
            if(!lane.progressive_frame)continue;
            make_current(pbuffer);
            try{
                const auto status=lane.progressive_decoder->poll_progressive();
                if(status==vf::GpuDecoder::ProgressiveStatus::pending){pending=true;continue;}
                if(status==vf::GpuDecoder::ProgressiveStatus::aborted){trace_host_frame("producer_aborted",lane.progressive_frame->pts);lane.progressive_frame.reset();continue;}
                auto frame=std::move(*lane.progressive_frame);lane.progressive_frame.reset();
                auto lease=frame.progressive_bgra->lease;auto prefix=lease->prefix();
                if(!lease->complete() || prefix.size()!=std::size_t(frame.width)*frame.height*4)throw std::runtime_error("completed progressive extent");
                frame.shared_bgra=std::make_shared<vf::SharedPixels>(vf::SharedPixels{lease,{const_cast<std::uint8_t*>(prefix.data()),prefix.size()},lease->storage_owner()});
                frame.progressive_bgra.reset();trace_host_frame("ready",frame.pts);
                if(std::getenv("VIEWFLOW_FIXTURE_PIXEL_STAMP")){
                    const auto stamp=vf::fixture_stamp::decode(frame.shared_bgra->bytes);
                    if(stamp)vf_diag::trace("ivshmem-pixel-stamp pts=%lld sequence=%llu generated_qpc_100ns=%llu scope=leased-host-pixels\n",static_cast<long long>(frame.pts),static_cast<unsigned long long>(stamp->sequence),static_cast<unsigned long long>(stamp->qpc100ns));
                }
                const bool reuse=lane.codec==3;
                std::swap(lane.decoder,lane.progressive_decoder);
                if(!reuse)lane.progressive_decoder.reset();
                lane.codec=3;lane.pending.clear();lane.uploaded.reset();
                accept(std::move(frame),true);
            }catch(const std::exception& error){
                std::fprintf(stderr,"progressive upload recovering reason=%s\n",error.what());
                if(lane.progressive_decoder)lane.progressive_decoder->cancel_progressive();
                lane.progressive_frame.reset();
            }
        }
        return pending;
    }
    void reader() {
        try {
            std::shared_ptr<vf::shm::Mapping> shared_mapping;
            std::optional<vf::shm::Frames> shared_frames;
            if(!shared_memory_path.empty()) {
                try {
                    shared_mapping=std::make_shared<vf::shm::Mapping>(shared_memory_path.c_str());shared_frames.emplace(shared_mapping->frames());
                    std::fprintf(stderr,"reverse-media transport=ivshmem format=bgra codec=none\n");
                }catch(const std::exception& error){std::fprintf(stderr,"reverse-media fallback=encoded reason=%s\n",error.what());}
            }
            const bool progressive_probe_enabled=progressive_enabled || std::getenv("VIEWFLOW_SHM_NEGOTIATION_PROBE")!=nullptr;
            vf::shm::ProgressiveProbe progressive_probe(progressive_probe_enabled && shared_frames?&shared_frames->progressive_negotiation():nullptr,false,vf::shm::progressive_feature|(progressive_enabled?vf::shm::progressive_payload_feature:0));
            bool progressive_probe_agreed=false;
            bool missing_shared_reported=false;
            while(running) {
                std::uint8_t prefix[4];if(!read_all(STDIN_FILENO,prefix,4))break;
                vf::Reader length{{prefix,4}};const auto size=length.u32();if(size>vf::max_record || size<32)throw std::runtime_error("reverse frame record size");
                std::vector<std::uint8_t> bytes(size);if(!read_all(STDIN_FILENO,bytes.data(),size))break;
                auto frame=vf::unpack_frame(bytes);
                if(progressive_probe_enabled){const bool agreed=progressive_probe.poll();if(agreed!=progressive_probe_agreed){progressive_probe_agreed=agreed;std::fprintf(stderr,"progressive-negotiation role=reader agreed=%u payload_capable=%u probe=1\n",unsigned(agreed),unsigned(progressive_enabled));}}
                if(frame.codec==vf::shm::codec) {
                    if(!shared_frames){if(!missing_shared_reported)std::fprintf(stderr,"IVSHMEM frame unavailable: configure matching --ivshmem host file; session retained\n");missing_shared_reported=true;continue;}
                    const bool progressive_reference=frame.color.size()>=4 && vf::Reader{frame.color}.u32()==0x324d4853;
                    if(progressive_reference){
                        auto lease=shared_frames->acquire_progressive(frame.color,frame.width,frame.height,shared_mapping);
                        if(!lease)continue;
                        frame.progressive_bgra=std::make_shared<vf::ProgressivePixels>(vf::ProgressivePixels{std::move(lease)});
                    }else if(std::getenv("VIEWFLOW_SHM_LEASE") || shared_mapping->supports_dma_buffers()) {
                        frame.shared_bgra=shared_frames->acquire(frame.color,frame.width,frame.height,shared_mapping);
                        if(frame.shared_bgra && shared_mapping->supports_dma_buffers()) {
                            const auto ref=vf::shm::unpack(frame.color);
                            frame.shared_bgra->dma_buffer=shared_mapping->dma_buffer(ref.slot,frame.width,frame.height,shared_mapping);
                        }
                    }
                    else {auto bytes=shared_frames->read(frame.color,frame.width,frame.height);if(bytes)frame.shared_bgra=std::make_shared<vf::SharedPixels>(vf::SharedPixels{bytes,*bytes});}
                    if(!frame.shared_bgra && !frame.progressive_bgra)continue; // Already replaced: retain the last presented frame.
                    if(frame.shared_bgra && std::getenv("VIEWFLOW_FIXTURE_PIXEL_STAMP")) {
                        const auto stamp=vf::fixture_stamp::decode(frame.shared_bgra->bytes);
                        if(stamp)vf_diag::trace("ivshmem-pixel-stamp pts=%lld sequence=%llu generated_qpc_100ns=%llu scope=leased-host-pixels\n",static_cast<long long>(frame.pts),static_cast<unsigned long long>(stamp->sequence),static_cast<unsigned long long>(stamp->qpc100ns));
                    }
                }
                if(frame.shared_bgra || frame.progressive_bgra) {
                    trace_host_frame(frame.progressive_bgra?"announced":"ready",frame.pts);
                    std::lock_guard lock(queue_mutex);const auto lane=frame.activity_epoch?frame.activity_lane:0;
                    if(raw_ready[lane])trace_host_frame("superseded_queued",raw_ready[lane]->pts);
                    activity_queues[lane]=viewflow::activity::FrameQueue{};if(!frame.activity_epoch)queue.clear();raw_ready[lane]=std::move(frame);
                }else if(frame.activity_epoch){
                    const auto lane=frame.activity_lane;bool request=false;
                    {std::lock_guard lock(queue_mutex);raw_ready[lane].reset();request=activity_queues[lane].push(std::move(frame),viewflow::activity::now_us());}
                    if(request){const auto bytes=viewflow::activity::pack_feedback({lane,true,true,false,0,1});vf::Writer prefix;prefix.u32(bytes.size());
                        std::lock_guard lock(output_mutex);write_all(STDOUT_FILENO,prefix.bytes);write_all(STDOUT_FILENO,bytes);}
                }else{
                    std::unique_lock lock(queue_mutex);raw_ready[0].reset();queue_changed.wait(lock,[&]{return queue.size()<2 || !running;});if(!running)break;queue.push_back(std::move(frame));
                }
                const std::uint64_t one=1;::write(wake,&one,sizeof(one));
            }
        }catch(const std::exception& error){std::fprintf(stderr,"reverse reader: %s\n",error.what());}
        input_done=true;const std::uint64_t one=1;::write(wake,&one,sizeof(one));
    }
    void run() {
        // NativeTouchpadEncoder admits two contacts and their physical click.
        // Single-finger motion/clicks stay on Wayland.
        if(!validate_only)touchpad=viewflow::hyprland::TouchpadCapture::discover();
        if(mac_shadow)std::fprintf(stderr,"Mac proxy native HID physical touchpad=%s; remote capability required\n",touchpad && touchpad->available()?"available":"unavailable (wheel fallback)");
        const auto* progressive_option=std::getenv("VIEWFLOW_SHM_PROGRESSIVE");
        progressive_enabled=progressive_option && std::string_view(progressive_option)=="1" && vf::GpuDecoder::progressive_available();
        if(progressive_enabled){
            const auto started=Clock::now();
            try{vf::GpuDecoder::prepare_upload(upload_cache);
                std::fprintf(stderr,"progressive-context-prepared elapsed_ms=%.3f scope=startup-before-reader\n",std::chrono::duration<double,std::milli>(Clock::now()-started).count());
            }catch(const std::exception& error){progressive_enabled=false;std::fprintf(stderr,"progressive preparation fallback=shm1 reason=%s\n",error.what());}
        }
        std::thread receiver([&]{reader();});auto geometry_at=Clock::now();
        try {
            while(running) {
                if(wl_display_dispatch_pending(display)<0)break;
                repeat_keys();
                drain_touchpad();
                presentation.poll_counts();
                // Harvest a completed GPU upload before a newer announcement
                // can replace it. The producer may announce the next generation
                // before its pixels are ready; that is not a newer usable frame.
                poll_progressive();
                poll_raw_dma();
                poll_async_alpha();
                std::optional<vf::Frame> frame;
                {std::lock_guard lock(queue_mutex);
                    const auto pop_raw=[&](unsigned lane)->std::optional<vf::Frame>{
                        // A completed producer frame has only local upload work left.
                        // Finish it instead of cancelling for a newer announcement;
                        // the reader keeps only the newest waiting generation.
                        if(lanes[lane].progressive_frame &&
                           lanes[lane].progressive_frame->progressive_bgra->lease->complete())return std::nullopt;
                        auto result=std::move(raw_ready[lane]);raw_ready[lane].reset();return result;
                    };
                    if(Clock::now()-last_background>=std::chrono::milliseconds(200)){frame=pop_raw(0);if(!frame)frame=activity_queues[0].pop();}
                    if(!frame)frame=pop_raw(1);if(!frame)frame=activity_queues[1].pop();
                    if(!frame)frame=pop_raw(0);if(!frame)frame=activity_queues[0].pop();
                    if(frame && !frame->activity_lane)last_background=Clock::now();
                    if(!frame && !queue.empty()){frame=std::move(queue.front());queue.pop_front();queue_changed.notify_all();}
                }
                if(frame){
                    const auto lane=frame->activity_epoch?frame->activity_lane:0;
                    const bool was_progressive=bool(frame->progressive_bgra);
                    try {if(frame->progressive_bgra)begin_progressive(std::move(*frame));else accept(std::move(*frame));}
                    catch(const std::exception& error){
                        std::fprintf(stderr,"activity decode recovering lane=%u reason=%s\n",lane,error.what());
                        make_current(pbuffer);
                        if(was_progressive){if(lanes[lane].progressive_decoder)lanes[lane].progressive_decoder->cancel_progressive();lanes[lane].progressive_frame.reset();}
                        else {lanes[lane].decoder.reset();lanes[lane].pending.clear();lanes[lane].uploaded.reset();}
                        if(viewflow::activity::negotiated()){
                            const auto bytes=viewflow::activity::pack_feedback({lane,true,false,lane==1,0,1});vf::Writer prefix;prefix.u32(bytes.size());
                            std::lock_guard lock(output_mutex);write_all(STDOUT_FILENO,prefix.bytes);write_all(STDOUT_FILENO,bytes);
                        }
                    }
                }
                const bool progressive_pending=poll_progressive();
                const bool raw_dma_pending=poll_raw_dma();
                const bool async_alpha_pending=poll_async_alpha();
                if(!frame && input_done){
                    // Source pipe ended: no further prefixes are guaranteed.
                    // Drain local DMA and release leases instead of waiting for
                    // a producer that may have exited without completing.
                    make_current(pbuffer);
                    for(auto& lane:lanes)if(lane.progressive_frame){lane.progressive_decoder->cancel_progressive();lane.progressive_frame.reset();}
                    break;
                }
                for(auto& [_,w]:windows)if(w->configured && !w->native)draw(*w);
                if(Clock::now()>=geometry_at || drag_transition_pending()){
                    const auto started=Clock::now();synchronize_geometry();const auto finished=Clock::now();
                    // Sample Super moves at the same cadence as native titlebar moves.
                    geometry_at=finished+std::chrono::milliseconds((local_titlebar_window || super_drag || !held_super.empty())?16:33);
                    static auto report=finished;static std::vector<double> durations;
                    if(durations.size()<4096)durations.push_back(std::chrono::duration<double,std::milli>(finished-started).count());
                    if(finished-report>=std::chrono::seconds(5)) {
                        std::sort(durations.begin(),durations.end());
                        vf_diag::trace("reverse-geometry-timing samples=%zu p50_ms=%.3f p95_ms=%.3f max_ms=%.3f\n",durations.size(),durations[durations.size()/2],durations[durations.size()*95/100],durations.back());
                        durations.clear();report=finished;
                    }
                }
                while(wl_display_prepare_read(display)!=0)if(wl_display_dispatch_pending(display)<0)throw std::runtime_error("Wayland dispatch failed");
                wl_display_flush(display);
                pollfd fds[]={{wl_display_get_fd(display),POLLIN,0},{wake,POLLIN,0},{touchpad?touchpad->fd():-1,POLLIN,0}};
                // Diagnostic control: isolate completion-observation delay. Only
                // spin while a progressive upload is outstanding; default sleeps.
                static const bool progressive_busy_poll=[] {const auto* v=std::getenv("VIEWFLOW_PROGRESSIVE_BUSY_POLL");return v && std::string_view(v)=="1";}();
                const int status=poll(fds,3,frame?0:progressive_pending?(progressive_busy_poll?0:1):(raw_dma_pending || async_alpha_pending)?1:8);
                if(status<0 && errno!=EINTR){wl_display_cancel_read(display);break;}
                if(fds[0].revents&POLLIN){if(wl_display_read_events(display)<0)break;}else wl_display_cancel_read(display);
                if(fds[1].revents&POLLIN){std::uint64_t value;::read(wake,&value,sizeof(value));}
            }
        }catch(...){running=false;queue_changed.notify_all();pthread_cancel(receiver.native_handle());receiver.join();throw;}
        running=false;queue_changed.notify_all();pthread_cancel(receiver.native_handle());receiver.join();
        send(0,vf::InputKind::release);
    }
};
std::string Window::app_id() const {
    if(tile.flags&vf::windows_shell_flag)return "ViewflowReverse-WindowsStart-"+std::to_string(getpid())+"-"+std::to_string(id);
    if(snapshot_desktop_output)return "ViewflowReverse-WindowsDesktop-"+std::to_string(getpid())+"-"+std::to_string(id);
    return std::string(ime_popup()?"ViewflowReverse-IME-":app->mac_shadow?((tile.flags&16)?"ViewflowReverse-MacNative-":"ViewflowReverse-Mac-"):((tile.flags&16)?std::string("ViewflowReverse-WindowsNative-")+((tile.flags&vf::windows_popup_flag)?"p":"r")+(shadow_corner?std::to_string(*shadow_corner):"X")+"-":"ViewflowReverse-"))+std::to_string(getpid())+"-"+std::to_string(id);}
Window::~Window() {
    app->presentation.forget_window(id);
    for(const auto& entry:icon_entries){std::error_code ec;std::filesystem::remove(entry,ec);}
    backdrop.reset();
    app->make_current(app->pbuffer);snapshot.reset();
    if(egl!=EGL_NO_SURFACE){eglMakeCurrent(app->egl_display,app->pbuffer,app->pbuffer,app->context);eglDestroySurface(app->egl_display,egl);}
    if(native)wl_egl_window_destroy(native);if(viewport)wp_viewport_destroy(viewport);if(top)xdg_toplevel_destroy(top);if(shell)xdg_surface_destroy(shell);if(surface)wl_surface_destroy(surface);
}
}
int main(int argc,char** argv) {
    if(argc==2 && std::string_view(argv[1])=="--activity-priority-capabilities") { std::puts("activity-priority-v1"); return 0; }
    signal(SIGPIPE,SIG_IGN);
    try {
        if(argc==2 && std::strcmp(argv[1],"--padded-geometry-self-test")==0){padded_geometry_self_test();return 0;}
        if(argc==2 && std::strcmp(argv[1],"--async-alpha-layout-self-test")==0) {
            vf::Frame frame;frame.width=6144;frame.height=3456;frame.shared_bgra=std::make_shared<vf::SharedPixels>();
            vf::Tile tile;tile.id=1;tile.flags=16;tile.width=tile.body_width=tile.logical_width=6144;
            tile.height=tile.body_height=tile.logical_height=3456;tile.pixel_scale=1;frame.tiles.push_back(tile);
            const auto base=App::alpha_layout_key(frame);
            if(vf::desktop_output_only(frame))throw std::runtime_error("ordinary WGC marked opaque");
            auto desktop=frame;desktop.tiles[0].flags|=vf::windows_desktop_output_flag;
            if(!vf::desktop_output_only(desktop))throw std::runtime_error("DD opaque classification");
            desktop.tiles.push_back(tile);
            if(vf::desktop_output_only(desktop))throw std::runtime_error("mixed atlas marked opaque");
            if(vf::desktop_output_only(vf::Frame{}))throw std::runtime_error("empty atlas marked opaque");
            const auto different=[&](const vf::Frame& changed){if(App::alpha_layout_key(changed)==base)throw std::runtime_error("async alpha layout identity missed change");};
            auto changed=frame;changed.width=4096;different(changed);
            changed=frame;changed.tiles[0].id=2;different(changed);
            changed=frame;changed.tiles[0].atlas_x=64;different(changed);
            changed=frame;changed.tiles[0].body_x=4;different(changed);
            changed=frame;changed.tiles[0].logical_height=1728;different(changed);
            changed=frame;changed.tiles[0].flags|=vf::windows_popup_flag;different(changed);
            changed=frame;vf::set_resident_rect(changed.tiles[0],{128,64,1000,800});different(changed);
            changed=frame;changed.shared_bgra.reset();different(changed);
            changed=frame;changed.tiles[0].x+=100;changed.tiles[0].y-=50;
            if(App::alpha_layout_key(changed)!=base)throw std::runtime_error("async alpha layout unnecessarily invalidated by desktop translation");
            std::fprintf(stderr,"async alpha layout self-test passed; no display or input\n");return 0;
        }
        App app;std::vector<std::string> coordinates;
        for(int i=1;i<argc;++i){const std::string arg=argv[i];
            if(arg=="--ivshmem"){if(++i==argc)throw std::runtime_error("missing IVSHMEM host path");app.shared_memory_path=argv[i];}
            else if(arg=="--validate")app.validate_only=true;
            else coordinates.push_back(arg);
        }
        if(!coordinates.empty()){
            if(coordinates.size()!=3)throw std::runtime_error("reverse presenter needs origin x, y, scale");
            app.origin_x=std::stoi(coordinates[0]);app.origin_y=std::stoi(coordinates[1]);app.scale=std::stoi(coordinates[2]);
            if(app.scale<1 || app.scale>4)throw std::runtime_error("invalid reverse scale");
        }
        app.start();app.run();return 0;
    }
    catch(const std::exception& error){std::fprintf(stderr,"reverse presenter: %s\n",error.what());return 1;}
}

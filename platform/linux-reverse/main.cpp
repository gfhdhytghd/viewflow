#include "gpu_decoder.hpp"
#include "../reverse-common/wire.hpp"
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
    wl_surface* surface{};xdg_surface* shell{};xdg_toplevel* top{};wp_viewport* viewport{};
    wl_egl_window* native{};EGLSurface egl{EGL_NO_SURFACE};
    bool configured{},placed{};vf::GeometrySync geometry_sync;
    int logical_width{},logical_height{},region_width{},region_height{};
    std::uint64_t alpha_revision{},native_address{};std::array<unsigned,4> alpha_rect{};bool drag_announced{};
    ~Window();
    std::string app_id() const {return "ViewflowReverse-"+std::to_string(id);}
};
struct App {
    wl_display* display{};wl_registry* registry{};wl_compositor* compositor{};xdg_wm_base* wm{};
    wp_viewporter* viewporter{};wl_seat* seat{};wl_pointer* pointer{};wl_keyboard* keyboard{};
    EGLDisplay egl_display{EGL_NO_DISPLAY};EGLConfig config{};EGLContext context{EGL_NO_CONTEXT};EGLSurface pbuffer{EGL_NO_SURFACE};
    std::unique_ptr<vf::GpuDecoder> decoder;
    GLuint program{},alpha_texture{};unsigned codec{},atlas_width{},atlas_height{};
    std::map<std::uint64_t,std::unique_ptr<Window>> windows;
    std::map<std::int64_t,vf::Frame> pending;
    std::uint64_t pointer_window{},keyboard_window{},sequence{};double pointer_x{},pointer_y{};
    xkb_context* key_context=xkb_context_new(XKB_CONTEXT_NO_FLAGS);xkb_keymap* key_map{};
    std::set<std::uint32_t> held_super,pending_super;bool super_drag{};
    std::optional<std::uint32_t> repeating_key;Clock::time_point repeat_at{};int repeat_rate{25},repeat_delay{600};
    int scale{2},origin_x{3072},origin_y{390};
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
    std::uint64_t send(std::uint64_t id,vf::InputKind kind,int a=0,int b=0,int c=0,int d=0) {
        auto bytes=vf::pack_input({id,++sequence,kind,a,b,c,d});vf::Writer prefix;prefix.u32(static_cast<std::uint32_t>(bytes.size()));
        write_all(STDOUT_FILENO,prefix.bytes);write_all(STDOUT_FILENO,bytes);return sequence;
    }
    std::uint64_t identify(wl_surface* surface) {for(auto& [id,w]:windows)if(w->surface==surface)return id;return 0;}
    void forward_pointer() {
        if(!pointer_window)return;
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
        if(button==272 && state==WL_POINTER_BUTTON_STATE_PRESSED && !a.held_super.empty() && a.windows.contains(a.pointer_window)) {
            a.super_drag=true;a.pending_super.clear();a.send(a.pointer_window,vf::InputKind::release);
            xdg_toplevel_move(a.windows.at(a.pointer_window)->top,a.seat,serial);return;
        }
        if(a.super_drag && button==272)return;
        if(a.pointer_window)a.send(a.pointer_window,vf::InputKind::button,static_cast<int>(button),state==WL_POINTER_BUTTON_STATE_PRESSED);
    }
    static void pointer_axis(void* data,wl_pointer*,std::uint32_t,std::uint32_t axis,wl_fixed_t value) {if(axis<2)static_cast<App*>(data)->axes[axis]+=wl_fixed_to_double(value);}
    static void pointer_frame(void* data,wl_pointer*) {
        auto& a=*static_cast<App*>(data);for(unsigned i=0;i<2;++i){const auto delta=a.axis120[i]?a.axis120[i]:static_cast<int>(std::lround(a.axes[i]*12));if(delta && a.pointer_window)a.send(a.pointer_window,vf::InputKind::wheel,i,i?-delta:-delta);a.axes[i]=0;a.axis120[i]=0;}
    }
    static void pointer_axis_source(void*,wl_pointer*,std::uint32_t){}
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
        auto& a=*static_cast<App*>(data);a.send(a.keyboard_window,vf::InputKind::release);a.keyboard_window=0;a.repeating_key.reset();a.held_super.clear();a.pending_super.clear();a.super_drag=false;
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
        else if(std::strcmp(name,xdg_wm_base_interface.name)==0){a.wm=static_cast<xdg_wm_base*>(wl_registry_bind(registry,id,&xdg_wm_base_interface,std::min(version,3u)));xdg_wm_base_add_listener(a.wm,&wm_listener,&a);}
        else if(std::strcmp(name,wp_viewporter_interface.name)==0)a.viewporter=static_cast<wp_viewporter*>(wl_registry_bind(registry,id,&wp_viewporter_interface,1));
        else if(std::strcmp(name,wl_seat_interface.name)==0 && !a.seat){a.seat=static_cast<wl_seat*>(wl_registry_bind(registry,id,&wl_seat_interface,std::min(version,9u)));wl_seat_add_listener(a.seat,&seat_listener,&a);}
    }
    static void removed(void*,wl_registry*,std::uint32_t){}
    static constexpr wl_registry_listener registry_listener={global,removed};
    static void configured(void* data,xdg_surface* surface,std::uint32_t serial) {auto& w=*static_cast<Window*>(data);xdg_surface_ack_configure(surface,serial);w.configured=true;}
    static constexpr xdg_surface_listener surface_listener={configured};
    static void top_configure(void* data,xdg_toplevel*,std::int32_t width,std::int32_t height,wl_array*) {
        auto& w=*static_cast<Window*>(data);if(width>0)w.logical_width=width;if(height>0)w.logical_height=height;
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
in vec2 uv;out vec4 color;uniform sampler2D luma;uniform sampler2D chroma;uniform sampler2D opacity;uniform vec4 tile;
void main(){vec2 p=tile.xy+uv*tile.zw;float y=(texture(luma,p).r-16.0/255.0)*255.0/219.0;vec2 c=(texture(chroma,p).rg-vec2(128.0/255.0))*255.0/224.0;
float a=texture(opacity,p).r;vec3 rgb=vec3(y+1.5748*c.y,y-0.187324*c.x-0.468124*c.y,y+1.8556*c.x);color=vec4(clamp(rgb,vec3(0),vec3(a)),a);})";
        auto compile=[](GLenum type,const char* source){const auto shader=glCreateShader(type);glShaderSource(shader,1,&source,nullptr);glCompileShader(shader);GLint okay{};glGetShaderiv(shader,GL_COMPILE_STATUS,&okay);if(!okay){char log[2048]{};glGetShaderInfoLog(shader,sizeof(log),nullptr,log);throw std::runtime_error(log);}return shader;};
        const auto vs=compile(GL_VERTEX_SHADER,vertex),fs=compile(GL_FRAGMENT_SHADER,fragment);
        program=glCreateProgram();glAttachShader(program,vs);glAttachShader(program,fs);glLinkProgram(program);glDeleteShader(vs);glDeleteShader(fs);
        GLint okay{};glGetProgramiv(program,GL_LINK_STATUS,&okay);if(!okay)throw std::runtime_error("reverse shader link failed");
        glGenTextures(1,&alpha_texture);glBindTexture(GL_TEXTURE_2D,alpha_texture);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
        eval("hl.window_rule({name='viewflow-windows-reverse',match={class='^ViewflowReverse-.*$'},float=true,no_initial_focus=true,decorate=false,border_size=0,no_shadow=true,no_anim=true})");
        std::fprintf(stderr,"reverse-presenter ready renderer=%s\n",glGetString(GL_RENDERER));
    }
    void make_current(EGLSurface surface) {if(!eglMakeCurrent(egl_display,surface,surface,context))throw std::runtime_error("reverse EGL make current failed");}
    Window& create(const vf::Tile& tile) {
        auto w=std::make_unique<Window>();w->app=this;w->id=tile.id;w->tile=tile;
        w->logical_width=static_cast<int>((tile.width+scale-1)/scale);w->logical_height=static_cast<int>((tile.height+scale-1)/scale);
        w->surface=wl_compositor_create_surface(compositor);w->viewport=wp_viewporter_get_viewport(viewporter,w->surface);
        w->shell=xdg_wm_base_get_xdg_surface(wm,w->surface);xdg_surface_add_listener(w->shell,&surface_listener,w.get());
        w->top=xdg_surface_get_toplevel(w->shell);xdg_toplevel_add_listener(w->top,&top_listener,w.get());
        xdg_toplevel_set_app_id(w->top,w->app_id().c_str());xdg_toplevel_set_title(w->top,tile.title.c_str());
        if(tile.owner && windows.contains(tile.owner))xdg_toplevel_set_parent(w->top,windows.at(tile.owner)->top);
        wl_surface_commit(w->surface);
        auto& result=*w;windows.emplace(tile.id,std::move(w));return result;
    }
    void region(Window& window) {
        const auto& t=window.tile;
        const std::array<unsigned,4> bounds{t.atlas_x,t.atlas_y,t.width,t.height};
        if(window.alpha_revision==alpha_revision && window.alpha_rect==bounds && window.region_width==window.logical_width && window.region_height==window.logical_height)return;
        window.alpha_revision=alpha_revision;window.alpha_rect=bounds;window.region_width=window.logical_width;window.region_height=window.logical_height;
        auto* region=wl_compositor_create_region(compositor);
        const auto add_region=[&](unsigned left,unsigned top,unsigned right){
            const int x0=std::uint64_t(left)*window.logical_width/t.width,x1=(std::uint64_t(right)*window.logical_width+t.width-1)/t.width;
            const int y0=std::uint64_t(top)*window.logical_height/t.height,y1=(std::uint64_t(std::min(top+scale,t.height))*window.logical_height+t.height-1)/t.height;
            wl_region_add(region,x0,y0,x1-x0,y1-y0);
        };
        for(unsigned y=0;y<t.height;y+=scale) {
            unsigned start=0;bool inside=false;
            for(unsigned x=0;x<=t.width;x+=scale) {
                const bool opaque=x<t.width && latest_alpha[std::size_t(t.atlas_y+y)*atlas_width+t.atlas_x+x]>8;
                if(opaque && !inside){start=x;inside=true;}
                if(!opaque && inside){add_region(start,y,x);inside=false;}
                if(x<t.width && x+scale>t.width){if(inside)add_region(start,y,t.width);break;}
            }
        }
        wl_surface_set_input_region(window.surface,region);wl_region_destroy(region);
    }
    void draw(Window& w) {
        if(!w.configured || !decoder || !atlas_width)return;
        if(!w.native){w.native=wl_egl_window_create(w.surface,w.logical_width*scale,w.logical_height*scale);w.egl=eglCreateWindowSurface(egl_display,config,reinterpret_cast<EGLNativeWindowType>(w.native),nullptr);}
        if(w.egl==EGL_NO_SURFACE)throw std::runtime_error("reverse EGL window failed");
        wl_egl_window_resize(w.native,w.logical_width*scale,w.logical_height*scale,0,0);
        wp_viewport_set_destination(w.viewport,w.logical_width,w.logical_height);
        xdg_surface_set_window_geometry(w.shell,0,0,w.logical_width,w.logical_height);
        make_current(w.egl);eglSwapInterval(egl_display,0);
        glViewport(0,0,w.logical_width*scale,w.logical_height*scale);glDisable(GL_BLEND);glUseProgram(program);
        const GLuint textures[]={decoder->y_texture(),decoder->uv_texture(),alpha_texture};
        const char* names[]={"luma","chroma","opacity"};
        for(unsigned i=0;i<3;++i){glActiveTexture(GL_TEXTURE0+i);glBindTexture(GL_TEXTURE_2D,textures[i]);glUniform1i(glGetUniformLocation(program,names[i]),i);}
        const auto& t=w.tile;glUniform4f(glGetUniformLocation(program,"tile"),float(t.atlas_x)/atlas_width,float(t.atlas_y)/atlas_height,float(t.width)/atlas_width,float(t.height)/atlas_height);
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
                ids.insert(tile.id);auto& w=windows.contains(tile.id)?*windows.at(tile.id):create(tile);
                w.tile=tile;xdg_toplevel_set_title(w.top,tile.title.c_str());
            }
            for(auto it=windows.begin();it!=windows.end();) {
                if(!ids.contains(it->first)){if(it->second->drag_announced)send(it->first,vf::InputKind::proxy_drag,getpid(),0,static_cast<int>(it->second->native_address),static_cast<int>(it->second->native_address>>32));if(pointer_window==it->first)pointer_window=0;if(keyboard_window==it->first){send(it->first,vf::InputKind::release);keyboard_window=0;}it=windows.erase(it);}else ++it;
            }
            for(auto& [_,w]:windows)draw(*w);
        }
        if(pending.size()>16)throw std::runtime_error("reverse decoder produced no frames");
    }
    void synchronize_geometry() {
        if(windows.empty())return;
        const auto clients=nlohmann::json::parse(ipc("j/clients"));
        for(const auto& client:clients) {
            const auto name=client.value("class",std::string{});if(!name.starts_with("ViewflowReverse-") || !client.value("mapped",false) || client.value("pid",0)!=getpid())continue;
            std::uint64_t id{};try{id=std::stoull(name.substr(16));}catch(...){continue;}
            auto found=windows.find(id);if(found==windows.end())continue;auto& w=*found->second;
            const auto address=client.at("address").get<std::string>();
            if(!address.starts_with("0x") || address.size()>18 || address.find_first_not_of("0123456789abcdefABCDEF",2)!=std::string::npos)throw std::runtime_error("invalid local Hyprland address");
            w.native_address=std::stoull(address,nullptr,16);
            const int x=client.at("at").at(0),y=client.at("at").at(1),width=client.at("size").at(0),height=client.at("size").at(1);
            const int target_x=static_cast<int>(std::lround(double(w.tile.x)/scale))+origin_x,target_y=static_cast<int>(std::lround(double(w.tile.y)/scale))+origin_y;
            const int target_width=(w.tile.width+scale-1)/scale,target_height=(w.tile.height+scale-1)/scale;
            const vf::Geometry local{x,y,width,height},remote{target_x,target_y,target_width,target_height};
            const auto action=w.geometry_sync.observe(local,remote,w.tile.geometry_ack,client.value("floating",false));
            if(action==vf::GeometryAction::send_local) {
                if(!held_super.empty() && !super_drag){super_drag=true;pending_super.clear();send(id,vf::InputKind::release);}
                w.geometry_sync.sent(send(id,vf::InputKind::geometry,(x-origin_x)*scale,(y-origin_y)*scale,width*scale,height*scale));
            } else if(action==vf::GeometryAction::apply_remote) {
                const std::string selector="'address:"+address+"'";
                eval("hl.dispatch(hl.dsp.window.resize({x="+std::to_string(target_width)+",y="+std::to_string(target_height)+",window="+selector+"}));hl.dispatch(hl.dsp.window.move({x="+std::to_string(target_x)+",y="+std::to_string(target_y)+",window="+selector+"}))");
                w.geometry_sync.applied(remote);
            }
            w.placed=true;
            const bool native_drag=(w.tile.flags&1)!=0;
            if(w.placed && w.drag_announced!=native_drag) {
                send(id,vf::InputKind::proxy_drag,getpid(),native_drag,static_cast<int>(w.native_address),static_cast<int>(w.native_address>>32));
                w.drag_announced=native_drag;
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
        std::thread receiver([&]{reader();});auto geometry_at=Clock::now();
        try {
            while(running) {
                if(wl_display_dispatch_pending(display)<0)break;
                repeat_keys();
                std::optional<vf::Frame> frame;
                {std::lock_guard lock(queue_mutex);if(!queue.empty()){frame=std::move(queue.front());queue.pop_front();queue_changed.notify_all();}}
                if(frame)accept(std::move(*frame));
                if(!frame && input_done)break;
                for(auto& [_,w]:windows)if(w->configured && !w->native)draw(*w);
                if(Clock::now()>=geometry_at){synchronize_geometry();geometry_at=Clock::now()+std::chrono::milliseconds(33);}
                while(wl_display_prepare_read(display)!=0)if(wl_display_dispatch_pending(display)<0)throw std::runtime_error("Wayland dispatch failed");
                wl_display_flush(display);
                pollfd fds[]={{wl_display_get_fd(display),POLLIN,0},{wake,POLLIN,0}};
                const int status=poll(fds,2,frame?0:8);
                if(status<0 && errno!=EINTR){wl_display_cancel_read(display);break;}
                if(fds[0].revents&POLLIN){if(wl_display_read_events(display)<0)break;}else wl_display_cancel_read(display);
                if(fds[1].revents&POLLIN){std::uint64_t value;::read(wake,&value,sizeof(value));}
            }
        }catch(...){running=false;queue_changed.notify_all();pthread_cancel(receiver.native_handle());receiver.join();throw;}
        running=false;queue_changed.notify_all();pthread_cancel(receiver.native_handle());receiver.join();
        send(0,vf::InputKind::release);
    }
};
Window::~Window() {
    if(egl!=EGL_NO_SURFACE){eglMakeCurrent(app->egl_display,app->pbuffer,app->pbuffer,app->context);eglDestroySurface(app->egl_display,egl);}
    if(native)wl_egl_window_destroy(native);if(viewport)wp_viewport_destroy(viewport);if(top)xdg_toplevel_destroy(top);if(shell)xdg_surface_destroy(shell);if(surface)wl_surface_destroy(surface);
}
}
int main(int argc,char** argv) {
    signal(SIGPIPE,SIG_IGN);
    try {App app;if(argc==2 && std::strcmp(argv[1],"--validate")==0)app.validate_only=true;if(argc==4){app.origin_x=std::stoi(argv[1]);app.origin_y=std::stoi(argv[2]);app.scale=std::stoi(argv[3]);if(app.scale<1 || app.scale>4)throw std::runtime_error("invalid reverse scale");}app.start();app.run();return 0;}
    catch(const std::exception& error){std::fprintf(stderr,"reverse presenter: %s\n",error.what());return 1;}
}

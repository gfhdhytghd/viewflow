#include "desktop_handoff.hpp"
#include "input_capture.hpp"
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstring>
namespace viewflow::hyprland {
DesktopHandoff::DesktopHandoff(const std::string& path,handoff::Rect local,handoff::Rect remote):core(local,remote) {
    sockaddr_un addr{};addr.sun_family=AF_UNIX;
    if(path.size()>=sizeof(addr.sun_path))throw std::runtime_error("handoff socket path too long");
    std::memcpy(addr.sun_path,path.c_str(),path.size()+1);
    fd=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC|SOCK_NONBLOCK,0);
    if(fd<0)throw std::runtime_error("handoff socket unavailable");
    if(connect(fd,reinterpret_cast<sockaddr*>(&addr),sizeof(addr))<0){::close(fd);fd=-1;throw std::runtime_error("handoff connect failed");}
    for(auto key:g_pInputManager->getKeysFromAllKBs()) {
        for(const auto& keyboard:g_pInputManager->m_keyboards)
            if(keyboard && !keyboard->isVirtual() && !keyboard->m_deviceTags.contains("viewflow-injected") && keyboard->getPressed(key)) {core.physicalKeys.insert(static_cast<int>(key));break;}
    }
    core.send=[this](handoff::Input e){send(e);};
    core.inject=[this](handoff::Input e){e.kind=static_cast<handoff::InputKind>(handoff::kind(e)+400);send(e);};
    core.capture=[this](bool active){
        if(active){
            const auto p=g_pInputManager->getMouseCoordsInternal();anchorX=p.x;anchorY=p.y;
            // End local client presses before physical releases are swallowed.
            for(int key:core.physicalKeys)g_pSeatManager->sendKeyboardKey(0,static_cast<uint32_t>(key),WL_KEYBOARD_KEY_STATE_RELEASED);
            g_pSeatManager->sendKeyboardMods(0,0,0,0);
            for(int button:core.physicalButtons)g_pSeatManager->sendPointerButton(0,static_cast<uint32_t>(button),WL_POINTER_BUTTON_STATE_RELEASED);
            g_pSeatManager->sendPointerFrame();
        }
        else {
            anchorX=std::clamp(core.remote.x+core.x,core.local.x+1,core.local.x+core.local.w-2);
            anchorY=std::clamp(core.remote.y+core.y,core.local.y+1,core.local.y+core.local.h-2);
            const bool previous=InputCapture::forwardedMotion;InputCapture::forwardedMotion=true;
            Pointer::mgr()->warpTo({anchorX,anchorY});InputCapture::forwardedMotion=previous;
            core.observe_position(anchorX,anchorY);
        }
        if(captureChanged)captureChanged(active);
    };
    source=wl_event_loop_add_fd(g_pCompositor->m_wlEventLoop,fd,WL_EVENT_READABLE,readable,this);
    if(!source){::close(fd);fd=-1;throw std::runtime_error("handoff event source unavailable");}
    send(handoff::message(handoff::capabilities,1,1));
}
DesktopHandoff::~DesktopHandoff(){close();}
void DesktopHandoff::send(handoff::Input e) {
    const auto bytes=reverse::pack_input(e);
    if(fd<0 || ::send(fd,bytes.data(),bytes.size(),MSG_NOSIGNAL|MSG_DONTWAIT)!=ssize_t(bytes.size()))
        throw std::runtime_error("handoff socket backpressure or disconnect");
}
void DesktopHandoff::close() {
    if(dead)return;
    dead=true;
    try{core.reset();}catch(...){if(core.outgoing && captureChanged)captureChanged(false);core.outgoing=false;core.incoming=false;}
    if(source){wl_event_source_remove(source);source=nullptr;}
    if(fd>=0){::close(fd);fd=-1;}
}
int DesktopHandoff::readable(int,uint32_t mask,void* data) {
    auto& self=*static_cast<DesktopHandoff*>(data);
    if(mask&(WL_EVENT_HANGUP|WL_EVENT_ERROR)){self.close();return 0;}
    try {
        for(unsigned i=0;i<64;++i) {
            uint8_t bytes[41];const auto n=recv(self.fd,bytes,sizeof(bytes),MSG_DONTWAIT);
            if(n<0 && (errno==EAGAIN || errno==EWOULDBLOCK))break;
            if(n!=40)throw std::runtime_error("handoff native framing");
            auto e=handoff::decode(std::span(bytes,40));
            if((handoff::kind(e)==handoff::captured || handoff::kind(e)==handoff::entered) && legacyCaptured && legacyCaptured()) {
                self.send(handoff::message(handoff::fault));continue;
            }
            self.core.command(e);
        }
    }catch(...){self.close();}
    return 0;
}
bool DesktopHandoff::busy(){for(const auto& r:routes)if(!r->dead && (r->core.pending || r->core.outgoing || r->core.incoming))return true;return false;}
bool DesktopHandoff::captured(){for(const auto& r:routes)if(!r->dead && r->core.outgoing)return true;return false;}
void DesktopHandoff::motion(double x,double y,double dx,double dy) {
    if(InputCapture::forwardedMotion || (legacyCaptured && legacyCaptured()))return;
    for(auto& r:routes) {
        if(r->dead)continue;
        if(busy() && !r->core.outgoing)continue;
        try{r->core.motion(x,y,dx,dy);}catch(...){r->close();}
    }
}
bool DesktopHandoff::input(handoff::Input e) {
    bool consumed=false;
    for(auto& r:routes)if(!r->dead)try{consumed=r->core.input(e)||consumed;}catch(...){r->close();}
    return consumed;
}
void DesktopHandoff::restoreAnchor(){for(auto& r:routes)if(!r->dead && r->core.outgoing)Pointer::mgr()->warpTo({r->anchorX,r->anchorY});}
}

#pragma once
#include <cstdint>
#include <algorithm>
namespace viewflow::reverse {
struct Geometry { int x{},y{},width{},height{};bool operator==(const Geometry&) const=default; };
// Confirm the application's own interpretation of a held click before taking
// over a titlebar drag. Content clicks and resizes keep their native handling.
struct NativeMoveConfirmation {
    Geometry initial{};
    std::uint64_t receipt{};
    bool armed{};
    void begin(Geometry remote,std::uint64_t acknowledged) {
        initial=remote;receipt=acknowledged;armed=true;
    }
    bool observe(Geometry remote,std::uint64_t acknowledged) {
        if(!armed)return false;
        if(acknowledged!=receipt || remote.width!=initial.width || remote.height!=initial.height) {
            armed=false;return false;
        }
        if(remote.x==initial.x && remote.y==initial.y)return false;
        armed=false;return true;
    }
    void cancel(){armed=false;}
};
// A tiled proxy's off-screen layout position is not a cross-desktop drag.
// Keep its native backing window inside the owning Linux monitor while the
// compositor remains free to scroll and clip the proxy itself.
inline Geometry tiled_backing_geometry(Geometry local, Geometry monitor) {
    local.x = std::min(std::max(local.x, monitor.x), monitor.x + monitor.width - local.width);
    local.y = std::min(std::max(local.y, monitor.y), monitor.y + monitor.height - local.height);
    return local;
}
enum class GeometryAction { none, send_local, apply_remote };
// Geometry comes from two asynchronous compositors. Only a receipt for the
// latest local edit may return ownership to Windows; elapsed time cannot do so.
struct GeometrySync {
    bool initialized{},floating{true};
    Geometry observed{};
    std::uint64_t pending{};
    GeometryAction observe(Geometry local,Geometry remote,std::uint64_t acknowledged,bool now_floating,bool local_drag=false) {
        if(!initialized){initialized=true;floating=now_floating;observed=local;return now_floating?GeometryAction::apply_remote:GeometryAction::send_local;}
        const bool changed=local!=observed || floating!=now_floating;
        observed=local;floating=now_floating;
        if(changed)return GeometryAction::send_local;
        if(!floating || local_drag)return GeometryAction::none;
        if(pending && acknowledged<pending)return GeometryAction::none;
        pending=0;
        return local==remote?GeometryAction::none:GeometryAction::apply_remote;
    }
    void sent(std::uint64_t sequence){pending=sequence;}
    void applied(Geometry remote){observed=remote;}
};
}

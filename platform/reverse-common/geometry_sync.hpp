#pragma once
#include <cstdint>
namespace viewflow::reverse {
struct Geometry { int x{},y{},width{},height{};bool operator==(const Geometry&) const=default; };
enum class GeometryAction { none, send_local, apply_remote };
// Geometry comes from two asynchronous compositors. Only a receipt for the
// latest local edit may return ownership to Windows; elapsed time cannot do so.
struct GeometrySync {
    bool initialized{},floating{true};
    Geometry observed{};
    std::uint64_t pending{};
    GeometryAction observe(Geometry local,Geometry remote,std::uint64_t acknowledged,bool now_floating) {
        if(!initialized){initialized=true;floating=now_floating;observed=local;return now_floating?GeometryAction::apply_remote:GeometryAction::send_local;}
        const bool changed=local!=observed || floating!=now_floating;
        observed=local;floating=now_floating;
        if(changed)return GeometryAction::send_local;
        if(!floating)return GeometryAction::none;
        if(pending && acknowledged<pending)return GeometryAction::none;
        pending=0;
        return local==remote?GeometryAction::none:GeometryAction::apply_remote;
    }
    void sent(std::uint64_t sequence){pending=sequence;}
    void applied(Geometry remote){observed=remote;}
};
}

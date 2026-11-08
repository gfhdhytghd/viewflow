#pragma once
#include "geometry_sync.hpp"
#include <optional>
namespace viewflow::reverse {
// Latest-wins local geometry candidate. There is deliberately no time debounce:
// GeometrySync already allows one in-flight edit and keeps only the newest
// queued one, so the source follows the pointer at the acknowledgement rate.
// A pause-based debounce only moves the source when the pointer stops, which
// shows up as a few discrete sizes with the old frame stretched in between.
struct WindowResize {
    std::optional<Geometry> candidate;
    void queue(Geometry geometry){candidate=geometry;}
    bool ready() const {return candidate.has_value();}
    void cancel(){candidate.reset();}
};
// xdg_toplevel configure state list: true while the compositor reports an
// interactive resize (XDG_TOPLEVEL_STATE_RESIZING == 3). The source geometry
// must not be pulled back over the proxy while the user is still dragging.
inline bool toplevel_resizing(const std::uint32_t* states,std::size_t count) {
    for(std::size_t i=0;i<count;++i)if(states[i]==3)return true;
    return false;
}
}

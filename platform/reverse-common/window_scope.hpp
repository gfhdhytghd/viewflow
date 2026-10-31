#pragma once
#include <vector>
#include <algorithm>
#include <utility>
namespace viewflow::reverse {
struct ScopeRect { double x{},y{},width{},height{}; };
struct MenuParent { unsigned id{}; ScopeRect body; };
// Candidates are front-to-back; ties retain the topmost native window.
inline unsigned menu_parent(double x,double y,const std::vector<MenuParent>& candidates) {
    unsigned selected=0;double nearest=0;
    for(const auto& candidate:candidates) {
        const auto& r=candidate.body;if(r.width<=0 || r.height<=0)continue;
        const double dx=std::max({r.x-x,0.,x-r.x-r.width});
        const double dy=std::max({r.y-y,0.,y-r.y-r.height});
        const double distance=dx*dx+dy*dy;
        if(!selected || distance<nearest){selected=candidate.id;nearest=distance;}
    }
    return selected;
}
inline ScopeRect intersection(ScopeRect a,ScopeRect b) {
    const double x=std::max(a.x,b.x),y=std::max(a.y,b.y);
    return {x,y,std::max(0.,std::min(a.x+a.width,b.x+b.width)-x),
                std::max(0.,std::min(a.y+a.height,b.y+b.height)-y)};
}
// Keep each source window in the nearest remote viewport, independent of the
// OS display enumeration order. A second peer must not steal the first's windows.
inline ScopeRect parking_position(ScopeRect requested, const std::vector<ScopeRect>& displays) {
    ScopeRect result = requested;
    double nearest = -1;
    for (const auto& display : displays) {
        if (display.width <= 0 || display.height <= 0) continue;
        const double x = std::clamp(requested.x, display.x, display.x + std::max(0., display.width - requested.width));
        const double y = std::clamp(requested.y, display.y, display.y + std::max(0., display.height - requested.height));
        const double dx = x - requested.x, dy = y - requested.y;
        const double distance = dx * dx + dy * dy;
        if (nearest < 0 || distance < nearest) { nearest = distance; result.x = x; result.y = y; }
    }
    return result;
}
// Share the portion outside the physical display union as soon as it enters
// a remote viewport. Waiting for the center can strand a titlebar at a native
// screen constraint, and disagrees with the supervisor's partial-window rule.
inline bool needs_remote(ScopeRect frame,const std::vector<ScopeRect>& physical,const std::vector<ScopeRect>& remote) {
    if(frame.width<=0 || frame.height<=0)return false;
    for(const auto& target:remote) {
        auto part=intersection(frame,target);
        if(part.width<=0 || part.height<=0)continue;
        std::vector<ScopeRect> uncovered{part};
        for(const auto& display:physical) {
            std::vector<ScopeRect> remaining;
            for(const auto& r:uncovered) {
                const auto hit=intersection(r,display);
                if(hit.width<=0 || hit.height<=0){remaining.push_back(r);continue;}
                for(const auto& piece:std::vector<ScopeRect>{
                    {r.x,r.y,r.width,hit.y-r.y},
                    {r.x,hit.y+hit.height,r.width,r.y+r.height-hit.y-hit.height},
                    {r.x,hit.y,hit.x-r.x,hit.height},
                    {hit.x+hit.width,hit.y,r.x+r.width-hit.x-hit.width,hit.height}})
                    if(piece.width>0 && piece.height>0)remaining.push_back(piece);
            }
            uncovered=std::move(remaining);
        }
        if(!uncovered.empty())return true;
    }
    return false;
}
}

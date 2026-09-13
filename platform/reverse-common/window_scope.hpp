#pragma once
#include <vector>
#include <algorithm>
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
inline bool needs_remote(ScopeRect frame,const std::vector<ScopeRect>& physical,const std::vector<ScopeRect>& remote) {
    if(!std::any_of(remote.begin(),remote.end(),[&](auto r){auto hit=intersection(frame,r);return hit.width>0 && hit.height>0;}))return false;
    std::vector<ScopeRect> remaining{frame};
    for(auto display:physical) {
        std::vector<ScopeRect> next;
        for(auto part:remaining) {
            const auto hit=intersection(part,display);
            if(hit.width<=0 || hit.height<=0){next.push_back(part);continue;}
            for(auto rect:std::vector<ScopeRect>{{part.x,part.y,part.width,hit.y-part.y},
                {part.x,hit.y+hit.height,part.width,part.y+part.height-hit.y-hit.height},
                {part.x,hit.y,hit.x-part.x,hit.height},
                {hit.x+hit.width,hit.y,part.x+part.width-hit.x-hit.width,hit.height}})
                if(rect.width>0 && rect.height>0)next.push_back(rect);
        }
        remaining=std::move(next);
    }
    return !remaining.empty();
}
}

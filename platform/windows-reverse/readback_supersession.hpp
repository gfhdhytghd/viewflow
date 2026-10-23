#pragma once
#include "../reverse-common/wire.hpp"
#include <algorithm>
#include <tuple>
namespace viewflow::reverse::shm {
// Only pixel-only replacements may coalesce; transient metadata is ordered.
inline bool supersedes_readback(const Frame& newer,const Frame& older) {
    const auto state=[](const Frame& f){return std::tie(f.codec,f.width,f.height,f.keyframe,f.activity_lane,f.activity_epoch,f.activity_preferred,f.activity_focus,f.activity_members);};
    if(newer.pts<=older.pts || state(newer)!=state(older) || newer.tiles.size()!=older.tiles.size())return false;
    return std::equal(newer.tiles.begin(),newer.tiles.end(),older.tiles.begin(),[](const Tile& a,const Tile& b){
        const auto fields=[](const Tile& t){return std::tie(t.id,t.owner,t.x,t.y,t.width,t.height,t.atlas_x,t.atlas_y,t.title,t.flags,t.geometry_ack,t.grab_x,t.grab_y,t.body_x,t.body_y,t.body_width,t.body_height,t.logical_width,t.logical_height,t.pixel_scale,t.resident_x,t.resident_y,t.resident_width,t.resident_height,t.app_id,t.icon_png);};
        return fields(a)==fields(b);
    });
}
}

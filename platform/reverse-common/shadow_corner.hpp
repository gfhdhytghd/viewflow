#pragma once
#include "window_residency.hpp"
#include <optional>
#include <cmath>
#include <string_view>
#include <charconv>

namespace viewflow::reverse {
// A shadow hint only: never rewrite the decoded alpha or compositor body shape.
// Unknown, asymmetric and partially resident corners intentionally have no hint.
inline std::optional<unsigned> shadow_corner(unsigned atlas_width,const Tile& t,
    std::span<const uint8_t> alpha,unsigned logical_width,unsigned logical_height) {
    if(!(t.flags&16) || !t.body_width || !t.body_height || !logical_width || !logical_height)return {};
    const auto resident=resident_rect(t);
    const unsigned extent=std::min({64u,t.body_width/2,t.body_height/2});
    if(extent<4)return {};
    unsigned total=0,smallest=1000,largest=0;
    for(unsigned corner=0;corner<4;++corner) {
        auto sample=[&](unsigned x,unsigned y)->std::optional<bool> {
            x=t.body_x+((corner&1)?t.body_width-1-x:x);
            y=t.body_y+((corner&2)?t.body_height-1-y:y);
            if(x<resident.x || y<resident.y || x>=resident.x+resident.width || y>=resident.y+resident.height)return {};
            return tile_alpha(atlas_width,t,alpha,x,y)>=128;
        };
        unsigned best=0,best_error=~0u;
        for(unsigned radius=0;radius<extent;++radius) {
            unsigned error=0;
            for(unsigned i=0;i<extent;++i)for(unsigned edge: {0u,1u,3u})for(unsigned transpose=0;transpose<2;++transpose) {
                const unsigned x=transpose?edge:i,y=transpose?i:edge;
                const auto actual=sample(x,y);if(!actual)return {};
                const double dx=double(radius)-x-.5,dy=double(radius)-y-.5;
                const bool expected=x+.5>=radius || y+.5>=radius || dx*dx+dy*dy<=double(radius)*radius;
                error+=(*actual!=expected);
            }
            if(error<best_error){best_error=error;best=radius;}
        }
        // A few antialiased boundary pixels may differ; arbitrary masks do not
        // get approximated as a standard rounded rectangle.
        if(best_error>6 || best==extent-1)return {};
        total+=best;smallest=std::min(smallest,best);largest=std::max(largest,best);
    }
    if(largest-smallest>2)return {};
    const double sx=double(logical_width)/t.body_width,sy=double(logical_height)/t.body_height;
    if(std::abs(sx-sy)>.02*std::max(sx,sy))return {};
    return static_cast<unsigned>(std::lround(total*.25*sx*10));
}
inline std::optional<double> windows_shadow_radius(std::string_view app_id) {
    constexpr std::string_view prefix="ViewflowReverse-WindowsNative-r";
    if(!app_id.starts_with(prefix))return {};
    app_id.remove_prefix(prefix.size());
    const auto end=app_id.find('-');if(end==std::string_view::npos)return {};
    unsigned tenths=0;const auto result=std::from_chars(app_id.data(),app_id.data()+end,tenths);
    if(result.ec!=std::errc{} || result.ptr!=app_id.data()+end || tenths>640)return {};
    return tenths/10.;
}
}

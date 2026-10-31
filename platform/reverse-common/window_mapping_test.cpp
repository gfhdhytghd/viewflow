#include "window_surface.hpp"
#include "window_resize.hpp"
#include <cassert>
#include <cmath>
namespace vf=viewflow::reverse;
int main() {
    vf::WindowResize resize;
    resize.queue({10,20,800,600},1000);
    assert(!resize.ready(1099));
    resize.queue({10,20,1000,800},1090);
    assert(!resize.ready(1189) && resize.ready(1190));
    assert(resize.candidate->width==1000);
    resize.cancel();assert(!resize.ready(10000)); // fullscreen or successful send
    // A tiled 1000x800 proxy still displays an old 1600x900 Retina body.
    const auto fit=vf::fitted_body(1000,800,1600,900);
    assert(fit.x==0 && fit.y==118 && fit.body_width==1000 && fit.body_height==563);
    assert(!vf::body_point(fit,500,117));
    assert(vf::body_point(fit,500,400));
    assert(!vf::body_point(fit,500,681));
    // Negative parking origin, scale two, compositor gaps and borders do not
    // enter the local ratio. Source actual bounds win over requested geometry.
    const double px=(500-fit.x)*1600./fit.body_width;
    assert(-3072+vf::local_pointer(px,1600,800,true)==-2672);
    assert(-299+vf::local_pointer(450,900,450,true)==-74);
    assert(vf::local_pointer(1600,1600,800,true)==799.5);
    assert(vf::local_pointer(-40,1600,800,true)==0);
    assert(vf::local_pointer(-40,1600,800,false)==-20); // held drag
    assert(vf::local_pointer(800,1600,1200,true)==600); // resize before next frame
    for(auto dimensions : {std::pair{1600u,900u},std::pair{16384u,16384u}}) {
        const auto packed=std::bit_cast<unsigned>(vf::pointer_extent(dimensions.first,dimensions.second));
        assert((packed&65535u)==dimensions.first && (packed>>16)==dimensions.second);
    }
    const auto portrait=vf::fitted_body(600,1000,1600,900);
    assert(portrait.body_width==600 && portrait.body_height==338 && portrait.y==331);
    const auto fullscreen=vf::fitted_body(1920,1080,1600,900);
    assert(fullscreen.x==0 && fullscreen.y==0 && fullscreen.body_width==1920);
    assert(vf::fitted_body(0,0,1600,900).body_width==0);
}

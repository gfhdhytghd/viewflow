#include "window_frame_geometry.hpp"
#include "../reverse-common/window_scope.hpp"
#include <vector>
#include <cassert>
namespace vm=viewflow::macos;
int main() {
    namespace vf=viewflow::reverse;
    assert(!vf::needs_remote({0,0,800,600},{{0,0,1920,1200}},{{-3072,0,3072,1728}}));
    assert(vf::needs_remote({-100,0,800,600},{{0,0,1920,1200}},{{-3072,0,3072,1728}}));
    assert(!vf::needs_remote({0,0,800,600},{{0,0,400,1200},{400,0,400,1200}},{{-1,0,2,1200}}));
    assert(vf::needs_remote({0,0,800,600},{{0,0,300,1200},{400,0,400,1200}},{{300,0,100,1200}}));
    assert(!vf::needs_remote({2000,0,800,600},{{0,0,1920,1200}},{{-3072,0,3072,1728}}));
    for(double x : {-399., -400., -401., -399.})
        assert(vf::needs_remote({x,0,800,600},{{0,0,1920,1200}},{{-3072,0,3072,1728}})==(x < 0));
    assert(vf::needs_remote({0,-301,800,600},{{0,0,1920,1200}},{{0,-1200,1920,1200}}));
    assert(vf::needs_remote({0,-300,800,600},{{0,0,1920,1200}},{{0,-1200,1920,1200}}));
    // One point across any shared edge starts sharing, without waiting for
    // a window center that the native compositor may never allow to cross.
    const std::vector<vf::ScopeRect> host{{-100,-200,1000,800}};
    for(const auto& remote:std::vector<vf::ScopeRect>{{-1100,-200,1000,800},
        {900,-200,1000,800},{-100,-1000,1000,800},{-100,600,1000,800}}) {
        const bool horizontal=remote.x!=host[0].x;
        const double x=horizontal?(remote.x<host[0].x?-101:701):100;
        const double y=horizontal?0:(remote.y<host[0].y?-201:401);
        assert(vf::needs_remote({x,y,200,200},host,{remote}));
        assert(!vf::needs_remote({100,0,200,200},host,{remote}));
    }
    // A gap elsewhere in the window cannot turn covered remote pixels into
    // a crossing. Test the intersection, not unrelated uncovered window area.
    assert(!vf::needs_remote({0,0,800,600},{{0,0,300,1200}},{{0,0,100,1200}}));
    const unsigned width=200,height=140;
    const auto stride=width*4;
    std::vector<std::uint8_t> image(stride*height);
    for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x) {
        // Asymmetric framing and a translucent body, not an opaque-only test.
        image[y*stride+x*4+3]=(x>=37 && x<157 && y>=19 && y<109)?170:20;
    }
    auto body=vm::window_body(image.data(),stride,{0,0,width,height},120,90);
    assert(body.x==37 && body.y==19 && body.width==120 && body.height==90);
    body=vm::window_body(image.data(),stride,{10,7,180,125},120,90);
    assert(body.x==37 && body.y==19);
    assert(vm::window_body(image.data(),stride,{0,0,width,height},201,90).width==0);
    assert(vm::window_body(nullptr,stride,{0,0,width,height},120,90).width==0);
}

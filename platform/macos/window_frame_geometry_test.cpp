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

#include "window_residency.hpp"
#include <cassert>
#include <limits>
namespace vf=viewflow::reverse;
template<class F> void rejected(F f) {bool threw=false;try{f();}catch(const std::exception&){threw=true;}assert(threw);}
int main() {
    const auto full=vf::PixelRect{0,0,1000,800};
    assert(vf::viewport_resident(1000,800,-500,-100,1500,900)==full);
    assert((vf::viewport_resident(1000,800,600,0,1600,800)==vf::PixelRect{344,0,656,800}));
    assert((vf::viewport_resident(1000,800,400.2,20.8,500.1,40.2,0)==vf::PixelRect{400,20,101,21}));
    assert(vf::viewport_resident(1000,800,2000,0,3000,800)==vf::PixelRect{});
    assert(vf::clip_resident(1000,800,INT32_MAX,0,INT32_MAX,800)==vf::PixelRect{});
    vf::Frame f;f.width=4;f.height=4;f.color={1};
    vf::Tile t;t.id=1;t.width=1000;t.height=800;t.x=-700;t.y=20;t.atlas_x=1;t.atlas_y=1;
    vf::set_resident_rect(t,{600,400,2,2});f.tiles={t};
    auto copy=vf::unpack_frame(vf::pack_frame(f));
    assert(copy.tiles[0].width==1000 && copy.tiles[0].x==-700);
    assert((vf::resident_rect(copy.tiles[0])==vf::PixelRect{600,400,2,2}));
    std::vector<uint8_t> alpha(16);alpha[5]=255;alpha[6]=128;alpha[9]=1;
    assert(vf::tile_alpha(f,t,alpha,600,400)==255);
    assert(vf::tile_alpha(f,t,alpha,601,400)==128);
    assert(vf::tile_alpha(f,t,alpha,599,400)==0);
    assert(vf::tile_alpha(f,t,alpha,602,400)==0);
    vf::set_resident_rect(f.tiles[0],{});assert(vf::unpack_frame(vf::pack_frame(f)).tiles.size()==1);
    assert(vf::tile_alpha(f,f.tiles[0],alpha,600,400)==0);
    vf::set_resident_rect(f.tiles[0],{999,0,2,2});rejected([&]{vf::pack_frame(f);});
    vf::set_resident_rect(f.tiles[0],{0,0,0,2});rejected([&]{vf::pack_frame(f);});
    vf::set_resident_rect(f.tiles[0],{0,0,4,4});rejected([&]{vf::pack_frame(f);}); // atlas origin overrun
    f.tiles[0].atlas_x=0;f.tiles[0].atlas_y=0;vf::pack_frame(f);
    // Reveal uses the new mapping and completed frame alpha, never old slots.
    vf::set_resident_rect(f.tiles[0],{0,0,4,4});alpha[0]=17;
    assert(vf::tile_alpha(f,f.tiles[0],alpha,0,0)==17);
    auto input=vf::unpack_input(vf::pack_input({1,1,vf::InputKind::visibility,0,0,4,4}));
    assert(input.kind==vf::InputKind::visibility);
}

#include "wire.hpp"
#include "touchpad.hpp"
#include <cassert>
#include <functional>
namespace vf=viewflow::reverse;
int main() {
    const auto rejected=[](auto action){bool failed=false;try{action();}catch(const std::exception&){failed=true;}assert(failed);};
    std::vector<std::uint8_t> alpha(64*64,0);for(unsigned i=7;i<64*40;++i)alpha[i]=static_cast<std::uint8_t>(i%256);
    assert(vf::decode_alpha(vf::encode_alpha(alpha),alpha.size())==alpha);
    std::fill(alpha.begin(),alpha.end(),173);auto compressed=vf::encode_alpha(alpha);assert(compressed.size()<alpha.size());assert(vf::decode_alpha(compressed,alpha.size())==alpha);
    vf::Frame frame;frame.width=64;frame.height=64;frame.pts=123;frame.keyframe=true;
    frame.alpha=compressed;frame.color={0,0,0,1,0x26};frame.tiles.push_back({42,0,-6144,-780,64,64,0,0,"Example"});
    frame.tiles[0].flags=1;frame.tiles[0].geometry_ack=987;
    auto bytes=vf::pack_frame(frame);auto decoded=vf::unpack_frame(bytes);
    assert(decoded.tiles.size()==1 && decoded.tiles[0].id==42 && decoded.tiles[0].x==-6144 && decoded.tiles[0].flags==1 && decoded.tiles[0].geometry_ack==987 && decoded.color==frame.color);
    for(std::size_t size=0;size<bytes.size();++size)rejected([&]{vf::unpack_frame(std::span(bytes).first(size));});
    auto trailing=bytes;trailing.push_back(0);rejected([&]{vf::unpack_frame(trailing);});
    frame.tiles.push_back(frame.tiles[0]);rejected([&]{vf::pack_frame(frame);});frame.tiles.pop_back();
    frame.tiles[0].atlas_x=1;rejected([&]{vf::pack_frame(frame);});
    for(auto malformed:std::vector<std::vector<std::uint8_t>>{{},{2},{1,0,0,0,0,5},{1,255,255,255,255,0},{0,1},{1,1,0,0,0}})
        rejected([&]{vf::decode_alpha(malformed,4096);});
    auto input=vf::pack_input({42,7,vf::InputKind::geometry,-6100,-700,1000,700});assert(input.size()==40);
    auto event=vf::unpack_input(input);assert(event.sequence==7 && event.a==-6100 && event.c==1000);
    vf::TouchpadAssembler touchpad;
    for(int i=0;i<5;++i){auto contact=vf::unpack_input(vf::pack_input({42,static_cast<unsigned>(10+i),vf::InputKind::touchpad_contact,i,1000,2000,0}));assert(!touchpad.input(contact));}
    auto fingers=touchpad.input({42,15,vf::InputKind::touchpad_frame,16000,11000,5,0});assert(fingers && fingers->count==5 && fingers->contacts[4].id==4);
    assert(touchpad.input({42,16,vf::InputKind::touchpad_frame,16000,11000,0,0})->count==0);
    touchpad.input({42,17,vf::InputKind::touchpad_contact,1,1000,2000,0});
    rejected([&]{touchpad.input({43,18,vf::InputKind::touchpad_frame,16000,11000,1,0});});
    touchpad.input({42,19,vf::InputKind::touchpad_contact,1,17000,2000,0});
    rejected([&]{touchpad.input({42,20,vf::InputKind::touchpad_frame,16000,11000,1,0});});
    input[20]=255;rejected([&]{vf::unpack_input(input);});
}

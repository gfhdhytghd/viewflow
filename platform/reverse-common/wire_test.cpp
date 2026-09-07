#include "wire.hpp"
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
    input[20]=255;rejected([&]{vf::unpack_input(input);});
}

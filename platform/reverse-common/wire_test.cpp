#include "wire.hpp"
#include "backdrop.hpp"
#include "touchpad.hpp"
#include "native_touchpad.hpp"
#include "window_surface.hpp"
#include "window_scope.hpp"
#include <cassert>
#include <functional>
namespace vf=viewflow::reverse;
int main() {
    { // Variable backdrop records must stay separate from fixed-size input.
        vf::Backdrop b{4, 8, -1234000, 3000, 250000, 245000, 500, 490, {137,80,78,71}};
        const auto bytes = vf::pack_backdrop(b);
        const auto decoded = vf::unpack_backdrop(bytes);
        assert(decoded.id == 4 && decoded.x == -1234000 && decoded.png == b.png);
        auto truncated = bytes; truncated.pop_back();
        bool rejected = false; try { (void)vf::unpack_backdrop(truncated); } catch (...) { rejected = true; }
        assert(rejected);
        b.pixel_width = 6144; b.pixel_height = 3456;
        assert(vf::unpack_backdrop(vf::pack_backdrop(b)).pixel_width == 6144);
        b.pixel_width = 8193; rejected = false;
        try { (void)vf::pack_backdrop(b); } catch (...) { rejected = true; }
        assert(rejected);
    }

    const auto rejected=[](auto action){bool failed=false;try{action();}catch(const std::exception&){failed=true;}assert(failed);};
    std::vector<std::uint8_t> alpha(64*64,0);for(unsigned i=7;i<64*40;++i)alpha[i]=static_cast<std::uint8_t>(i%256);
    assert(vf::decode_alpha(vf::encode_alpha(alpha),alpha.size())==alpha);
    std::fill(alpha.begin(),alpha.end(),173);auto compressed=vf::encode_alpha(alpha);assert(compressed.size()<alpha.size());assert(vf::decode_alpha(compressed,alpha.size())==alpha);
    vf::Frame frame;frame.width=64;frame.height=64;frame.pts=123;frame.keyframe=true;
    frame.alpha=compressed;frame.color={0,0,0,1,0x26};frame.tiles.push_back({42,0,-6144,-780,64,64,0,0,"Example"});
    frame.tiles[0].flags=3;frame.tiles[0].geometry_ack=987;
    auto bytes=vf::pack_frame(frame);auto decoded=vf::unpack_frame(bytes);
    assert(decoded.tiles.size()==1 && decoded.tiles[0].id==42 && decoded.tiles[0].x==-6144 && decoded.tiles[0].flags==3 && decoded.tiles[0].geometry_ack==987 && decoded.color==frame.color);
    auto anchored=frame;anchored.tiles[0].flags=5;anchored.tiles[0].grab_x=1132;anchored.tiles[0].grab_y=28;
    auto fullscreen=frame;fullscreen.tiles[0].flags=32;
    assert(vf::unpack_frame(vf::pack_frame(fullscreen)).tiles[0].flags==32);
    const auto exit_fullscreen=vf::unpack_input(vf::pack_input({42,9,vf::InputKind::fullscreen,0,0,0,0}));
    assert(exit_fullscreen.kind==vf::InputKind::fullscreen && exit_fullscreen.a==0);
    auto anchor_bytes=vf::pack_frame(anchored);auto anchor_copy=vf::unpack_frame(anchor_bytes);
    assert(anchor_copy.tiles[0].grab_x==1132 && anchor_copy.tiles[0].grab_y==28);
    for(std::size_t size=0;size<anchor_bytes.size();++size)rejected([&]{vf::unpack_frame(std::span(anchor_bytes).first(size));});
    anchored.tiles[0].flags=4;rejected([&]{vf::pack_frame(anchored);});
    auto local_anchor=vf::unpack_input(vf::pack_input({42,8,vf::InputKind::proxy_drag_anchor,566000,14000,123,0}));
    assert(local_anchor.kind==vf::InputKind::proxy_drag_anchor && local_anchor.a==566000 && local_anchor.c==123);
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
    struct Snapshot {
        struct Contact {unsigned id,x,y;int pressure,major,minor,orientation;};
        unsigned count=2,width=16000,height=11490;
        std::array<Contact,5> contacts{{{100,8000,5745,9,80,40,-1},{101,16000,0,20,120,80,1}}};
    } snapshot;
    vf::NativeTouchpadEncoder native;
    std::vector<vf::NativeTouchpadReport> reports;
    auto emit=[&](const auto& report){reports.push_back(report);};
    native.frame(snapshot,1234,emit);
    assert(reports.size()==1 && reports[0][0]==2 && reports[0][1]==0);
    assert(reports[0][14]==0 && reports[0][15]==64 && reports[0][18]==9);
    assert(reports[0][19]==20 && reports[0][20]==10 && reports[0][22]==5);
    const auto original=reports[0];
    native.frame(snapshot,1235,emit);assert(reports.size()==1);
    snapshot.contacts[0].x+=100;native.frame(snapshot,1236,emit);
    assert(reports.size()==2 && reports.back()[12]==original[12]);
    snapshot.count=1;native.frame(snapshot,1237,emit);
    assert(reports.size()==4 && reports[2][13]==0 && reports[2][25]==0 && reports[3][0]==0);
    snapshot.count=0;native.frame(snapshot,1238,emit);assert(reports.size()==4);
    snapshot.count=2;native.frame(snapshot,1239,emit);assert(reports.back()[0]==2);
    snapshot.count=3;native.frame(snapshot,1240,emit);
    assert(reports.back()[0]==0 && reports[reports.size()-2][13]==0);
    const auto released_count=reports.size();
    snapshot.count=2;native.frame(snapshot,1241,emit);assert(reports.size()==released_count);
    snapshot.count=0;native.frame(snapshot,1242,emit);
    snapshot.count=2;native.frame(snapshot,1243,emit);assert(reports.back()[0]==2 && reports.size()==released_count+1);
    vf::NativeTouchpadAssembler assembly;vf::NativeTouchpadReport rebuilt{};
    auto chunk=[&](unsigned offset,unsigned window=42) {
        std::array<std::uint32_t,3> words{};
        for(unsigned j=0;j<3;++j)for(unsigned k=0;k<4;++k)words[j]|=std::uint32_t(original[offset+4*j+k])<<(8*k);
        auto wire=vf::pack_input({window,99,vf::InputKind::native_touchpad_chunk,int(offset),int(words[0]),int(words[1]),int(words[2])});
        assert(wire.size()==40);assert(!assembly.input(vf::unpack_input(wire),rebuilt));
    };
    for(unsigned offset=0;offset<72;offset+=12)chunk(offset);
    assert(assembly.input({42,100,vf::InputKind::native_touchpad_commit,72},rebuilt) && rebuilt==original);
    chunk(0);chunk(24);assert(!assembly.input({42,101,vf::InputKind::native_touchpad_commit,72},rebuilt));
    chunk(0);chunk(12,43);assert(!assembly.input({43,102,vf::InputKind::native_touchpad_commit,72},rebuilt));
    frame.tiles[0].atlas_x=0;frame.tiles[0].flags=8;
    assert(vf::unpack_frame(vf::pack_frame(frame)).tiles[0].flags==8);
    auto decorated=frame;
    auto& tile=decorated.tiles[0];tile.flags=16;tile.body_x=8;tile.body_y=12;tile.body_width=40;tile.body_height=36;
    tile.logical_width=20;tile.logical_height=18;tile.pixel_scale=2;
    auto decoration_copy=vf::unpack_frame(vf::pack_frame(decorated)).tiles[0];
    assert(decoration_copy.body_x==8 && decoration_copy.body_height==36 && decoration_copy.pixel_scale==2);
    assert(vf::logical_width(decoration_copy,1)==20 && vf::logical_height(decoration_copy,1)==18);
    auto surface=vf::surface_geometry(decoration_copy,20,18);
    assert(surface.width==32 && surface.height==32 && surface.x==4 && surface.y==6);
    assert(surface.body_width==20 && surface.body_height==18);
    assert(!vf::body_pixel(decoration_copy,7,12) && vf::body_pixel(decoration_copy,8,12));
    assert(!vf::body_pixel(decoration_copy,48,12) && !vf::body_pixel(decoration_copy,8,48));
    const auto body=vf::surface_geometry(decoration_copy,400,360);
    assert(body.body_width==400 && body.body_height==360);
    assert(!vf::body_point(body,body.x-0.01,body.y+20));
    assert(!vf::body_point(body,body.x+400,body.y+20));
    assert(!vf::body_point(body,body.x+20,body.y-0.01));
    assert(!vf::body_point(body,body.x+20,body.y+360));
    assert(vf::body_point(body,body.x,body.y));
    assert(vf::body_point(body,body.x+399.99,body.y+359.99));
    const auto cropped=vf::body_tile(decoration_copy);
    assert(cropped.atlas_x==decoration_copy.atlas_x+decoration_copy.body_x);
    assert(cropped.atlas_y==decoration_copy.atlas_y+decoration_copy.body_y);
    assert(cropped.width==decoration_copy.body_width && cropped.height==decoration_copy.body_height);
    const auto tiled=vf::body_surface(721,483);
    assert(tiled.x==0 && tiled.y==0 && tiled.width==721 && tiled.height==483);
    assert(!(cropped.flags&16));
    surface=vf::surface_geometry(decoration_copy,40,36);
    assert(surface.width==64 && surface.x==8 && surface.body_width==40);
    // A resized body retains its original desktop coordinates at each edge.
    assert(vf::body_pointer(8,8,40,20,-200,2)==-200);
    assert(vf::body_pointer(48,8,40,20,-200,2)==-160);
    assert(vf::body_pointer(28,8,40,20,-200,2)==-180);
    assert(vf::body_pointer(6,6,18,18,100,2)==100);
    { // Native-titlebar drag: delayed frames/proxy moves cannot move the mouse.
        const vf::PointerAnchor drag{3100, vf::body_pointer(20,0,600,600,-1200,2), 2};
        assert(drag.at(3100)==-1160);
        assert(drag.at(3130)==-1100);
        // A stale frame origin plus the newly moved proxy's relative point
        // would incorrectly snap the pointer back. Held motion ignores both.
        assert(vf::body_pointer(-10,0,600,600,-1200,2)==-1220);
        assert(drag.at(3130)==-1100);
        assert(drag.at(3110)==-1140);
        const vf::PointerAnchor resized{100,200,1.5};
        assert(resized.at(120)==230);
    }
    tile.body_width=57;rejected([&]{vf::pack_frame(decorated);});tile.body_width=40;
    tile.pixel_scale=0;rejected([&]{vf::pack_frame(decorated);});
    input[20]=255;rejected([&]{vf::unpack_input(input);});
    const std::vector<vf::MenuParent> parents{{10,{0,0,300,200}},{11,{100,100,400,300}}};
    assert(vf::menu_parent(150,150,parents)==10); // overlapping: frontmost
    assert(vf::menu_parent(480,350,parents)==11);
    assert(vf::menu_parent(550,350,parents)==11); // submenu beyond body edge
    assert(vf::menu_parent(10,10,{})==0);
}

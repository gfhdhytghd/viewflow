#include "stable_surface_layout.h"
#include <cassert>
#include <iostream>
using namespace viewflow;
int main(){
 windows_preview::AtlasFrameBinding a;
 a.width=1024;a.height=512;a.layout.stream={1,2};a.layout.geometry_epoch=3;a.layout.config_generation=4;a.layout.revision=5;
 a.layout.tiles={{{10,11},6,7,8,9,0,0,300,200},{{12,13},6,7,8,9,300,0,200,200}};
 a.layout.patches=std::vector<vfgp::AtlasPatch>{{0,0,0,0,0,300,200},{1,0,0,300,0,200,200}};a.opaque_patches={1,0};
 a.layout.desktop=vfgp::DesktopLayout{1,{0,0,1920000,1080000},{{{10,11},{0,0,300000,200000},true,2,0},{{12,13},{300000,0,200000,200000},true,1,0}}};
 auto b=a;b.identity=99;b.layout.source_ns=100;for(auto& t:b.layout.tiles){t.source_frame+=1;t.source_ns+=1;}
 assert(windows_preview::SameSurfaceLayout(a,b));
 unsigned cases=0;
 auto reject=[&](auto change){auto c=b;change(c);assert(!windows_preview::SameSurfaceLayout(a,c));++cases;};
 reject([](auto& c){++c.width;});reject([](auto& c){++c.layout.stream.first;});reject([](auto& c){++c.layout.geometry_epoch;});reject([](auto& c){++c.layout.config_generation;});reject([](auto& c){++c.layout.revision;});
 reject([](auto& c){++c.layout.tiles[1].window.second;});reject([](auto& c){++c.layout.tiles[1].placement_generation;});reject([](auto& c){++c.layout.tiles[1].geometry_epoch;});reject([](auto& c){++c.layout.tiles[1].x;});reject([](auto& c){++c.layout.tiles[1].height;});
 reject([](auto& c){c.layout.patches.reset();});reject([](auto& c){++c.layout.patches->back().source_y;});reject([](auto& c){c.opaque_patches[1]=1;});
 reject([](auto& c){c.layout.desktop.reset();});reject([](auto& c){++c.layout.desktop->topology_generation;});reject([](auto& c){++c.layout.desktop->viewport.width_millidip;});reject([](auto& c){++c.layout.desktop->windows[1].bounds.x_millidip;});reject([](auto& c){++c.layout.desktop->windows[1].z_order;});reject([](auto& c){++c.layout.desktop->windows[1].raise_serial;});reject([](auto& c){c.layout.desktop->windows[1].movable=false;});
 std::cout<<cases<<" changed mappings fall back; advancing frame identity preserves eligibility\n";
}

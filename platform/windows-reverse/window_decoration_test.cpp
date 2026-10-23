#include "window_decoration.hpp"
#include "../reverse-common/wire.hpp"
#include <cassert>
int main(){
 using namespace viewflow::reverse;
 assert(shadow_padding(96,false,true)==108);
 assert(shadow_padding(192,false,true)==216);
 assert(shadow_padding(192,true,true)==0);
 assert(shadow_padding(192,false,false)==0);
 // Native geometry keeps the original Windows physical body coordinate system.
 Frame f;f.color={0};f.width=256;f.height=256;f.tiles.push_back({});auto& t=f.tiles.back();
 t.id=1;t.x=-400;t.y=2400;t.width=248;t.height=148;t.flags=16;
 t.body_x=t.body_y=24;t.body_width=t.logical_width=200;t.body_height=t.logical_height=100;t.pixel_scale=1;
 validate(f);
 // Production now sends a body-only tile; local receivers own all shadows.
 t.body_x=t.body_y=0;t.width=t.body_width;t.height=t.body_height;
 validate(f);assert(t.width==t.logical_width && t.height==t.logical_height && t.pixel_scale==1);
}

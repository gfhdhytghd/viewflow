#include "frame_changes.hpp"
#include "../reverse-common/opaque_alpha.hpp"
#include "alpha_encode.hpp"
#include <cassert>
using namespace viewflow::reverse;
int main(){
 OpaqueAlphaCache masks;Frame f;f.width=8;f.height=6;
 Tile body{};body.width=8;body.height=6;f.tiles={body};
 const auto& opaque=masks.get(f);assert(encode_windows_alpha(opaque)==encode_windows_opaque_alpha(48));
 f.tiles[0].flags=16;f.tiles[0].body_x=2;f.tiles[0].body_y=1;f.tiles[0].body_width=4;f.tiles[0].body_height=3;
 const auto& mask=masks.get(f);const auto* ptr=mask.data();
 for(unsigned y=0;y<6;++y)for(unsigned x=0;x<8;++x)assert(mask[y*8+x]==((x>=2 && x<6 && y>=1 && y<4)?255:0));
 assert(masks.get(f).data()==ptr);

 FrameChangeTracker c;Tile t{1,0,10,20,6144,3456,0,0,"sample",0,0};std::vector<Tile> tiles{t};FrameChangeTracker::Versions v{{1,1}};
 assert(c.needs_frame(tiles,v,false,false));c.submitted(tiles,v);assert(!c.needs_frame(tiles,v,false,false));
 assert(c.needs_frame(tiles,v,true,false));assert(c.needs_frame(tiles,v,false,true));
 // New pixels, including a callback that races the prior GPU submission.
 auto next=v;next[1]=2;assert(c.needs_frame(tiles,next,false,false));c.submitted(tiles,v);assert(c.needs_frame(tiles,next,false,false));c.submitted(tiles,next);assert(!c.needs_frame(tiles,next,false,false));
 // Geometry, layout, title, owner, drag/IME flags, and acknowledgments still flow.
 for(int field=0;field<22;++field){auto changed=tiles;auto& a=changed[0];switch(field){case 0:++a.id;break;case 1:++a.owner;break;case 2:++a.x;break;case 3:++a.y;break;case 4:++a.width;break;case 5:++a.height;break;case 6:++a.atlas_x;break;case 7:++a.atlas_y;break;case 8:a.title+=" updated";break;case 9:++a.flags;break;case 10:++a.geometry_ack;break;case 11:++a.resident_x;break;case 12:++a.resident_y;break;case 13:++a.resident_width;break;case 14:++a.resident_height;break;case 15:++a.body_x;break;case 16:++a.body_y;break;case 17:++a.body_width;break;case 18:++a.body_height;break;case 19:++a.logical_width;break;case 20:++a.logical_height;break;case 21:++a.pixel_scale;break;}assert(c.needs_frame(changed,next,false,false));}
 // Closing the final window emits removal metadata; subsequent idle preserves it.
 assert(c.needs_frame({}, {},false,false));c.submitted({},{});assert(!c.needs_frame({}, {},false,false));assert(c.needs_frame({}, {},false,true));assert(c.needs_frame(tiles,next,false,false));
 // A tile whose source copy was unavailable must be retried, not marked consumed.
 c.submitted(tiles,{});assert(c.needs_frame(tiles,next,false,false));
}

#include "frame_changes.hpp"
#include <cassert>
using namespace viewflow::reverse;
int main(){
 FrameChangeTracker c;Tile t{1,0,10,20,6144,3456,0,0,"sample",0,0};std::vector<Tile> tiles{t};FrameChangeTracker::Versions v{{1,1}};
 assert(c.needs_frame(tiles,v,false,false));c.submitted(tiles,v);assert(!c.needs_frame(tiles,v,false,false));
 assert(c.needs_frame(tiles,v,true,false));assert(c.needs_frame(tiles,v,false,true));
 // New pixels, including a callback that races the prior GPU submission.
 auto next=v;next[1]=2;assert(c.needs_frame(tiles,next,false,false));c.submitted(tiles,v);assert(c.needs_frame(tiles,next,false,false));c.submitted(tiles,next);assert(!c.needs_frame(tiles,next,false,false));
 // Geometry, layout, title, owner, drag/IME flags, and acknowledgments still flow.
 for(int field=0;field<11;++field){auto changed=tiles;auto& a=changed[0];switch(field){case 0:++a.id;break;case 1:++a.owner;break;case 2:++a.x;break;case 3:++a.y;break;case 4:++a.width;break;case 5:++a.height;break;case 6:++a.atlas_x;break;case 7:++a.atlas_y;break;case 8:a.title+=" updated";break;case 9:++a.flags;break;case 10:++a.geometry_ack;break;}assert(c.needs_frame(changed,next,false,false));}
 // Closing the final window emits removal metadata; subsequent idle preserves it.
 assert(c.needs_frame({}, {},false,false));c.submitted({},{});assert(!c.needs_frame({}, {},false,false));assert(c.needs_frame({}, {},false,true));assert(c.needs_frame(tiles,next,false,false));
 // A tile whose source copy was unavailable must be retried, not marked consumed.
 c.submitted(tiles,{});assert(c.needs_frame(tiles,next,false,false));
}

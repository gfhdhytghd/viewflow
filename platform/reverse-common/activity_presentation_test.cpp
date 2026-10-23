#include "activity_presentation.hpp"
#include <cassert>
int main(){
    namespace vf=viewflow::reverse;
    vf::Frame frame;frame.codec=1;frame.width=frame.height=1;frame.pts=1;frame.keyframe=true;
    vf::Tile tile;tile.id=1;tile.width=tile.height=1;frame.tiles={tile};frame.alpha={0,255};frame.color={1};
    const auto old=vf::pack_frame(frame);assert(old[0]==1);
    frame.activity_epoch=1;frame.activity_lane=1;frame.activity_preferred=1;frame.activity_focus=2;frame.activity_members={1,2};
    const auto encoded=vf::pack_frame(frame);const auto decoded=vf::unpack_frame(encoded);
    assert(decoded.activity_epoch==1 && decoded.activity_members==frame.activity_members && decoded.activity_lane==1);
    viewflow::activity::Presentation p;assert(p.admit(frame));assert(p.accepts(frame,tile));assert(p.members(frame).contains(2));
    auto next=frame;next.activity_epoch=2;next.activity_preferred=2;
    assert(p.admit(next));assert(!p.accepts(next,tile));assert(!p.admit(frame));
    next.activity_lane=0;assert(p.admit(next));assert(p.accepts(next,tile));
    next.activity_epoch=3;next.activity_members={1};assert(p.admit(next));assert(!p.members(next).contains(2));
    vf::Tile parent=tile;parent.id=3;parent.owner=1;
    vf::Tile child=tile;child.id=4;child.owner=3;
    auto nested=frame;nested.activity_epoch=4;nested.activity_members={1,3,4};nested.activity_focus=1;
    nested.tiles={tile,parent,child};assert(p.admit(nested));assert(p.accepts(nested,child));
    nested.activity_lane=0;assert(p.admit(nested));assert(!p.accepts(nested,child));
    frame.activity_epoch=0;assert(vf::pack_frame(frame)==old);
    auto invalid=encoded;invalid[4]=2;bool threw=false;try{(void)vf::unpack_frame(invalid);}catch(...){threw=true;}assert(threw);
}

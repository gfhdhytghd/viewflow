#include "geometry_sync.hpp"
#include <cassert>
namespace vf=viewflow::reverse;
int main(){
 vf::Geometry a{10,20,400,300},b{20,30,400,300},c{30,40,500,350};
 vf::GeometrySync sync;
 assert(sync.observe(a,a,0,true)==vf::GeometryAction::apply_remote);sync.applied(a);
 assert(sync.observe(b,a,0,true)==vf::GeometryAction::send_local);sync.sent(10);
 // Old frames cannot undo either a Win+drag or a resize, even after a long stall.
 for(int i=0;i<10000;++i)assert(sync.observe(b,a,0,true)==vf::GeometryAction::none);
 assert(sync.observe(c,b,10,true)==vf::GeometryAction::send_local);sync.sent(11);
 assert(sync.observe(c,b,10,true)==vf::GeometryAction::none);
 assert(sync.observe(c,c,11,true)==vf::GeometryAction::none);
 assert(sync.observe(c,b,11,true)==vf::GeometryAction::apply_remote);sync.applied(b);
 // Tiling owns geometry permanently, including after Windows acknowledges.
 assert(sync.observe(c,b,11,false)==vf::GeometryAction::send_local);sync.sent(12);
 assert(sync.observe(c,b,12,false)==vf::GeometryAction::none);
 assert(sync.observe(a,b,12,false)==vf::GeometryAction::send_local);sync.sent(13);
 assert(sync.observe(a,b,13,false)==vf::GeometryAction::none);
 assert(sync.observe(a,b,13,true)==vf::GeometryAction::send_local);
}

#include "geometry_sync.hpp"
#include <cassert>
namespace vf=viewflow::reverse;
int main(){
 // A native translation confirms titlebar ownership once. Content clicks,
 // resizes, and receipts for our own old geometry must not initiate a move.
 vf::NativeMoveConfirmation confirmation;
 const vf::Geometry press{100,200,800,600};
 confirmation.begin(press,40);
 assert(!confirmation.observe(press,40));
 assert(confirmation.observe({110,205,800,600},40));
 assert(!confirmation.observe({120,210,800,600},40));
 confirmation.begin(press,40);
 assert(!confirmation.observe({110,205,810,600},40));
 assert(!confirmation.observe({120,210,800,600},40));
 confirmation.begin(press,40);
 assert(!confirmation.observe({110,205,800,600},41));
 confirmation.begin(press,41);confirmation.cancel();
 assert(!confirmation.observe({110,205,800,600},41));
 // Linux moves immediately while Mac is still rendering its first native
 // drag position. Old receipts cannot rewind that local motion or its release.
 vf::GeometrySync local_titlebar;
 assert(local_titlebar.observe(press,press,40,true)==vf::GeometryAction::apply_remote);
 local_titlebar.applied(press);
 const vf::Geometry following{180,240,800,600},late_mac{110,205,800,600};
 local_titlebar.sent(42);
 assert(local_titlebar.observe(following,late_mac,40,true,true)==vf::GeometryAction::send_local);
 local_titlebar.sent(43);
 assert(local_titlebar.observe(following,late_mac,42,true,true)==vf::GeometryAction::none);
 assert(local_titlebar.observe(following,late_mac,42,true,false)==vf::GeometryAction::none);
 assert(local_titlebar.observe(following,following,43,true,false)==vf::GeometryAction::none);
 // Scrolling overhang must not move the Windows backing across the seam.
 const vf::Geometry linux_monitor{0,0,3072,1728};
 const vf::Geometry overflow{2900,50,800,600};
 const auto backing=vf::tiled_backing_geometry(overflow,linux_monitor);
 assert(backing.x==2272 && backing.y==50 && backing.width==800);
 assert(backing.x+backing.width<=3072);
 assert(vf::tiled_backing_geometry({-500,50,800,600},linux_monitor).x==0);
 vf::GeometrySync tiled;
 assert(tiled.observe(overflow,backing,0,false)==vf::GeometryAction::send_local);
 tiled.sent(1);
 assert(tiled.observe(overflow,backing,1,false)==vf::GeometryAction::none);
 assert(tiled.observe(overflow,backing,1,true)==vf::GeometryAction::send_local);
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
 // Acknowledged remote frames cannot reposition a locally held native drag.
 assert(sync.observe(b,c,11,true,true)==vf::GeometryAction::none);
 assert(sync.observe(a,c,11,true,true)==vf::GeometryAction::send_local);sync.sent(12);
 assert(sync.observe(a,c,12,true,true)==vf::GeometryAction::none);
 assert(sync.observe(a,c,12,true,false)==vf::GeometryAction::apply_remote);sync.applied(c);
 // Tiling owns geometry permanently, including after Windows acknowledges.
 assert(sync.observe(c,b,11,false)==vf::GeometryAction::send_local);sync.sent(12);
 assert(sync.observe(c,b,12,false)==vf::GeometryAction::none);
 assert(sync.observe(a,b,12,false)==vf::GeometryAction::send_local);sync.sent(13);
 assert(sync.observe(a,b,13,false)==vf::GeometryAction::none);
 assert(sync.observe(a,b,13,true)==vf::GeometryAction::send_local);
 // Focus changes asymmetric framing while the native body remains stationary.
 // Observe actual outer geometry, never old outer coordinates plus new insets.
 vf::GeometrySync decoration;
 const vf::Geometry focused{944,962,1192,994},unfocused{977,984,1192,994};
 assert(decoration.observe(focused,focused,0,true)==vf::GeometryAction::apply_remote);
 decoration.applied(focused);
 assert(decoration.observe(focused,unfocused,0,true)==vf::GeometryAction::apply_remote);
 decoration.applied(unfocused);
 assert(decoration.observe(unfocused,unfocused,0,true)==vf::GeometryAction::none);
 assert(decoration.observe(unfocused,focused,0,true)==vf::GeometryAction::apply_remote);
 decoration.applied(focused);
 assert(decoration.observe(focused,focused,0,true)==vf::GeometryAction::none);
}

#include "../source/background_region.h"
#include <cassert>
#include <iostream>
using namespace viewflow::background;
int main(){
 Rect desktop{-1920,0,6144,3456};const auto kernel=hyprland_support(5,4);assert(kernel==182);
 Rect window{1000,700,1800,1300};auto p=plan(window,desktop,kernel);assert(p.bounds.contains(window)&&usable(p.bounds,desktop,kernel).contains(window));
 assert(p.bounds==Rect({690,390,2110,1610}));assert(!needs_urgent_refresh(p.bounds,window,desktop,kernel));
 for(int delta=-64;delta<=64;++delta){Rect moved=window;moved.left+=delta;moved.right+=delta;assert(usable(p.bounds,desktop,kernel).contains(moved));auto [x,y]=brush_offset(p.bounds,moved);assert(moved.left+x==p.bounds.left&&moved.top+y==p.bounds.top);}
 Rect moved{1100,700,1900,1300};assert(needs_urgent_refresh(p.bounds,moved,desktop,kernel));assert(usable(p.bounds,desktop,kernel).contains(moved)); // prefetch before miss
 Rect resized{1000,700,1850,1320};assert(usable(p.bounds,desktop,kernel).contains(resized));assert(brush_offset(p.bounds,resized)==brush_offset(p.bounds,window));
 auto fast=plan(window,desktop,kernel,6000,-3000);assert(fast.motion_x==400&&fast.motion_y==200);assert(fast.bounds.contains(p.bounds));
 Rect edge{-1924,-4,-1076,604};auto clipped=plan(edge,desktop,kernel);assert(clipped.bounds.left==desktop.left&&clipped.bounds.top==desktop.top);assert(usable(clipped.bounds,desktop,kernel).contains(clipped.visible));assert(!needs_urgent_refresh(clipped.bounds,edge,desktop,kernel));
 assert(brush_offset(clipped.bounds,edge)==std::pair<int64_t,int64_t>(4,4));
 assert(!plan({-2000,0,20000,1000},{-3000,0,25000,10000},kernel).fits_texture);
 assert(plan({10000,0,11000,1000},desktop,kernel).visible.empty());
 // Resize/move generations are simulated geometry only; no desktop input.
 unsigned checked=0;
 for(int x=-1800;x<5000;x+=71)for(int y=0;y<2200;y+=79){Rect r{x,y,x+800,y+600};auto q=plan(r,desktop,kernel,900,300);assert(q.fits_texture);assert(usable(q.bounds,desktop,kernel).contains(q.visible));assert(!needs_urgent_refresh(q.bounds,r,desktop,kernel));++checked;}
 std::cout<<"PASS background geometry cases="<<checked<<" kernel="<<kernel<<" input_injected=0\n";
}

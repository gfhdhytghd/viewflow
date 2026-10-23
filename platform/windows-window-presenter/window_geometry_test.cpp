#include "window_geometry.hpp"
#include <cassert>
#include <cmath>
int main() {
    viewflow::reverse::Tile tile;tile.width=2120;tile.height=1250;tile.flags=16;
    tile.body_x=10;tile.body_y=20;tile.body_width=2100;tile.body_height=1200;
    tile.logical_width=1050;tile.logical_height=600;tile.pixel_scale=2;tile.x=-2400;tile.y=-1800;
    const auto g=viewflow::portable::geometry(tile,1);
    assert(g.body_width==2100 && g.body_height==1200);
    assert(g.body_x==0 && g.body_y==0 && g.width==2100 && g.height==1200 && g.padding==216);
    // Negative source origins and asymmetric image padding must invert exactly.
    const double left=tile.x-g.body_x,top=tile.y-g.body_y;
    assert(left+g.body_x==tile.x && top+g.body_y==tile.y);
    assert(left+g.image_x+tile.body_x*g.pixel_x==tile.x);
    const auto scaled=viewflow::portable::geometry(tile,2);
    assert(scaled.body_width==1050 && scaled.body_height==600);
    const auto fullscreen=viewflow::portable::geometry(tile,1,true);
    assert(fullscreen.body_x==0 && fullscreen.body_y==0 && fullscreen.width==2100 && fullscreen.height==1200);
    assert(fullscreen.image_x+tile.body_x*fullscreen.pixel_x==0);
    assert(fullscreen.image_y+tile.body_y*fullscreen.pixel_y==0);
    tile.flags=18; const auto popup=viewflow::portable::geometry(tile,1);
    assert(popup.padding==0 && popup.width==2120 && popup.height==1250);
    tile.flags=0; const auto legacy=viewflow::portable::geometry(tile,2);
    assert(legacy.width==1060 && legacy.height==625 && legacy.body_x==0 && legacy.padding==0);
}

#include "output_float_geometry.hpp"
#include <cassert>
using namespace viewflow::hyprland;
int main() {
    const FloatRect work{3072,299,1920,1200};
    auto r=fitFloat({3100,350,800,600},work);
    assert(r.x==3100 && r.y==350 && r.width==800 && r.height==600);
    r=fitFloat({3084,372,2234,1033},work);
    assert(r.x==3072 && r.width==1920 && r.y==372 && r.height==1033);
    for(double x:{-5000.,0.,3100.,6000.}) for(double y:{-3000.,0.,500.,6000.})
      for(double w:{32.,800.,8000.}) for(double h:{32.,600.,8000.}) {
        r=fitFloat({x,y,w,h},work);
        assert(r.x>=work.x && r.y>=work.y && r.x+r.width<=work.x+work.width && r.y+r.height<=work.y+work.height);
      }
    r=fitFloat({-5000,-300,3000,1600},{-1920,-1080,1920,1080});
    assert(r.x==-1920 && r.y==-1080 && r.width==1920 && r.height==1080);
}

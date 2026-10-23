#include "gpu_shadow_math.cuh"
#include <cstdio>
#include <cstdlib>

using namespace viewflow::gpu;
void require(bool value) { if (!value) std::abort(); }
int main() {
  ShadowSnapshot s{0,0,100,80,10,10,80,60,10,5,8,2,3,26,26,26,200,false};
  require(shadowMultiplier(0,40,s)==0);
  require(shadowMultiplier(5,40,s)==.125);
  require(shadowMultiplier(50,40,s)==1);
  require(shadowMultiplier(0,0,s)==0);
  require(shadowInCutout(50,40,s));
  require(!shadowInCutout(10,10,s));
  for(int y=0;y<=80;y++) for(int x=0;x<=100;x++) {
    const double v=shadowMultiplier(x,y,s);
    require(v>=0&&v<=1);
    require(std::abs(v-shadowMultiplier(100-x,y,s))<1e-12);
    require(std::abs(v-shadowMultiplier(x,80-y,s))<1e-12);
  }
  unsigned char bright[]{200,100,80,100};
  repairShadowPixel(bright,5,40,false,s);
  require(bright[0]==200&&bright[3]==100);
  unsigned char reconstruct[]{13,13,13,100};
  repairShadowPixel(reconstruct,-1,40,false,s);
  require(reconstruct[0]==26&&reconstruct[3]==50);
  unsigned char clear[]{0,0,0,0};
  s.sharp=true; repairShadowPixel(clear,5,40,false,s);
  require(clear[0]==26&&clear[3]==200);
  unsigned char inside[]{0,0,0,0};
  repairShadowPixel(inside,50,40,true,s);
  require(inside[3]==0);
  std::puts("PASS shadow math host fixtures (GPU equivalence pending)");
}

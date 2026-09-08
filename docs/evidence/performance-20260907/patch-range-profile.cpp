
#include "atlas_record.h"
#include <chrono>
#include <cstdio>
using namespace viewflow::vfgp;
volatile uint64_t checksum;
int main() {
 for(unsigned tiles:{1u,8u,32u,128u}) {
  std::vector<AtlasPatch> patches;
  for(unsigned t=0;t<tiles;++t) for(unsigned p=0;p<128;++p)
   patches.push_back({t,p*128,0,p*128,t*128,128,128});
  for(unsigned mode:{0u,1u}) {
   const auto start=std::chrono::steady_clock::now();uint64_t sum=0;
   for(unsigned repeat=0;repeat<500;++repeat) for(unsigned t=0;t<tiles;++t) {
    if(mode) {auto range=PatchesForTile(patches,t);sum+=range.size()+range.back().source_x;}
    else {std::vector<AtlasPatch> selected;for(auto p:patches)if(p.tile_index==t)selected.push_back(p);sum+=selected.size()+selected.back().source_x;}
   }
   checksum=sum;
   std::printf("tiles=%u patches=%zu mode=%s ns_per_frame=%lld checksum=%llu\n",tiles,patches.size(),mode?"range":"scan",(long long)std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-start).count()/500,(unsigned long long)sum);
  }
 }
}

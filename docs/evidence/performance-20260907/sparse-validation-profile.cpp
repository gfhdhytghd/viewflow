#ifdef VIEWFLOW_BASELINE
#include "/tmp/viewflow-atlas-record-before-sweep.h"
#else
#include "atlas_record.h"
#endif
#include <chrono>
#include <cstdio>
using namespace viewflow::vfgp;
int main() {
 for(uint32_t count:{128u,1024u,4096u,16384u,32768u}) {
  std::vector<uint8_t> bytes(8+28*count);
  auto put=[&](size_t at,uint32_t v){for(int i=0;i<4;++i)bytes[at+i]=uint8_t(v>>((3-i)*8));};
  put(0,count);
  for(uint32_t i=0;i<count;++i) {
   size_t at=8+28*i;
   for(auto v:{0u,(i%128)*128,(i/128)*128,(i%128)*128,(i/128)*128,128u,128u}) {put(at,v);at+=4;}
  }
  const auto start=std::chrono::steady_clock::now();size_t sum=0;
  for(int repeat=0;repeat<5;++repeat) {
   AtlasLayout layout;layout.tiles.resize(1);layout.tiles[0].width=16384;layout.tiles[0].height=32768;
   if(!DecodeSparsePatches(bytes,16384,32768,layout)) return 1;
   sum+=layout.patches->size();
  }
  std::printf("patches=%u mean_us=%lld checksum=%zu\n",count,(long long)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count()/5,sum);
 }
}

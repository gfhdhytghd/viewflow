#include "atlas_record.h"
#include <cassert>
#include <random>
using namespace viewflow::vfgp;
static bool check(std::vector<AtlasPatch> patches) {
  std::sort(patches.begin(),patches.end(),[](auto a,auto b){return std::tuple{a.tile_index,a.source_y,a.source_x}<std::tuple{b.tile_index,b.source_y,b.source_x};});
  bool expected=true;
  for(size_t i=0;i<patches.size();++i)for(size_t j=0;j<i;++j) {
    const auto p=patches[i],q=patches[j];
    if(p.tile_index==q.tile_index && p.source_x<uint64_t(q.source_x)+q.width &&
       q.source_x<uint64_t(p.source_x)+p.width && p.source_y<uint64_t(q.source_y)+q.height &&
       q.source_y<uint64_t(p.source_y)+p.height) expected=false;
  }
  std::vector<uint8_t> bytes(8+28*patches.size());
  auto put=[&](size_t at,uint32_t v){for(int i=0;i<4;++i)bytes[at+i]=uint8_t(v>>((3-i)*8));};
  put(0,uint32_t(patches.size()));
  for(size_t i=0;i<patches.size();++i) {
    auto& p=patches[i];p.x=uint32_t(i%128)*128;p.y=uint32_t(i/128)*128;
    size_t at=8+i*28;
    for(auto v:{p.tile_index,p.source_x,p.source_y,p.x,p.y,p.width,p.height}) {put(at,v);at+=4;}
  }
  AtlasLayout layout;layout.tiles.resize(4);
  for(auto& tile:layout.tiles){tile.width=UINT32_MAX;tile.height=UINT32_MAX;}
  const bool actual=DecodeSparsePatches(bytes,16384,16384,layout);
  assert(actual==expected);
  if(actual)assert(*layout.patches==patches);
  return actual;
}
int main() {
  assert(check({}));
  assert(check({{0,0,0,0,0,128,128},{0,128,0,0,0,128,128},{0,0,128,0,0,128,128}}));
  assert(!check({{0,0,0,0,0,128,128},{0,127,127,0,0,128,128}}));
  assert(check({{0,0,0,0,0,128,128},{1,0,0,0,0,128,128}}));
  assert(check({{0,UINT32_MAX-128,UINT32_MAX-128,0,0,128,128}}));
  // Expiry follows rectangle bottoms, not insertion order; shorter later
  // rectangles may expire while a tall earlier rectangle remains active.
  assert(check({{0,0,0,0,0,10,128},{0,10,1,0,0,10,1},{0,10,2,0,0,10,126}}));
  assert(!check({{0,0,0,0,0,10,128},{0,10,1,0,0,10,1},{0,9,2,0,0,10,126}}));
  std::mt19937 random(71231);
  for(unsigned trial=0;trial<10000;++trial) {
    std::vector<AtlasPatch> patches;
    for(unsigned i=0,n=random()%300;i<n;++i) {
      const bool grid=trial%2;
      patches.push_back({uint32_t(random()%4),uint32_t(grid?(i%10)*128:random()%512),
        uint32_t(grid?(i/10)*128:random()%512),0,0,uint32_t(1+random()%128),uint32_t(1+random()%128)});
    }
    check(std::move(patches));
  }
}

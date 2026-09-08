#include "sparse_coalesce.h"
#include <cassert>
#include <map>
#include <random>
using namespace viewflow;
using namespace viewflow::windows_preview;
using Pixel=std::tuple<uint32_t,uint32_t,uint32_t>;
using Sample=std::tuple<uint32_t,uint32_t,uint8_t>;
static auto coverage(std::span<const vfgp::AtlasPatch> patches,std::span<const uint8_t> opaque) {
  std::map<Pixel,Sample> result;
  for(size_t i=0;i<patches.size();++i) {
    const auto& p=patches[i];
    for(uint32_t y=0;y<p.height;++y)for(uint32_t x=0;x<p.width;++x)
      assert(result.emplace(Pixel{p.tile_index,p.source_x+x,p.source_y+y},Sample{p.x+x,p.y+y,opaque.empty()?0:opaque[i]}).second);
  }
  return result;
}
int main() {
  std::vector<vfgp::AtlasPatch> grid;
  for(uint32_t y=0;y<8;++y)for(uint32_t x=0;x<8;++x)grid.push_back({0,x*4,y*4,8+x*4,12+y*4,4,4});
  std::vector<uint8_t> opaque(grid.size(),1);
  bool rejected=false;
  try {CoalesceSparsePatches(grid,std::span<const uint8_t>(opaque).first(1));}catch(const std::runtime_error&){rejected=true;}
  assert(rejected);
  auto merged=CoalesceSparsePatches(grid,opaque);
  assert(merged.patches.size()==1 && merged.patches[0].width==32 && merged.patches[0].height==32);
  assert(coverage(grid,opaque)==coverage(merged.patches,merged.opaque));
  auto missing=grid;missing.erase(missing.begin()+9);
  merged=CoalesceSparsePatches(missing);assert(merged.patches.size()>1 && merged.opaque.empty());
  assert(coverage(missing,{})==coverage(merged.patches,{}));
  auto overlapping=grid;overlapping[1].source_x=2;
  assert(CoalesceSparsePatches(overlapping).patches==overlapping);
  auto overflow=grid;overflow[0].x=UINT32_MAX;
  assert(CoalesceSparsePatches(overflow).patches==overflow);
  std::vector<vfgp::AtlasPatch> large;
  for(uint32_t y=0;y<128;++y)for(uint32_t x=0;x<256;++x)large.push_back({0,x,y,x+8,y+12,1,1});
  merged=CoalesceSparsePatches(large);
  assert(merged.patches.size()==1 && merged.patches[0].width==256 && merged.patches[0].height==128);
  assert(coverage(large,{})==coverage(merged.patches,{}));
  std::mt19937 random(42);
  for(unsigned trial=0;trial<200;++trial) {
    auto patches=grid;
    for(size_t i=0;i<patches.size();++i) {
      opaque[i]=uint8_t(random()%2);
      if(random()%4==0)patches[i].x+=64;
      if(random()%5==0)patches[i].tile_index=1;
    }
    // Reversed traversal also exercises source order independent unions.
    if(trial%2) {std::reverse(patches.begin(),patches.end());std::reverse(opaque.begin(),opaque.end());}
    merged=CoalesceSparsePatches(patches,opaque);
    assert(coverage(patches,opaque)==coverage(merged.patches,merged.opaque));
  }
}

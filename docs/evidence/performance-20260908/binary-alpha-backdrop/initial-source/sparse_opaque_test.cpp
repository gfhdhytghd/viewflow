#include "sparse_opaque.h"
#include <cassert>
#include <limits>
int main() {
  using viewflow::windows_preview::OpaqueSparsePatches;
  for(size_t length=0;length<40;++length) {
    std::vector<uint8_t> row(length+3,255);
    const auto view=std::span(row).subspan(3,length);
    assert(viewflow::windows_preview::AllOpaqueAlpha(view));
    for(size_t index=0;index<length;++index)for(unsigned value=0;value<255;++value) {
      view[index]=uint8_t(value);
      assert(!viewflow::windows_preview::AllOpaqueAlpha(view));
      view[index]=255;
    }
  }
  std::vector<uint8_t> alpha(32 * 24, 255);
  std::vector<viewflow::vfgp::AtlasPatch> patches{{0,0,0,4,4,8,8}, {0,8,0,16,4,8,8}, {0,16,0,0,0,4,4}};
  assert((OpaqueSparsePatches(alpha,32,24,patches)==std::vector<uint8_t>{1,1,0}));
  alpha[8 * 32 + 8] = 254;
  assert((OpaqueSparsePatches(alpha,32,24,patches)==std::vector<uint8_t>{0,1,0}));
  alpha[8 * 32 + 8] = 255;
  alpha[2 * 32 + 2] = 0; // Halo, outside the visible source rectangle.
  assert(OpaqueSparsePatches(alpha,32,24,patches)[0]==0);
  assert((OpaqueSparsePatches({},32,24,patches)==std::vector<uint8_t>{0,0,0}));
  patches[0].x=std::numeric_limits<uint32_t>::max();
  assert(OpaqueSparsePatches(alpha,32,24,patches)[0]==0);
  // A remapped patch follows its atlas alpha, not its destination coordinates.
  patches[0]={0,1000,1000,16,4,8,8};
  assert(OpaqueSparsePatches(alpha,32,24,patches)[0]==1);
}

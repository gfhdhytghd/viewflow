#include "sparse_atlas_plan.hpp"
#include <cassert>
using namespace viewflow::gpu;
int main() {
  SparseCell clipped{0,0,0,128,128,-128,0,0,CellAlpha::Opaque,0};
  assert(!clipSparseCell(clipped,0,0,0,128));
  assert(clipSparseCell(clipped,64,0,64,128));
  assert(clipped.sourceX==64 && clipped.sceneX==-64 && clipped.width==64);
  assert(planSparseAtlas({clipped},128,128,false).storedPixels==8192);
  SparseCell bottom{0,0,0,128,128,0,0,0,CellAlpha::Opaque,0};
  SparseCell top{1,0,0,128,128,0,0,1,CellAlpha::Opaque,0};
  auto p = planSparseAtlas({bottom,top},128,128,false);
  assert(p.fits && p.draws.size()==1 && p.storedPixels==16384 && p.occludedPixels==16384);
  top.alpha=CellAlpha::Mixed;
  p=planSparseAtlas({bottom,top},128,128,false);
  assert(!p.fits && p.draws.size()==2 && p.requiredHeight==256);
  p=planSparseAtlas({bottom,top},128,128,true);
  assert(p.fits && p.draws.size()==1 && p.draws[0].layers.size()==2);
  assert(p.draws[0].layers[0].source==0 && p.draws[0].patch.source==1);
  top.alpha=CellAlpha::Empty;
  p=planSparseAtlas({bottom,top},128,128,false);
  assert(p.draws.size()==1 && p.emptyPixels==16384);
  top.alpha=CellAlpha::Opaque; top.width=64;
  p=planSparseAtlas({bottom,top},256,128,true);
  assert(p.draws.size()==2); // rounded/boundary partial coverage cannot hide full lower cell
  top.width=128; top.grid=1;
  assert(planSparseAtlas({bottom,top},256,128,true).draws.size()==2);
  top.grid=0; top.sceneX=-128;
  assert(planSparseAtlas({bottom,top},256,128,false).draws.size()==2);
  // A moved upper layer reveals a newly transmitted lower cell immediately.
  top.sceneX=128;
  p=planSparseAtlas({bottom,top},256,128,false);
  assert(p.storedPixels==32768 && p.draws.size()==2);
  // A translucent edge keeps the lower opaque neighbor needed by blur.
  top.sceneX=0;top.alpha=CellAlpha::Opaque;
  auto edge=top;edge.sourceX=128;edge.sceneX=128;edge.alpha=CellAlpha::Mixed;
  assert(planSparseAtlas({bottom,top,edge},384,128,false,128).draws.size()==3);
  // Unknown/mixed coverage and separated grids cannot authorize occlusion.
  bottom.alpha=CellAlpha::Mixed; top.sceneX=0; top.alpha=CellAlpha::Mixed;
  assert(planSparseAtlas({bottom,top},256,128,false).draws.size()==2);
}

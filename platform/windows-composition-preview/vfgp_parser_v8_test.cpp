#include "vfgp_parser.h"
#include <cassert>
using namespace viewflow::vfgp;
static void put(std::vector<uint8_t>& b,size_t at,uint64_t v,size_t n=4) {
  for(size_t i=0;i<n;++i)b[at+i]=uint8_t(v>>((n-i-1)*8));
}
static std::vector<uint8_t> fixture(bool desktop=false,bool hidden=false) {
  const size_t atlas=176, desktop_bytes=desktop?104:0, patch_at=atlas+desktop_bytes;
  const size_t header=patch_at+8+(hidden?0:28), payload=36;
  std::vector<uint8_t>b(header+payload);
  b[0]='V';b[1]='F';b[2]='G';b[3]='P';b[4]=8;
  put(b,8,header);put(b,12,payload);put(b,16,1,8);put(b,24,4);put(b,28,2);put(b,32,4);put(b,36,32);
  put(b,40,1000,8);put(b,48,10000,8);put(b,64,9,8);put(b,72,3,8);put(b,80,4,8);put(b,88,5,8);
  put(b,96,100,8);put(b,104,1);put(b,108,desktop?7:3);
  put(b,120,2,8);put(b,128,5,8);put(b,136,3,8);put(b,144,7,8);put(b,152,100,8);
  put(b,168,1024);put(b,172,768); // full window is much larger than the coded atlas
  if(desktop) {
    put(b,atlas,8,8);put(b,atlas+8,uint64_t(-3000),8);put(b,atlas+16,4000,8);
    put(b,atlas+24,8000,8);put(b,atlas+32,6000,8);put(b,atlas+40,1);
    put(b,atlas+56,2,8);put(b,atlas+64,uint64_t(-2000),8);put(b,atlas+72,4500,8);
    put(b,atlas+80,5000,8);put(b,atlas+88,4000,8);put(b,atlas+96,3);put(b,atlas+100,7);
  }
  put(b,patch_at,hidden?0:1);
  if(!hidden) { put(b,patch_at+12,256);put(b,patch_at+16,128);put(b,patch_at+28,4);put(b,patch_at+32,2); }
  b[header+4]='V';b[header+5]='F';b[header+6]='A';b[header+7]='R';b[header+8]=1;
  put(b,header+12,4);put(b,header+16,2);put(b,header+20,8,8);
  for(size_t i=header+28;i<b.size();++i)b[i]=255;
  return b;
}
int main() {
  // Include gaps, an empty atlas, and the largest tile id without incrementing
  // it to find the upper bound. Borrowed ranges must retain patch identity.
  std::vector<AtlasPatch> indexed{{1,0,0,0,0,128,128}, {1,128,0,128,0,128,128},
      {3,0,0,256,0,128,128}, {UINT32_MAX,0,0,384,0,128,128}};
  assert(PatchesForTile({}, 0).empty());
  for(uint32_t tile : {0u,1u,2u,3u,4u,UINT32_MAX}) {
    std::vector<AtlasPatch> expected;
    for(const auto& patch : indexed) if(patch.tile_index==tile) expected.push_back(patch);
    const auto selected=PatchesForTile(indexed,tile);
    assert(std::equal(selected.begin(),selected.end(),expected.begin(),expected.end()));
    if(!selected.empty()) assert(selected.data()>=indexed.data() && selected.data()<indexed.data()+indexed.size());
  }
  for(bool desktop:{false,true})for(bool hidden:{false,true}) {
    auto b=fixture(desktop,hidden);std::vector<Frame> frames;
    Parser parser(4096,true,true,true,true);
    for(auto c:b)assert(parser.Push({&c,1},&frames));
    assert(parser.Finish()&&frames.size()==1&&frames[0].atlas->patches);
    assert(frames[0].atlas->patches->size()==(hidden?0:1));
    assert(frames[0].atlas->tiles[0].width==1024);
    assert(frames[0].atlas->desktop.has_value()==desktop);
    if(!hidden)assert(frames[0].atlas->patches->front().source_x==256);
  }
  for(int mutation=0;mutation<5;++mutation) {
    auto b=fixture();
    if(mutation==0)put(b,184,1); // absent tile index
    if(mutation==1)put(b,188,1024); // source crop overflow
    if(mutation==2)put(b,196,1); // nonaligned/out-of-bounds atlas slot
    if(mutation==3)put(b,176,32769); // excessive patch count
    if(mutation==4)b[4]=5; // sparse data cannot enter a legacy parser path
    Parser parser(4096,true,true,true,true);std::vector<Frame> frames;
    assert(!parser.Push(b,&frames)&&frames.empty());
  }
  auto b=fixture(true);Parser disabled(4096,true,true,true,false);std::vector<Frame> frames;
  assert(!disabled.Push(b,&frames));
}

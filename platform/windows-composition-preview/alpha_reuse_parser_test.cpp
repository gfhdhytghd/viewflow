#include "vfgp_parser.h"
#include <algorithm>
#include <cassert>
#include <iostream>
using namespace viewflow::vfgp;
static void u32(std::vector<uint8_t>& b,uint32_t n) { for(int i=24;i>=0;i-=8)b.push_back(uint8_t(n>>i)); }
static void u64(std::vector<uint8_t>& b,uint64_t n) { u32(b,uint32_t(n>>32));u32(b,uint32_t(n)); }
static auto alpha(uint32_t w,uint32_t h,std::vector<uint8_t> payload) {
  std::vector<uint8_t> b{'V','F','A','R',1,1,0,0};u32(b,w);u32(b,h);u64(b,uint64_t(w)*h);
  b.insert(b.end(),payload.begin(),payload.end());return b;
}
static auto record(uint64_t id,uint32_t w,uint32_t h,std::vector<uint8_t> a) {
  std::vector<uint8_t>b{'V','F','G','P',2,0,0,0};u32(b,40);u32(b,uint32_t(a.size()+1));
  u64(b,id);u32(b,w);u32(b,h);u32(b,1);u32(b,uint32_t(a.size()));b.push_back(uint8_t(id));
  b.insert(b.end(),a.begin(),a.end());return b;
}
static void push(Parser& p,const std::vector<uint8_t>& wire,std::vector<Frame>& frames) {
  for(size_t i=0;i<wire.size();i+=3)
    assert(p.Push(std::span(wire).subspan(i,(std::min)(size_t(3),wire.size()-i)),&frames));
}
int main() {
  std::vector<Frame> frames;
  {
    Parser p(1024,false,false,false,false,true);
    push(p,record(1,2,2,alpha(2,2,{0x83,17})),frames);
    push(p,record(2,2,2,alpha(2,2,{0x83,17})),frames);
    assert(frames.size()==2 && frames[1].alpha_reused);
    assert(frames[0].shared_alpha == frames[1].shared_alpha);
    assert(frames[0].identity==1 && frames[1].identity==2 && frames[1].color_au[0]==2);
    push(p,record(3,2,2,alpha(2,2,{0x83,29})),frames);
    assert(!frames[2].alpha_reused && frames[2].shared_alpha!=frames[1].shared_alpha);
    push(p,record(4,1,4,alpha(1,4,{0x83,29})),frames);
    assert(!frames[3].alpha_reused && frames[3].width==1);
    assert(p.Finish());
    // A stale encoding cannot hide a mismatched outer frame shape.
    auto malformed=record(5,2,2,alpha(1,4,{0x83,29}));
    assert(!p.Push(malformed,&frames));
    assert(frames.size()==4);
  }
  assert(std::ranges::equal(frames[0].Alpha(),std::vector<uint8_t>(4,17)));
  assert(std::ranges::equal(frames[2].Alpha(),std::vector<uint8_t>(4,29)));
  // A changed malformed run must still be decoded and rejected after a cache hit.
  Parser invalid(1024,false,false,false,false,true);std::vector<Frame> f;
  push(invalid,record(1,2,2,alpha(2,2,{0x83,17})),f);
  push(invalid,record(2,2,2,alpha(2,2,{0x83,17})),f);
  assert(!invalid.Push(record(3,2,2,alpha(2,2,{0x84,17})),&f));
  assert(f.size()==2 && std::ranges::equal(f[0].Alpha(),std::vector<uint8_t>(4,17)));
  std::cout << "PASS exact encoded reuse, changed alpha/shape, fragmentation, malformed data and retained snapshots\n";
}

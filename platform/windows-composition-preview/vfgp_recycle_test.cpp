#include "vfgp_parser.h"
#include <iostream>
using namespace viewflow::vfgp;
static void u32(std::vector<uint8_t>& b, uint32_t n) {
  for (int shift = 24; shift >= 0; shift -= 8) b.push_back(uint8_t(n >> shift));
}
static std::vector<uint8_t> wire(uint32_t id, uint32_t width, uint8_t alpha) {
  std::vector<uint8_t> b{'V','F','G','P',1,0,0,0};
  u32(b,40); u32(b,1+width); u32(b,0); u32(b,id);
  u32(b,width); u32(b,1); u32(b,1); u32(b,width);
  b.push_back(1); b.insert(b.end(),width,alpha); return b;
}
static std::vector<uint8_t> rle_wire(uint32_t id) {
  std::vector<uint8_t> alpha{'V','F','A','R',1,1,0,0};
  u32(alpha,1024); u32(alpha,1); u32(alpha,0); u32(alpha,1024);
  for (int i=0;i<8;++i) { alpha.push_back(255); alpha.push_back(9); }
  std::vector<uint8_t> b{'V','F','G','P',2,0,0,0};
  u32(b,40); u32(b,uint32_t(1+alpha.size())); u32(b,0); u32(b,id);
  u32(b,1024); u32(b,1); u32(b,1); u32(b,uint32_t(alpha.size()));
  b.push_back(1); b.insert(b.end(),alpha.begin(),alpha.end()); return b;
}
int main() {
  Parser parser(4096);
  std::vector<Frame> frames;
  if (!parser.Push(wire(1,1024,231),&frames) || frames.size()!=1) return 1;
  auto* allocation=frames[0].alpha.data();
  parser.RecycleAlpha(std::move(frames[0].alpha)); frames.clear();
  if (!parser.Push(wire(2,2,17),&frames) || frames.size()!=1) return 2;
  if (frames[0].alpha.data()!=allocation || frames[0].alpha!=std::vector<uint8_t>{17,17}) return 3;
  parser.RecycleAlpha(std::move(frames[0].alpha)); frames.clear();
  if (!parser.Push(rle_wire(3),&frames) || frames[0].alpha.data()!=allocation ||
      frames[0].alpha!=std::vector<uint8_t>(1024,9) || !parser.Finish()) return 4;
  // Oversize donated capacity is not retained; malformed input still poisons.
  parser.RecycleAlpha(std::vector<uint8_t>(8192,255));
  if (parser.Push(wire(3,2,255),&frames) || !parser.error()) return 5;
  std::cout << "PASS bounded alpha reuse and exact resized contents\n";
}

#include "vfgp_parser.h"
#include <fstream>
#include <iterator>
#include <iostream>
#include <array>

using namespace viewflow::vfgp;
static void put(std::vector<uint8_t>& bytes, size_t at, uint64_t value, size_t size) {
  for (size_t i = 0; i < size; ++i) bytes[at + i] = uint8_t(value >> ((size - i - 1) * 8));
}
static std::vector<uint8_t> fixture() {
  std::vector<uint8_t> bytes(270);
  bytes[0]='V'; bytes[1]='F'; bytes[2]='G'; bytes[3]='P'; bytes[4]=5;
  put(bytes,8,240,4); put(bytes,12,30,4); put(bytes,16,9,8);
  put(bytes,24,4,4); put(bytes,28,2,4); put(bytes,32,4,4); put(bytes,36,26,4);
  put(bytes,40,1000,8); put(bytes,48,10'000'000,8); put(bytes,64,99,8);
  put(bytes,72,3,8); put(bytes,80,4,8); put(bytes,88,5,8); put(bytes,96,100,8);
  put(bytes,104,2,4); put(bytes,108,3,4);
  for (size_t i = 0; i < 2; ++i) {
    const size_t at = 112 + i * 64;
    put(bytes,at+8,i+1,8); put(bytes,at+16,5,8); put(bytes,at+24,3,8);
    put(bytes,at+32,i+7,8); put(bytes,at+40,i+100,8);
    put(bytes,at+48,i*2,4); put(bytes,at+56,2,4); put(bytes,at+60,2,4);
  }
  bytes[242]=1; bytes[243]=0x65;
  bytes[244]='V'; bytes[245]='F'; bytes[246]='A'; bytes[247]='R'; bytes[248]=1; bytes[249]=1;
  put(bytes,252,4,4); put(bytes,256,2,4); put(bytes,260,8,8); bytes[268]=0x87; bytes[269]=7;
  return bytes;
}
#include <cassert>
static std::vector<uint8_t> activity(unsigned lane,uint64_t identity) {
  auto bytes=fixture();constexpr size_t base=240,extension=84;
  bytes.insert(bytes.begin()+base,extension,0);
  bytes[4]=11;bytes[5]=5;bytes[6]=lane;put(bytes,8,base+extension,4);put(bytes,16,identity,8);
  put(bytes,base,lane,4);put(bytes,base+4,2,4);put(bytes,base+8,1,8);
  put(bytes,base+24,1,8);put(bytes,base+40,2,8);
  put(bytes,base+56,1,8);put(bytes,base+72,2,8);put(bytes,base+80,80,4);
  return bytes;
}
int main(){
  const auto foreground=activity(1,9),background=activity(0,8);
  std::vector<Frame> frames;
  Parser old(4096,true,true);assert(!old.Push(foreground,&frames));assert(frames.empty());
  Parser modern(4096,true,true,false,false,false,true);
  for(auto byte:foreground)assert(modern.Push({&byte,1},&frames));
  assert(modern.Push(background,&frames));assert(modern.Finish());assert(frames.size()==2);
  assert(frames[0].atlas->activity->lane==1 && frames[1].atlas->activity->lane==0);
  assert((frames[0].atlas->activity->members==std::vector<AtlasId>{{0,1},{0,2}}));
  assert(frames[0].alpha==frames[1].alpha);
  assert(!modern.Push(background,&frames));
  for(auto offset:{size_t(6),size_t(244),size_t(320)}){
    auto bad=foreground;bad[offset]=255;Parser parser(4096,true,true,false,false,false,true);frames.clear();
    assert(!parser.Push(bad,&frames));assert(frames.empty());
  }
}

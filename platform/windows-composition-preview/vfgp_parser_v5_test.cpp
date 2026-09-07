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
int main(int argc, char** argv) {
  auto bytes = fixture();
  if (argc == 2) {
    std::ifstream input(argv[1], std::ios::binary);
    const std::vector<uint8_t> actual{std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
    if (actual != bytes) { std::cerr << "Rust/C++ fixture mismatch\n"; return 1; }
  }
  Parser single(4096, true);
  std::vector<Frame> output;
  if (single.Push(bytes, &output) || !output.empty()) return 2;
  Parser parser(4096, true, true);
  for (const auto& byte : bytes) if (!parser.Push({&byte, 1}, &output)) return 3;
  if (!parser.Finish() || output.size() != 1 || !output[0].atlas ||
      output[0].deadline_qpc != DeadlineQpc{1000,10'000'000} ||
      output[0].alpha != std::vector<uint8_t>(8,7)) return 4;
  const auto& atlas = *output[0].atlas;
  if (atlas.stream != AtlasId{0,99} || atlas.geometry_epoch != 3 || atlas.config_generation != 4 ||
      atlas.revision != 5 || atlas.source_ns != 100 || !atlas.color_keyframe || !atlas.alpha_keyframe ||
      atlas.tiles.size() != 2 || atlas.tiles[1].window != AtlasId{0,2} ||
      atlas.tiles[1].source_frame != 8 || atlas.tiles[1].source_ns != 101 || atlas.tiles[1].x != 2) return 5;
  for (size_t cut = 1; cut < bytes.size(); ++cut) {
    Parser partial(4096,true,true); std::vector<Frame> pending;
    if (!partial.Push({bytes.data(),cut}, &pending) || partial.Finish() || !pending.empty()) return 6;
  }
  for (const auto& [offset, value, size] : std::vector<std::array<size_t,3>>{
      {40,0,8}, {48,0,8}, {64,0,8}, {104,4097,4}, {108,4,4},
      {120,99,8}, {184,1,8}, {128,6,8}, {224,1,4}, {96,101,8}, {24,3,4}}) {
    auto invalid = bytes; put(invalid,offset,value,size);
    Parser reject(4096,true,true); std::vector<Frame> frames;
    if (reject.Push(invalid,&frames) || !frames.empty() || reject.Finish()) return 7;
  }
  Parser limited(bytes.size()-1,true,true); std::vector<Frame> frames;
  if (limited.Push(bytes,&frames)) return 8;
  Parser startup(4096,true,true); std::vector<Frame> warmed;
  auto warmup = std::vector<uint8_t>(bytes.begin(), bytes.begin()+40);
  warmup[4]=3; warmup[5]=1; put(warmup,8,40,4);
  warmup.insert(warmup.end(),bytes.begin()+240,bytes.end());
  for (uint64_t id=1;id<=3;++id) {
    put(warmup,16,id,8);
    if (!startup.Push(warmup,&warmed)) return 9;
  }
  auto live = bytes; put(live,16,1,8);
  if (!startup.Push(live,&warmed) || !startup.Finish() || warmed.size()!=4 ||
      !warmed[0].decode_only || warmed.back().decode_only || !warmed.back().atlas ||
      warmed.back().identity!=1 || startup.Push(live,&warmed)) return 10;
  std::cout << "PASS VFGP v5 atlas identities, regions, deadline and opt-in\n";
  return 0;
}

#include "vfgp_parser.h"

#include <algorithm>
#include <cstdio>
#include <vector>

using namespace viewflow::vfgp;

namespace {
void u32(std::vector<uint8_t>& bytes, uint32_t value) {
  for (int shift = 24; shift >= 0; shift -= 8)
    bytes.push_back(uint8_t(value >> shift));
}
void u64(std::vector<uint8_t>& bytes, uint64_t value) {
  u32(bytes, uint32_t(value >> 32));
  u32(bytes, uint32_t(value));
}
void put32(std::vector<uint8_t>& bytes, size_t at, uint32_t value) {
  for (size_t index = 0; index < 4; ++index)
    bytes[at + index] = uint8_t(value >> (24 - 8 * index));
}
std::vector<uint8_t> vfar(uint32_t width, uint32_t height) {
  std::vector<uint8_t> bytes{'V', 'F', 'A', 'R', 1, 1, 0, 0};
  u32(bytes, width); u32(bytes, height); u64(bytes, uint64_t(width) * height);
  bytes.insert(bytes.end(), {0x83, 7});
  return bytes;
}
std::vector<uint8_t> frame(uint64_t identity, uint64_t deadline,
                           uint64_t frequency) {
  const auto alpha = vfar(2, 2);
  std::vector<uint8_t> bytes{'V', 'F', 'G', 'P', 4, 0, 0, 0};
  u32(bytes, 56); u32(bytes, uint32_t(4 + alpha.size())); u64(bytes, identity);
  u32(bytes, 2); u32(bytes, 2); u32(bytes, 4); u32(bytes, uint32_t(alpha.size()));
  u64(bytes, deadline); u64(bytes, frequency);
  bytes.insert(bytes.end(), {0, 0, 1, 0x65}); bytes.insert(bytes.end(), alpha.begin(), alpha.end());
  return bytes;
}
bool check(bool value, const char* message) {
  if (!value) std::fprintf(stderr, "FAIL %s\n", message);
  return value;
}
}  // namespace

int main() {
  const auto first = frame(9, 0x0102'0304'0506'0708ULL, 10'000'000);
  Parser default_parser;
  std::vector<Frame> rejected;
  if (!check(!default_parser.Push(first, &rejected) && !default_parser.Finish(),
             "v4 default rejection")) return 1;

  Parser parser(4096, true);
  std::vector<Frame> decoded;
  for (size_t at = 0; at < first.size(); ++at)
    if (!check(parser.Push({first.data() + at, 1}, &decoded), "bytewise v4 parse")) return 1;
  if (!check(parser.Finish() && decoded.size() == 1 && decoded[0].identity == 9 &&
                 decoded[0].deadline_qpc == DeadlineQpc{0x0102'0304'0506'0708ULL, 10'000'000} &&
                 decoded[0].color_au == std::vector<uint8_t>{0, 0, 1, 0x65} &&
                 decoded[0].alpha == std::vector<uint8_t>{7, 7, 7, 7},
             "v4 deadline fields and alpha")) return 1;

  auto second = frame(10, 0x0102'0304'0506'0709ULL, 10'000'000);
  std::vector<uint8_t> multiple = first;
  multiple.insert(multiple.end(), second.begin(), second.end());
  Parser multi(4096, true); std::vector<Frame> frames;
  if (!check(multi.Push(multiple, &frames) && multi.Finish() && frames.size() == 2 &&
                 frames[1].deadline_qpc == DeadlineQpc{0x0102'0304'0506'0709ULL, 10'000'000},
             "multiple v4 records")) return 1;

  for (size_t cut = 1; cut < first.size(); ++cut) {
    Parser partial(4096, true); std::vector<Frame> output;
    if (!check(partial.Push({first.data(), cut}, &output) && !partial.Finish(),
               "v4 truncation remains incomplete")) return 1;
  }
  for (auto bad : {frame(9, 0, 10'000'000), frame(9, 1, 0)}) {
    Parser invalid(4096, true); std::vector<Frame> output;
    if (!check(!invalid.Push(bad, &output), "v4 zero deadline or frequency")) return 1;
  }
  auto wrong_header = first; put32(wrong_header, 8, 40);
  Parser header(4096, true); std::vector<Frame> output;
  if (!check(!header.Push(wrong_header, &output), "v4 wrong header bytes")) return 1;
  Parser limited(first.size() - 1, true);
  if (!check(!limited.Push(first, &output), "v4 max bound")) return 1;
  std::puts("PASS VFGP v4 opt-in deadline parser");
  return 0;
}

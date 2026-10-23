#include "vfgp_parser.h"
#include <cassert>
#include <vector>

using namespace viewflow::vfgp;
static void put(std::vector<uint8_t> &bytes, size_t at, uint64_t value,
                size_t size) {
  for (size_t i = 0; i < size; ++i)
    bytes[at + i] = uint8_t(value >> ((size - i - 1) * 8));
}
static std::vector<uint8_t> fixture() {
  // one 64-byte tile, then 48-byte desktop fixed block, then one 56-byte record
  std::vector<uint8_t> b(160 + 120 + 36);
  b[0] = 'V';
  b[1] = 'F';
  b[2] = 'G';
  b[3] = 'P';
  b[4] = 7;
  put(b, 8, 280, 4);
  put(b, 12, 36, 4);
  put(b, 16, 1, 8);
  put(b, 24, 4, 4);
  put(b, 28, 2, 4);
  put(b, 32, 4, 4);
  put(b, 36, 32, 4);
  put(b, 40, 1000, 8);
  put(b, 48, 10000, 8);
  put(b, 64, 9, 8);
  put(b, 72, 3, 8);
  put(b, 80, 4, 8);
  put(b, 88, 5, 8);
  put(b, 96, 100, 8);
  put(b, 104, 1, 4);
  put(b, 108, 3, 4);
  const size_t tile = 112;
  put(b, tile + 8, 2, 8);
  put(b, tile + 16, 5, 8);
  put(b, tile + 24, 3, 8);
  put(b, tile + 32, 7, 8);
  put(b, tile + 40, 100, 8);
  put(b, tile + 56, 4, 4);
  put(b, tile + 60, 2, 4);
  const size_t desktop = 176;
  put(b, desktop, 8, 8);
  put(b, desktop + 8, uint64_t(-3000), 8);
  put(b, desktop + 16, 4000, 8);
  put(b, desktop + 24, 8000, 8);
  put(b, desktop + 32, 6000, 8);
  put(b, desktop + 40, 1, 4);
  const size_t placement = desktop + 48;
  put(b, placement + 8, 2, 8);
  put(b, placement + 16, uint64_t(-2000), 8);
  put(b, placement + 24, 4500, 8);
  put(b, placement + 32, 5000, 8);
  put(b, placement + 40, 4000, 8);
  put(b, placement + 48, 3, 4);
  put(b, placement + 52, 7, 4);
  b[284] = 'V';
  b[285] = 'F';
  b[286] = 'A';
  b[287] = 'R';
  b[288] = 1; // raw alpha
  put(b, 292, 4, 4);
  put(b, 296, 2, 4);
  put(b, 300, 8, 8);
  for (size_t i = 0; i < 8; ++i)
    b[308 + i] = 7;
  return b;
}
int main() {
  auto b = fixture();
  std::vector<Frame> frames;
  Parser disabled(4096, true, true, true);
  assert(!disabled.Push(b, &frames));
  Parser parser(4096, true, true, true, true);
  for (auto byte : b)
    assert(parser.Push({&byte, 1}, &frames));
  assert(parser.Finish() && frames.size() == 1 && frames[0].atlas &&
         frames[0].atlas->desktop);
  const auto &desktop = *frames[0].atlas->desktop;
  assert((desktop.topology_generation == 8 &&
          desktop.viewport.x_millidip == -3000 && desktop.windows.size() == 1 &&
          desktop.windows[0].window == AtlasId{0, 2} &&
          desktop.windows[0].movable && desktop.windows[0].z_order == 7 && desktop.windows[0].raise_serial == 1));
  // A reordered/mismatched desktop window is rejected before any native
  // placement.
  b = fixture();
  put(b, 224, 3, 8);
  frames.clear();
  Parser reject(4096, true, true, true, true);
  assert(!reject.Push(b, &frames) && frames.empty());
}

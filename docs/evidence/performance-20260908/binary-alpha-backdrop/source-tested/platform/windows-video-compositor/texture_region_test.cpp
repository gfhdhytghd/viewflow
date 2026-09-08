#include "texture_region.h"
#include <limits>

using namespace viewflow::windows;
int main() {
  if (!valid_texture_region(64, 64, {0, 0, 64, 64})) return 1;
  if (!valid_texture_region(64, 64, {3, 5, 17, 19})) return 2;
  if (!valid_texture_region(64, 64, {63, 63, 1, 1})) return 3;
  if (valid_texture_region(64, 64, {64, 0, 1, 1})) return 4;
  if (valid_texture_region(64, 64, {0, 0, 0, 1})) return 5;
  if (valid_texture_region(64, 64, {0, 63, 1, 2})) return 6;
  constexpr auto max = std::numeric_limits<uint32_t>::max();
  if (valid_texture_region(max, max, {max, 0, 2, 1})) return 7;
  if (!valid_texture_region(max, max, {max - 1, max - 1, 1, 1})) return 8;
  return 0;
}

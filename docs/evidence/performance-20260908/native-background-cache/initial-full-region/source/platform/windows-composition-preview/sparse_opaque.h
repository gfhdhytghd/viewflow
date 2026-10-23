#pragma once
#include "atlas_record.h"
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <span>
#include <vector>

namespace viewflow::windows_preview {
inline bool AllOpaqueAlpha(std::span<const uint8_t> row) {
  uint64_t non_opaque=0;
  size_t offset=0;
  for (; offset+sizeof(uint64_t)<=row.size(); offset+=sizeof(uint64_t)) {
    uint64_t word;
    std::memcpy(&word,row.data()+offset,sizeof(word));
    non_opaque|=~word;
  }
  for (; offset<row.size(); ++offset) non_opaque|=uint64_t(row[offset]^255u);
  return non_opaque==0;
}
// Classify the exact decoded alpha plane, never window opacity hints. Include
// a two-pixel sampling halo and retain backdrop at atlas edges. Unknown/missing
// alpha remains conservative. The classification travels with its frame ID.
inline std::vector<uint8_t> OpaqueSparsePatches(std::span<const uint8_t> alpha,
    uint32_t width, uint32_t height, std::span<const vfgp::AtlasPatch> patches) {
  std::vector<uint8_t> opaque(patches.size());
  if (!width || !height || uint64_t(width) * height != alpha.size()) return opaque;
  constexpr uint32_t halo = 2;
  for (size_t index = 0; index < patches.size(); ++index) {
    const auto& patch = patches[index];
    if (!patch.width || !patch.height || patch.x < halo || patch.y < halo ||
        uint64_t(patch.x) + patch.width + halo > width ||
        uint64_t(patch.y) + patch.height + halo > height) continue;
    bool full = true;
    for (uint32_t y = patch.y - halo; y < patch.y + patch.height + halo; ++y) {
      const auto row = alpha.subspan(size_t(y) * width + patch.x - halo, size_t(patch.width) + 2 * halo);
      if (!AllOpaqueAlpha(row)) {
        full = false;
        break;
      }
    }
    opaque[index] = uint8_t(full);
  }
  return opaque;
}
} // namespace viewflow::windows_preview

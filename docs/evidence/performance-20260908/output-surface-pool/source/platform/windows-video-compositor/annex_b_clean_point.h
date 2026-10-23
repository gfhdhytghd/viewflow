#pragma once
#include <cstddef>
#include <cstdint>
#include <span>

namespace viewflow::windows {
// Conservative sample hint, not a bitstream validator. Only a VCL access unit
// containing IDR slices and no non-IDR VCL slices is a random-access point.
inline bool annex_b_clean_point(std::span<const uint8_t> au) {
  bool idr = false;
  for (std::size_t i = 0; i + 2 < au.size(); ++i) {
    if (au[i] || au[i + 1]) continue;
    std::size_t header = i + 2;
    if (au[header] == 0) ++header;
    if (header >= au.size() || au[header] != 1) continue;
    if (++header >= au.size()) return false;
    const uint8_t nal = au[header];
    if (nal & 0x80) return false;
    const uint8_t type = nal & 0x1f;
    if (type >= 1 && type <= 4) return false;
    if (type == 5) idr = true;
    i = header;
  }
  return idr;
}
} // namespace viewflow::windows

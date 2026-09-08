#pragma once
#include <cstdint>

namespace viewflow::windows {
struct TextureRegion {
  uint32_t x{}, y{}, width{}, height{};
};

// BGRA composition is already decoded: odd tile sizes/offsets are legal here,
// unlike subsampled NV12 decoder apertures. Use wide sums before any D3D cast.
constexpr bool valid_texture_region(uint32_t width, uint32_t height,
                                    TextureRegion region) {
  return width && height && region.width && region.height &&
         uint64_t(region.x) + region.width <= width &&
         uint64_t(region.y) + region.height <= height;
}
} // namespace viewflow::windows

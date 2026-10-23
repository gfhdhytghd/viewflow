#include "nvenc_encoder.hpp"

#include <cassert>
#include <cstdint>
#include <string>
#include <vector>

using namespace viewflow::nvenc;

int main() {
  // Synthetic-only unit checks: no display/window/screen-capture dependency.
  const std::vector<std::uint8_t> rgba{
      1, 2, 3, 0,    // transparent red: alpha must survive exactly.
      4, 5, 6, 127,  // partial alpha.
      7, 8, 9, 255,  // opaque alpha.
      10, 11, 12, 42,
  };
  const AlphaPlanes alpha = split_straight_rgba_alpha(rgba, 2, 2);
  assert(!alpha.all_opaque);
  assert((alpha.luma == std::vector<std::uint8_t>{0, 127, 255, 42}));
  assert((alpha.chroma_u == std::vector<std::uint8_t>{128, 128, 128, 128}));
  assert((alpha.chroma_v == std::vector<std::uint8_t>{128, 128, 128, 128}));

  const AlphaPlanes opaque = split_straight_rgba_alpha(
      std::vector<std::uint8_t>{0, 0, 0, 255, 1, 1, 1, 255}, 2, 1);
  assert(opaque.all_opaque);

  // OpaqueMayOmit's no-allocation fast path must only classify exactly opaque
  // RGBA as omittable.  Transparent and partial source alpha must still take
  // the existing split/encode path.
  assert(is_straight_rgba_opaque(std::vector<std::uint8_t>{0, 0, 0, 255, 1, 1, 1, 255}));
  assert(!is_straight_rgba_opaque(std::vector<std::uint8_t>{0, 0, 0, 0}));
  assert(!is_straight_rgba_opaque(std::vector<std::uint8_t>{0, 0, 0, 127}));
  assert(!is_straight_rgba_opaque(std::vector<std::uint8_t>{0, 0, 0}));

  std::string error;
  EncoderConfig invalid{0,
                        1,
                        1024,
                        1,
                        AlphaPolicy::Required,
                        AlphaFidelity{AlphaFidelityKind::Lossless}};
  assert(!Encoder::create(invalid, &error));
  assert(!error.empty());
  return 0;
}

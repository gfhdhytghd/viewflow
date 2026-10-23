#include "gpu_shadow_repair.cuh"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>

using viewflow::gpu::ShadowRepair;
using viewflow::gpu::ShadowSnapshot;

namespace {
struct Region { int left, top, right, bottom; bool cutout; };
struct Fixture { int width, height; size_t rgbaPitch, alphaPitch; ShadowSnapshot snapshot; std::vector<unsigned char> rgba, alpha; };

bool check(cudaError_t error, const char* what) {
  if (error == cudaSuccess) return true;
  std::fprintf(stderr, "FAIL %s: %s\n", what, cudaGetErrorString(error));
  return false;
}

int floorClamp(double value, int low, int high) {
  if (value <= double(low)) return low;
  if (value >= double(high)) return high;
  return static_cast<int>(std::floor(value));
}
int ceilClamp(double value, int low, int high) {
  if (value <= double(low)) return low;
  if (value >= double(high)) return high;
  return static_cast<int>(std::ceil(value));
}
double cpuLength(double x, double y, double power) {
  power = std::clamp(power, 1.0, 10.0);
  return std::pow(std::pow(std::abs(x), power) + std::pow(std::abs(y), power), 1.0 / power);
}
bool cpuInRoundedCutout(double x, double y, const ShadowSnapshot& s) {
  const double right = s.cutoutLeft + s.cutoutWidth, bottom = s.cutoutTop + s.cutoutHeight;
  if (x < s.cutoutLeft || x > right || y < s.cutoutTop || y > bottom) return false;
  if (s.windowRounding <= 0.0) return true;
  const double radius = std::min(s.windowRounding, std::min(s.cutoutWidth * .5, s.cutoutHeight * .5));
  const double innerLeft = s.cutoutLeft + radius, innerTop = s.cutoutTop + radius;
  const double innerRight = right - radius, innerBottom = bottom - radius;
  if (x >= innerLeft && x <= innerRight) return true;
  if (y >= innerTop && y <= innerBottom) return true;
  return cpuLength(x < innerLeft ? innerLeft - x : x - innerRight,
                   y < innerTop ? innerTop - y : y - innerBottom, s.roundingPower) <= radius;
}
double cpuMultiplier(double x, double y, const ShadowSnapshot& s) {
  if (s.range <= 0.0 || s.width <= 0.0 || s.height <= 0.0) return 0.0;
  const double radius = s.range + std::max(0.0, s.rounding);
  const double right = s.width - radius, bottom = s.height - radius;
  bool corner = false; double distance = 0.0;
  if (x < radius) {
    if (y < radius) { distance = cpuLength(x - radius, y - radius, s.roundingPower); corner = true; }
    else if (y > bottom) { distance = cpuLength(x - radius, y - bottom, s.roundingPower); corner = true; }
  } else if (x > right) {
    if (y < radius) { distance = cpuLength(x - right, y - radius, s.roundingPower); corner = true; }
    else if (y > bottom) { distance = cpuLength(x - right, y - bottom, s.roundingPower); corner = true; }
  }
  double result = 1.0;
  if (corner) {
    if (distance > radius) result = 0.0;
    else if (distance > radius - s.range) result = std::pow((radius - distance) / s.range, s.power);
  } else {
    const double nearest = std::min(std::min(y, s.height - y), std::min(x, s.width - x));
    if (nearest < s.range) result = std::pow(std::clamp(nearest / s.range, 0.0, 1.0), s.power);
  }
  return std::clamp(result, 0.0, 1.0);
}
void cpuRepairPixel(unsigned char* pixel, int x, int y, bool testCutout, const ShadowSnapshot& s) {
  const double centerX = x - s.left + .5, centerY = y - s.top + .5;
  if (testCutout && cpuInRoundedCutout(centerX, centerY, s)) return;
  const int maxRgb = std::max({int(pixel[0]), int(pixel[1]), int(pixel[2])});
  const bool existing = pixel[3] > 0 && pixel[3] <= 249 && maxRgb <= 64;
  if (pixel[3] != 0 && maxRgb > 64) return;
  int alpha = std::clamp(int(std::lround(s.alpha * (s.sharp ? 1.0 : cpuMultiplier(centerX, centerY, s)))), 0, int(s.alpha));
  if (alpha <= 0 && existing) {
    const unsigned char color[] = {s.red, s.green, s.blue};
    for (int channel = 0; channel < 3; ++channel)
      if (color[channel] > 0) alpha = std::max(alpha, int(std::lround(double(pixel[channel]) * pixel[3] / color[channel])));
    alpha = std::clamp(alpha, 0, int(s.alpha));
  }
  pixel[3] = static_cast<unsigned char>(alpha);
  pixel[0] = alpha == 0 ? 0 : s.red;
  pixel[1] = alpha == 0 ? 0 : s.green;
  pixel[2] = alpha == 0 ? 0 : s.blue;
}
void repairRegion(Fixture& fixture, const Region& region) {
  for (int y = region.top; y < region.bottom; ++y) for (int x = region.left; x < region.right; ++x) {
    unsigned char* pixel = fixture.rgba.data() + size_t(y) * fixture.rgbaPitch + size_t(x) * 4;
    cpuRepairPixel(pixel, x, y, region.cutout, fixture.snapshot);
    fixture.alpha[size_t(y) * fixture.alphaPitch + size_t(x)] = pixel[3];
  }
}
void oracle(Fixture& fixture) {
  const ShadowSnapshot& s = fixture.snapshot;
  if (s.alpha == 0) return;
  const int left = floorClamp(s.left, 0, fixture.width), top = floorClamp(s.top, 0, fixture.height);
  const int right = ceilClamp(s.left + s.width, left, fixture.width), bottom = ceilClamp(s.top + s.height, top, fixture.height);
  const int cutLeft = floorClamp(s.left + s.cutoutLeft, left, right), cutTop = floorClamp(s.top + s.cutoutTop, top, bottom);
  const int cutRight = ceilClamp(s.left + s.cutoutLeft + s.cutoutWidth, cutLeft, right);
  const int cutBottom = ceilClamp(s.top + s.cutoutTop + s.cutoutHeight, cutTop, bottom);
  const Region outer[] = {{left, top, right, cutTop, false}, {left, cutBottom, right, bottom, false},
                          {left, cutTop, cutLeft, cutBottom, false}, {cutRight, cutTop, right, cutBottom, false}};
  for (const Region& region : outer) repairRegion(fixture, region);
  const int radius = std::clamp(int(std::ceil(s.windowRounding)), 0, std::max(cutRight - cutLeft, cutBottom - cutTop));
  if (radius <= 0) return;
  const Region corners[] = {
      {cutLeft, cutTop, std::min(cutLeft + radius, cutRight), std::min(cutTop + radius, cutBottom), true},
      {std::max(cutRight - radius, cutLeft), cutTop, cutRight, std::min(cutTop + radius, cutBottom), true},
      {cutLeft, std::max(cutBottom - radius, cutTop), std::min(cutLeft + radius, cutRight), cutBottom, true},
      {std::max(cutRight - radius, cutLeft), std::max(cutBottom - radius, cutTop), cutRight, cutBottom, true},
  };
  for (const Region& region : corners) repairRegion(fixture, region);
}
Fixture makeFixture(ShadowSnapshot snapshot) {
  Fixture fixture{19, 17, 19 * 4 + 7, 19 + 5, snapshot, {}, {}};
  fixture.rgba.assign(fixture.rgbaPitch * size_t(fixture.height), 0xcd);
  fixture.alpha.assign(fixture.alphaPitch * size_t(fixture.height), 0xcd);
  for (int y = 0; y < fixture.height; ++y) for (int x = 0; x < fixture.width; ++x) {
    unsigned char* pixel = fixture.rgba.data() + size_t(y) * fixture.rgbaPitch + size_t(x) * 4;
    pixel[0] = pixel[1] = pixel[2] = 0; pixel[3] = 0;
    fixture.alpha[size_t(y) * fixture.alphaPitch + size_t(x)] = 0;
  }
  return fixture;
}
bool run(Fixture input, const char* name) {
  Fixture want = input;
  oracle(want);
  unsigned char *dRgba = nullptr, *dAlpha = nullptr;
  bool ok = check(cudaMalloc(reinterpret_cast<void**>(&dRgba), input.rgba.size()), "malloc rgba") &&
            check(cudaMalloc(reinterpret_cast<void**>(&dAlpha), input.alpha.size()), "malloc alpha");
  if (ok) ok = check(cudaMemcpy(dRgba, input.rgba.data(), input.rgba.size(), cudaMemcpyHostToDevice), "upload rgba") &&
               check(cudaMemcpy(dAlpha, input.alpha.data(), input.alpha.size(), cudaMemcpyHostToDevice), "upload alpha");
  ShadowRepair repair{dRgba, input.rgbaPitch, dAlpha, input.alphaPitch, input.width, input.height, input.snapshot};
  if (ok) ok = check(viewflow::gpu::repairShadow(repair, 0), "repair") && check(cudaDeviceSynchronize(), "repair stream sync");
  if (ok) ok = check(cudaMemcpy(input.rgba.data(), dRgba, input.rgba.size(), cudaMemcpyDeviceToHost), "download rgba") &&
               check(cudaMemcpy(input.alpha.data(), dAlpha, input.alpha.size(), cudaMemcpyDeviceToHost), "download alpha");
  if (dRgba) ok = check(cudaFree(dRgba), "free rgba") && ok;
  if (dAlpha) ok = check(cudaFree(dAlpha), "free alpha") && ok;
  if (!ok) return false;
  int maxAlphaDelta = 0;
  for (int y = 0; y < input.height; ++y) for (int x = 0; x < input.width; ++x) {
    const unsigned char* got = input.rgba.data() + size_t(y) * input.rgbaPitch + size_t(x) * 4;
    const unsigned char* expected = want.rgba.data() + size_t(y) * want.rgbaPitch + size_t(x) * 4;
    for (int channel = 0; channel < 3; ++channel) if (got[channel] != expected[channel]) {
      std::fprintf(stderr, "FAIL %s: RGB differs at %d,%d channel=%d (%u != %u)\n", name, x, y, channel, got[channel], expected[channel]); return false;
    }
    maxAlphaDelta = std::max(maxAlphaDelta, std::abs(int(got[3]) - int(expected[3])));
    if (input.alpha[size_t(y) * input.alphaPitch + size_t(x)] != got[3] ||
        want.alpha[size_t(y) * want.alphaPitch + size_t(x)] != expected[3]) {
      std::fprintf(stderr, "FAIL %s: independent alpha is not synchronized at %d,%d\n", name, x, y); return false;
    }
  }
  if (input.rgba != want.rgba || input.alpha != want.alpha) {
    std::fprintf(stderr, "FAIL %s: exact CPU/GPU mismatch; max alpha delta=%d (permitted=0; alpha=1 would be reported, not accepted)\n", name, maxAlphaDelta);
    return false;
  }
  std::printf("PASS %s (exact; max alpha delta=%d)\n", name, maxAlphaDelta);
  return true;
}
void setPixel(Fixture& fixture, int x, int y, unsigned char red, unsigned char green, unsigned char blue, unsigned char alpha) {
  unsigned char* pixel = fixture.rgba.data() + size_t(y) * fixture.rgbaPitch + size_t(x) * 4;
  pixel[0] = red; pixel[1] = green; pixel[2] = blue; pixel[3] = alpha;
  fixture.alpha[size_t(y) * fixture.alphaPitch + size_t(x)] = alpha;
}
ShadowSnapshot base() { return {1.25, .5, 15.25, 14.0, 3.1, 2.2, 8.0, 8.1, 4.5, 1.75, 2.6, 2.3, 3, 19, 73, 141, 197, false}; }
bool invalidContract() {
  unsigned char *first = nullptr, *second = nullptr;
  bool ok = check(cudaMalloc(reinterpret_cast<void**>(&first), 128), "invalid malloc first") &&
            check(cudaMalloc(reinterpret_cast<void**>(&second), 128), "invalid malloc second");
  ShadowRepair repair{first, 32, second, 8, 8, 2, base()};
  if (ok && viewflow::gpu::repairShadow(repair, 0) != cudaSuccess) { std::fputs("FAIL valid repair rejected\n", stderr); ok = false; }
  if (ok) ok = check(cudaDeviceSynchronize(), "valid invalid-contract repair sync");
  if (ok && viewflow::gpu::repairShadow({first, 32, first, 8, 8, 2, base()}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL alias was accepted\n", stderr); ok = false; }
  if (ok && viewflow::gpu::repairShadow({first, 31, second, 8, 8, 2, base()}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL short rgba pitch was accepted\n", stderr); ok = false; }
  if (ok && viewflow::gpu::repairShadow({first, std::numeric_limits<size_t>::max(), second, 8, 8, 2, base()}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL pitch span overflow was accepted\n", stderr); ok = false; }
  auto nonfinite = base(); nonfinite.left = std::numeric_limits<double>::infinity();
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, nonfinite}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL nonfinite snapshot was accepted\n", stderr); ok = false; }
  auto sumOverflow = base(); sumOverflow.left = std::numeric_limits<double>::max(); sumOverflow.width = std::numeric_limits<double>::max();
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, sumOverflow}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL finite-value addition overflow was accepted\n", stderr); ok = false; }
  auto cutoutLeftOverflow = base(); cutoutLeftOverflow.left = std::numeric_limits<double>::max(); cutoutLeftOverflow.cutoutLeft = std::numeric_limits<double>::max();
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, cutoutLeftOverflow}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL cutout absolute-left overflow was accepted\n", stderr); ok = false; }
  auto cutoutTopOverflow = base(); cutoutTopOverflow.top = std::numeric_limits<double>::max(); cutoutTopOverflow.cutoutTop = std::numeric_limits<double>::max();
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, cutoutTopOverflow}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL cutout absolute-top overflow was accepted\n", stderr); ok = false; }
  auto cutoutRightOverflow = base(); cutoutRightOverflow.cutoutLeft = std::numeric_limits<double>::max(); cutoutRightOverflow.cutoutWidth = std::numeric_limits<double>::max();
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, cutoutRightOverflow}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL cutout relative-right overflow was accepted\n", stderr); ok = false; }
  auto cutoutBottomOverflow = base(); cutoutBottomOverflow.cutoutTop = std::numeric_limits<double>::max(); cutoutBottomOverflow.cutoutHeight = std::numeric_limits<double>::max();
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, cutoutBottomOverflow}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL cutout relative-bottom overflow was accepted\n", stderr); ok = false; }
  auto hugeCorner = base(); hugeCorner.windowRounding = std::numeric_limits<double>::max();
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, hugeCorner}, 0) != cudaSuccess) { std::fputs("FAIL DBL_MAX window rounding was rejected\n", stderr); ok = false; }
  if (ok) ok = check(cudaDeviceSynchronize(), "huge corner repair sync");
  auto zeroRange = base(); zeroRange.range = 0.0;
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, zeroRange}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL zero range was accepted\n", stderr); ok = false; }
  auto zeroCutout = base(); zeroCutout.cutoutWidth = 0.0;
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, zeroCutout}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL zero cutout width was accepted\n", stderr); ok = false; }
  auto negativeRounding = base(); negativeRounding.rounding = -0.1;
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, negativeRounding}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL negative rounding was accepted\n", stderr); ok = false; }
  auto invalidRoundingPower = base(); invalidRoundingPower.roundingPower = 10.1;
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, invalidRoundingPower}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL invalid rounding power was accepted\n", stderr); ok = false; }
  auto lowPower = base(); lowPower.power = 0;
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, lowPower}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL low shadow power was accepted\n", stderr); ok = false; }
  auto highPower = base(); highPower.power = 5;
  if (ok && viewflow::gpu::repairShadow({first, 32, second, 8, 8, 2, highPower}, 0) != cudaErrorInvalidValue) { std::fputs("FAIL high shadow power was accepted\n", stderr); ok = false; }
  if (first) ok = check(cudaFree(first), "invalid free first") && ok;
  if (second) ok = check(cudaFree(second), "invalid free second") && ok;
  if (ok) std::puts("PASS invalid dimension/pitch/finite/alias contract");
  return ok;
}
} // namespace

int main() {
  bool ok = true;
  auto soft = makeFixture(base());
  setPixel(soft, 2, 3, 20, 30, 40, 80);                 // colored recording shadow
  setPixel(soft, 3, 3, 230, 30, 20, 120);               // window content must survive
  ok = run(soft, "soft_colored_shadow_and_window_cutout") && ok;
  auto sharpSnapshot = base(); sharpSnapshot.sharp = true;
  ok = run(makeFixture(sharpSnapshot), "sharp_shadow") && ok;
  auto blackSnapshot = base(); blackSnapshot.red = blackSnapshot.green = blackSnapshot.blue = 0;
  ok = run(makeFixture(blackSnapshot), "black_shadow") && ok;
  auto transparentSnapshot = base(); transparentSnapshot.alpha = 0;
  auto transparent = makeFixture(transparentSnapshot);
  setPixel(transparent, 2, 3, 17, 31, 47, 0);
  setPixel(transparent, 4, 4, 12, 22, 32, 70);
  ok = run(transparent, "transparent_configured_shadow_is_complete_noop") && ok;
  auto reconstruct = makeFixture(base());
  setPixel(reconstruct, 1, 7, 5, 18, 35, 100);           // multiplier is zero at left edge; reconstruct alpha
  ok = run(reconstruct, "reconstruct_alpha_from_colored_premultiplied_pixel") && ok;
  auto clippedSnapshot = base(); clippedSnapshot.left = -2.4; clippedSnapshot.top = -1.3;
  clippedSnapshot.width = 15.8; clippedSnapshot.height = 13.7;
  ok = run(makeFixture(clippedSnapshot), "alpha_zero_clipped_shadow_noninteger_rounding") && ok;
  auto overlapSnapshot = base(); overlapSnapshot.cutoutLeft = 5.2; overlapSnapshot.cutoutTop = 5.1;
  overlapSnapshot.cutoutWidth = 2.2; overlapSnapshot.cutoutHeight = 2.2; overlapSnapshot.windowRounding = 9.7;
  ok = run(makeFixture(overlapSnapshot), "overlapping_corner_regions_preserve_eight_pass_order") && ok;
  ok = invalidContract() && ok;
  if (!ok) return 1;
  std::puts("PASS GPU shadow repair oracle suite");
}

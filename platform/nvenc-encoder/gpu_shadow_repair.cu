#include "gpu_shadow_repair.cuh"

#include <cmath>
#include <cstdint>
#include <limits>

namespace viewflow::gpu {
namespace {

struct Region { int left, top, right, bottom; bool testCutout; };

bool finiteSnapshot(const ShadowSnapshot& s) {
  const double values[] = {s.left, s.top, s.width, s.height, s.cutoutLeft,
                           s.cutoutTop, s.cutoutWidth, s.cutoutHeight, s.range,
                           s.rounding, s.windowRounding, s.roundingPower};
  for (double value : values) if (!std::isfinite(value)) return false;
  if (!std::isfinite(s.left + s.width) || !std::isfinite(s.top + s.height) ||
      !std::isfinite(s.left + s.cutoutLeft) || !std::isfinite(s.top + s.cutoutTop) ||
      !std::isfinite(s.left + s.cutoutLeft + s.cutoutWidth) ||
      !std::isfinite(s.top + s.cutoutTop + s.cutoutHeight)) return false;
  return s.width > 0.0 && s.height > 0.0 && s.range > 0.0 &&
         s.cutoutWidth > 0.0 && s.cutoutHeight > 0.0 && s.rounding >= 0.0 &&
         s.windowRounding >= 0.0 && s.roundingPower >= 1.0 && s.roundingPower <= 10.0 &&
         s.power >= 1 && s.power <= 4;
}

bool spanSize(size_t pitch, int height, size_t& bytes) {
  if (height <= 0 || pitch > std::numeric_limits<size_t>::max() / size_t(height)) return false;
  bytes = pitch * size_t(height);
  return true;
}

bool overlap(const void* a, size_t as, const void* b, size_t bs) {
  const auto av = reinterpret_cast<uintptr_t>(a);
  const auto bv = reinterpret_cast<uintptr_t>(b);
  if (av > UINTPTR_MAX - as || bv > UINTPTR_MAX - bs) return true;
  return av < bv + bs && bv < av + as;
}

int floorClamp(double v, int low, int high) {
  if (v <= double(low)) return low;
  if (v >= double(high)) return high;
  return static_cast<int>(std::floor(v));
}

int ceilClamp(double v, int low, int high) {
  if (v <= double(low)) return low;
  if (v >= double(high)) return high;
  return static_cast<int>(std::ceil(v));
}

__global__ void repairRegionKernel(ShadowRepair repair, Region region) {
  const size_t offsetX = size_t(blockIdx.x) * blockDim.x + threadIdx.x;
  const size_t offsetY = size_t(blockIdx.y) * blockDim.y + threadIdx.y;
  if (offsetX >= size_t(region.right - region.left) || offsetY >= size_t(region.bottom - region.top)) return;
  const int x = region.left + static_cast<int>(offsetX);
  const int y = region.top + static_cast<int>(offsetY);
  unsigned char* pixel = repair.rgba + size_t(y) * repair.rgbaPitch + size_t(x) * 4;
  repairShadowPixel(pixel, x, y, region.testCutout, repair.snapshot);
  repair.alpha[size_t(y) * repair.alphaPitch + size_t(x)] = pixel[3];
}

cudaError_t enqueue(const ShadowRepair& repair, const Region& region, cudaStream_t stream) {
  if (region.left >= region.right || region.top >= region.bottom) return cudaSuccess;
  const dim3 block(16, 16);
  const dim3 grid((unsigned(region.right - region.left) + block.x - 1) / block.x,
                  (unsigned(region.bottom - region.top) + block.y - 1) / block.y);
  repairRegionKernel<<<grid, block, 0, stream>>>(repair, region);
  return cudaGetLastError();
}

} // namespace

cudaError_t repairShadow(const ShadowRepair& repair, cudaStream_t stream) {
  if (!repair.rgba || !repair.alpha || repair.width <= 0 || repair.height <= 0 ||
      repair.rgbaPitch < size_t(repair.width) * 4 || repair.alphaPitch < size_t(repair.width) ||
      !finiteSnapshot(repair.snapshot)) return cudaErrorInvalidValue;
  size_t rgbaBytes = 0, alphaBytes = 0;
  if (!spanSize(repair.rgbaPitch, repair.height, rgbaBytes) ||
      !spanSize(repair.alphaPitch, repair.height, alphaBytes) ||
      overlap(repair.rgba, rgbaBytes, repair.alpha, alphaBytes)) return cudaErrorInvalidValue;
  // Match repairTransparentShadow: a fully transparent configured shadow is
  // not a request to clear source pixels.
  if (repair.snapshot.alpha == 0) return cudaSuccess;

  const ShadowSnapshot& s = repair.snapshot;
  const int repairLeft = floorClamp(s.left, 0, repair.width);
  const int repairTop = floorClamp(s.top, 0, repair.height);
  const int repairRight = ceilClamp(s.left + s.width, repairLeft, repair.width);
  const int repairBottom = ceilClamp(s.top + s.height, repairTop, repair.height);
  const int cutoutLeft = floorClamp(s.left + s.cutoutLeft, repairLeft, repairRight);
  const int cutoutTop = floorClamp(s.top + s.cutoutTop, repairTop, repairBottom);
  const int cutoutRight = ceilClamp(s.left + s.cutoutLeft + s.cutoutWidth, cutoutLeft, repairRight);
  const int cutoutBottom = ceilClamp(s.top + s.cutoutTop + s.cutoutHeight, cutoutTop, repairBottom);

  const Region regions[] = {
      {repairLeft, repairTop, repairRight, cutoutTop, false},
      {repairLeft, cutoutBottom, repairRight, repairBottom, false},
      {repairLeft, cutoutTop, cutoutLeft, cutoutBottom, false},
      {cutoutRight, cutoutTop, repairRight, cutoutBottom, false},
  };
  for (const Region& region : regions) {
    const cudaError_t error = enqueue(repair, region, stream);
    if (error != cudaSuccess) return error;
  }
  const int cornerRadius = ceilClamp(s.windowRounding, 0,
                                     shadowMax(cutoutRight - cutoutLeft, cutoutBottom - cutoutTop));
  if (cornerRadius <= 0) return cudaSuccess;
  const int leftRadius = shadowMin(cornerRadius, cutoutRight - cutoutLeft);
  const int topRadius = shadowMin(cornerRadius, cutoutBottom - cutoutTop);
  const Region corners[] = {
      {cutoutLeft, cutoutTop, cutoutLeft + leftRadius, cutoutTop + topRadius, true},
      {cutoutRight - leftRadius, cutoutTop, cutoutRight, cutoutTop + topRadius, true},
      {cutoutLeft, cutoutBottom - topRadius, cutoutLeft + leftRadius, cutoutBottom, true},
      {cutoutRight - leftRadius, cutoutBottom - topRadius, cutoutRight, cutoutBottom, true},
  };
  for (const Region& region : corners) {
    const cudaError_t error = enqueue(repair, region, stream);
    if (error != cudaSuccess) return error;
  }
  return cudaSuccess;
}

} // namespace viewflow::gpu

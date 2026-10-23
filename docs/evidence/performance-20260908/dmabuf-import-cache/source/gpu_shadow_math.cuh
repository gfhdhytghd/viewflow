#pragma once

#include <cmath>

#ifdef __CUDACC__
#define VF_SHADOW_HD __host__ __device__
#else
#define VF_SHADOW_HD
#endif

namespace viewflow::gpu {

// Render-time pixel-space constants. The producer must freeze these with the
// corresponding geometry epoch; this helper never queries a live window.
struct ShadowSnapshot {
  double left, top, width, height;
  double cutoutLeft, cutoutTop, cutoutWidth, cutoutHeight;
  double range, rounding, windowRounding, roundingPower;
  int power;
  unsigned char red, green, blue, alpha;
  bool sharp;
};

template <typename T> VF_SHADOW_HD inline T shadowMin(T a, T b) { return a < b ? a : b; }
template <typename T> VF_SHADOW_HD inline T shadowMax(T a, T b) { return a > b ? a : b; }
template <typename T> VF_SHADOW_HD inline T shadowClamp(T a, T lo, T hi) {
  return shadowMin(shadowMax(a, lo), hi);
}

VF_SHADOW_HD inline double shadowLength(double x, double y, double power) {
  power = shadowClamp(power, 1.0, 10.0);
  return ::pow(::pow(::fabs(x), power) + ::pow(::fabs(y), power), 1.0 / power);
}

VF_SHADOW_HD inline bool shadowInCutout(double x, double y, const ShadowSnapshot& s) {
  const double right = s.cutoutLeft + s.cutoutWidth;
  const double bottom = s.cutoutTop + s.cutoutHeight;
  if (x < s.cutoutLeft || x > right || y < s.cutoutTop || y > bottom) return false;
  if (s.windowRounding <= 0) return true;
  const double r = shadowMin(s.windowRounding, shadowMin(s.cutoutWidth * .5, s.cutoutHeight * .5));
  const double left = s.cutoutLeft + r, top = s.cutoutTop + r;
  const double innerRight = right - r, innerBottom = bottom - r;
  if ((x >= left && x <= innerRight) || (y >= top && y <= innerBottom)) return true;
  return shadowLength(x < left ? left - x : x - innerRight,
                      y < top ? top - y : y - innerBottom, s.roundingPower) <= r;
}

VF_SHADOW_HD inline double shadowMultiplier(double x, double y, const ShadowSnapshot& s) {
  if (s.range <= 0 || s.width <= 0 || s.height <= 0) return 0;
  const double radius = s.range + shadowMax(0.0, s.rounding);
  const double right = s.width - radius, bottom = s.height - radius;
  bool corner = false;
  double dx = 0, dy = 0;
  if (x < radius) {
    if (y < radius) { dx = x - radius; dy = y - radius; corner = true; }
    else if (y > bottom) { dx = x - radius; dy = y - bottom; corner = true; }
  } else if (x > right) {
    if (y < radius) { dx = x - right; dy = y - radius; corner = true; }
    else if (y > bottom) { dx = x - right; dy = y - bottom; corner = true; }
  }
  double result = 1;
  if (corner) {
    const double distance = shadowLength(dx, dy, s.roundingPower);
    if (distance > radius) result = 0;
    else if (distance > radius - s.range) result = ::pow((radius - distance) / s.range, s.power);
  } else {
    const double nearest = shadowMin(shadowMin(y, s.height - y), shadowMin(x, s.width - x));
    if (nearest < s.range) result = ::pow(shadowClamp(nearest / s.range, 0.0, 1.0), s.power);
  }
  return shadowClamp(result, 0.0, 1.0);
}

// One invocation corresponds to one CPU repairRegion visit. Overlapping
// rounded-corner regions must retain their original visit count/order.
VF_SHADOW_HD inline void repairShadowPixel(unsigned char* rgba, int x, int y,
                                           bool testCutout, const ShadowSnapshot& s) {
  const double cx = x - s.left + .5, cy = y - s.top + .5;
  if (testCutout && shadowInCutout(cx, cy, s)) return;
  const int maxRgb = shadowMax(int(rgba[0]), shadowMax(int(rgba[1]), int(rgba[2])));
  const bool existing = rgba[3] > 0 && rgba[3] <= 249 && maxRgb <= 64;
  if (rgba[3] != 0 && maxRgb > 64) return;
  const double multiplier = s.sharp ? 1.0 : shadowMultiplier(cx, cy, s);
  int alpha = shadowClamp(int(::lround(s.alpha * multiplier)), 0, int(s.alpha));
  if (alpha <= 0 && existing) {
    const unsigned char channels[3] = {s.red, s.green, s.blue};
    for (int i = 0; i < 3; ++i) {
      if (channels[i] > 0)
        alpha = shadowMax(alpha, int(::lround(double(rgba[i]) * rgba[3] / channels[i])));
    }
    alpha = shadowClamp(alpha, 0, int(s.alpha));
  }
  rgba[3] = static_cast<unsigned char>(alpha);
  rgba[0] = alpha == 0 ? 0 : s.red;
  rgba[1] = alpha == 0 ? 0 : s.green;
  rgba[2] = alpha == 0 ? 0 : s.blue;
}

} // namespace viewflow::gpu

#undef VF_SHADOW_HD

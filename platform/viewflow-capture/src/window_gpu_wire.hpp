// SPDX-License-Identifier: GPL-3.0-only
// Derived from HyprCapture caa7657c5f13b5828f984357f7686c98375f2949; see ../NOTICE.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace viewflow_capture::gpuwire {

constexpr std::size_t HCGF_BYTES = 232;
constexpr std::size_t HCGR_BYTES = 32;
constexpr std::size_t HCGI_BYTES = 88;
constexpr std::uint32_t HCGF_ABGR8888 = 0x34324241U;

enum class Error : std::uint8_t {
    None, Length, Magic, Version, HeaderLength, ZeroLineage, NonFinite, Geometry, Format, Stride, Offset, Crop, Flags, Reserved, Shadow,
};

struct Shadow {
    double left = 0, top = 0, width = 0, height = 0;
    double cutoutLeft = 0, cutoutTop = 0, cutoutWidth = 0, cutoutHeight = 0;
    double range = 0, rounding = 0, windowRounding = 0, roundingPower = 0;
    std::uint32_t power = 0;
    std::array<std::uint8_t, 4> rgba{};
    bool sharp = false;
};

struct Frame {
    std::uint64_t sequence = 0, captureMonotonicNs = 0, geometryEpoch = 0;
    double logicalX = 0, logicalY = 0, logicalWidth = 0, logicalHeight = 0;
    std::uint32_t imageWidth = 0, imageHeight = 0, fourcc = HCGF_ABGR8888, stride = 0;
    std::uint64_t modifier = 0, offset = 0;
    std::uint32_t cropX = 0, cropY = 0, cropWidth = 0, cropHeight = 0;
    bool flipY = false;
    bool shadowEnabled = false;
    Shadow shadow{};
};

struct Release {
    std::uint64_t sequence = 0, geometryEpoch = 0;
};

// Source-frozen main-surface geometry, not an input authorization. It travels
// in the same seqpacket as its HCGF frame and image/fence descriptors.
struct InputGeometry {
    std::uint64_t window = 0, surface = 0, pid = 0;
    std::array<double, 4> content{};
    std::array<double, 2> surfaceExtent{};
};
bool encode(const InputGeometry&, std::array<std::uint8_t, HCGI_BYTES>&, Error* = nullptr);
bool decode(const std::uint8_t*, std::size_t, InputGeometry&, Error* = nullptr);

bool encode(const Frame&, std::array<std::uint8_t, HCGF_BYTES>&, Error* = nullptr);
bool decode(const std::uint8_t*, std::size_t, Frame&, Error* = nullptr);
bool encode(const Release&, std::array<std::uint8_t, HCGR_BYTES>&, Error* = nullptr);
bool decode(const std::uint8_t*, std::size_t, Release&, Error* = nullptr);

} // namespace viewflow_capture::gpuwire

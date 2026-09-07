#pragma once
#import <CoreImage/CoreImage.h>
#include <span>
#include <vector>

namespace viewflow::macos {
struct Planes {
    CVPixelBufferRef color{};
    std::vector<uint8_t> alpha;
    Planes() = default;
    Planes(const Planes&) = delete;
    Planes(Planes&& other) noexcept : color(other.color), alpha(std::move(other.alpha)) { other.color = nullptr; }
    ~Planes() { if (color) CVPixelBufferRelease(color); }
};
Planes split_planes(CIContext* context, CIImage* image, unsigned width, unsigned height, CGColorSpaceRef color_space);
CIImage* join_planes(CVPixelBufferRef color, std::span<const uint8_t> alpha);
void pixel_self_test();
}

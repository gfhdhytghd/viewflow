#pragma once
#import <CoreImage/CoreImage.h>
#include <span>
#include <memory>
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
Planes split_planes(CIContext* context, CIImage* image, unsigned width, unsigned height, CGColorSpaceRef color_space,
    CVPixelBufferRef captured = nullptr, bool captured_srgb = false);
CIImage* join_planes(CVPixelBufferRef color, std::span<const uint8_t> alpha);
// Shares immutable alpha storage through the last Core Image/Metal consumer.
CIImage* join_planes(CVPixelBufferRef color, std::shared_ptr<const std::vector<uint8_t>> alpha);
CIImage* make_alpha_mask(unsigned width, unsigned height, std::shared_ptr<const std::vector<uint8_t>> alpha);
CIImage* join_planes(CVPixelBufferRef color, CIImage* mask);
void pixel_self_test();
}

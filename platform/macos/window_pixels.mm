#include "window_pixels.hpp"
#include "window_codec.hpp"
#import <Metal/Metal.h>
#include <stdexcept>
#include <cmath>
#include <cstdio>

namespace viewflow::macos {
namespace {
CVPixelBufferRef allocate(unsigned width, unsigned height) {
    CVPixelBufferRef pixels = nullptr;
    auto attributes = @{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}, (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey: @YES};
    if (CVPixelBufferCreate(nullptr, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixels) != kCVReturnSuccess)
        throw std::runtime_error("allocate window pixels");
    return pixels;
}
struct PixelOwner {
    CVPixelBufferRef pixels;
    ~PixelOwner() { if (pixels) CVPixelBufferRelease(pixels); }
};
}
Planes split_planes(CIContext* context, CIImage* image, unsigned width, unsigned height, CGColorSpaceRef color_space) {
    if (!context || !image || !width || !height || uint64_t(width) * height > reverse::max_pixels)
        throw std::runtime_error("invalid window pixel extent");
    PixelOwner pixels{allocate(width, height)};
    const auto rect = CGRectMake(0, 0, width, height);
    [context render:image toCVPixelBuffer:pixels.pixels bounds:rect colorSpace:color_space];
    Planes result; result.alpha.resize(static_cast<size_t>(width) * height);
    if (CVPixelBufferLockBaseAddress(pixels.pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        throw std::runtime_error("lock source alpha");
    const auto* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pixels.pixels));
    const auto stride = CVPixelBufferGetBytesPerRow(pixels.pixels);
    for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; ++x) result.alpha[y * width + x] = base[y * stride + x * 4 + 3];
    CVPixelBufferUnlockBaseAddress(pixels.pixels, kCVPixelBufferLock_ReadOnly);
    result.color = allocate(width, height);
    // CIColorMatrix operates on unpremultiplied values; a separate
    // unpremultiply filter would divide by alpha twice.
    CIImage* color = [CIImage imageWithCVPixelBuffer:pixels.pixels];
    color = [color imageByApplyingFilter:@"CIColorMatrix" withInputParameters:@{
        @"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:0], @"inputBiasVector": [CIVector vectorWithX:0 Y:0 Z:0 W:1]}];
    [context render:color toCVPixelBuffer:result.color bounds:rect colorSpace:color_space];
    return result;
}
CIImage* join_planes(CVPixelBufferRef color, std::span<const uint8_t> alpha) {
    const auto width = CVPixelBufferGetWidth(color), height = CVPixelBufferGetHeight(color);
    if (width * height != alpha.size()) throw std::runtime_error("proxy alpha extent mismatch");
    PixelOwner mask{allocate(static_cast<unsigned>(width), static_cast<unsigned>(height))};
    if (CVPixelBufferLockBaseAddress(mask.pixels, 0) != kCVReturnSuccess) throw std::runtime_error("lock proxy alpha");
    auto* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(mask.pixels));
    const auto stride = CVPixelBufferGetBytesPerRow(mask.pixels);
    for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
        auto* p = base + y * stride + x * 4; p[0] = p[1] = p[2] = p[3] = alpha[y * width + x];
    }
    CVPixelBufferUnlockBaseAddress(mask.pixels, 0);
    return [[CIImage imageWithCVPixelBuffer:color] imageByApplyingFilter:@"CIBlendWithAlphaMask" withInputParameters:@{
        kCIInputBackgroundImageKey: [CIImage imageWithColor:CIColor.clearColor], kCIInputMaskImageKey: [CIImage imageWithCVPixelBuffer:mask.pixels]}];
}
void pixel_self_test() {
    constexpr unsigned width = 64, height = 64;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CIContext* context = [CIContext contextWithMTLDevice:MTLCreateSystemDefaultDevice() options:@{kCIContextWorkingColorSpace: (__bridge id)space}];
    PixelOwner input{allocate(width, height)};
    if (CVPixelBufferLockBaseAddress(input.pixels, 0) != kCVReturnSuccess) throw std::runtime_error("fixture lock");
    auto* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(input.pixels));
    const auto stride = CVPixelBufferGetBytesPerRow(input.pixels);
    for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; ++x) {
        // Asymmetric quadrants catch vertical inversion and double alpha.
        const unsigned a = y < 32 ? (x < 32 ? 255 : 128) : (x < 32 ? 64 : 0);
        auto* p = base + y * stride + x * 4;
        p[0] = static_cast<uint8_t>(40 * a / 255); p[1] = static_cast<uint8_t>(100 * a / 255);
        p[2] = static_cast<uint8_t>(200 * a / 255); p[3] = static_cast<uint8_t>(a);
    }
    CVPixelBufferUnlockBaseAddress(input.pixels, 0);
    auto planes = split_planes(context, [CIImage imageWithCVPixelBuffer:input.pixels], width, height, space);
    Encoder encoder; Decoder decoder;
    reverse::Frame frame; frame.codec = 1; frame.width = width; frame.height = height; frame.pts = 1;
    frame.alpha = reverse::encode_alpha(planes.alpha);
    frame = encoder.encode(planes.color, std::move(frame));
    PixelOwner decoded{decoder.decode(frame)};
    if (!decoded.pixels) throw std::runtime_error("fixture decode missing");
    PixelOwner output{allocate(width, height)};
    [context render:join_planes(decoded.pixels, planes.alpha) toCVPixelBuffer:output.pixels bounds:CGRectMake(0, 0, width, height) colorSpace:space];
    CVPixelBufferLockBaseAddress(output.pixels, kCVPixelBufferLock_ReadOnly);
    const auto* result = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(output.pixels));
    const auto result_stride = CVPixelBufferGetBytesPerRow(output.pixels);
    bool valid = true;
    for (unsigned y : {16u, 48u}) for (unsigned x : {16u, 48u}) {
        const unsigned a = y < 32 ? (x < 32 ? 255 : 128) : (x < 32 ? 64 : 0);
        const auto* p = result + y * result_stride + x * 4;
        valid &= std::abs(int(p[3]) - int(a)) <= 1;
        valid &= std::abs(int(p[0]) - int(40 * a / 255)) < 12;
        valid &= std::abs(int(p[1]) - int(100 * a / 255)) < 12;
        valid &= std::abs(int(p[2]) - int(200 * a / 255)) < 12;
        if (!valid) std::fprintf(stderr, "pixel fixture (%u,%u) BGRA=%u,%u,%u,%u expected alpha=%u\n", x,y,p[0],p[1],p[2],p[3],a);
    }
    CVPixelBufferUnlockBaseAddress(output.pixels, kCVPixelBufferLock_ReadOnly);
    CGColorSpaceRelease(space);
    if (!valid) throw std::runtime_error("window color/alpha/orientation fixture mismatch");
    std::fprintf(stderr, "macos-window Metal color/alpha/orientation self-test passed; no windows/capture/input\n");
}
}

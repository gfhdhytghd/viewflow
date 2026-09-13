#include "window_pixels.hpp"
#include "window_codec.hpp"
#import <Metal/Metal.h>
#include <stdexcept>
#include <cmath>
#include <cstdio>
#include <algorithm>
#include <cstdlib>
#include <cstring>

namespace viewflow::macos {
namespace {
struct PixelPool {
    unsigned width{}, height{};
    CVPixelBufferPoolRef pool{};
    ~PixelPool() { if (pool) CVPixelBufferPoolRelease(pool); }
};
CVPixelBufferRef allocate(unsigned width, unsigned height) {
    // CoreVideo recycles only buffers whose final consumer has released them.
    // Four recent geometries cover resize oscillation without retaining a pool
    // for every intermediate size. In-flight images retain their own buffers.
    thread_local std::vector<std::unique_ptr<PixelPool>> pools;
    auto found = std::find_if(pools.begin(), pools.end(), [&](const auto& entry) {
        return entry->width == width && entry->height == height;
    });
    if (found == pools.end()) {
        auto entry = std::make_unique<PixelPool>();
        entry->width = width; entry->height = height;
        auto attributes = @{
            (__bridge NSString*)kCVPixelBufferWidthKey: @(width),
            (__bridge NSString*)kCVPixelBufferHeightKey: @(height),
            (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey: @YES};
        if (CVPixelBufferPoolCreate(nullptr, nullptr, (__bridge CFDictionaryRef)attributes, &entry->pool) != kCVReturnSuccess)
            throw std::runtime_error("allocate window pixel pool");
        if (pools.size() == 4) pools.erase(pools.begin());
        pools.push_back(std::move(entry));
    } else {
        auto entry = std::move(*found);
        pools.erase(found); pools.push_back(std::move(entry));
    }
    CVPixelBufferRef pixels = nullptr;
    if (CVPixelBufferPoolCreatePixelBuffer(nullptr, pools.back()->pool, &pixels) != kCVReturnSuccess)
        throw std::runtime_error("allocate pooled window pixels");
    return pixels;
}
struct PixelOwner {
    CVPixelBufferRef pixels;
    ~PixelOwner() { if (pixels) CVPixelBufferRelease(pixels); }
};
// One instance per serial source worker. Alpha is read as unorm BGRA and
// rounded back to its original byte; it is never filtered or quantized.
struct GPUAlpha {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pipeline;
    id<MTLComputePipelineState> split_pipeline;
    id<MTLBuffer> bytes;
    id<MTLCommandBuffer> command;
    CVMetalTextureCacheRef cache{};
    CVMetalTextureRef texture{};
    CVMetalTextureRef color_texture{};
    GPUAlpha() {
        const char* enabled = std::getenv("VIEWFLOW_MACOS_GPU_ALPHA");
        if ((enabled && std::strcmp(enabled, "0") == 0) || !device) return;
        NSError* error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:@"#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "kernel void extract_alpha(texture2d<float, access::read> image [[texture(0)]], "
            "device uchar* output [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { "
            "if(p.x < image.get_width() && p.y < image.get_height()) "
            "output[p.y * image.get_width() + p.x] = uchar(round(image.read(p).a * 255.0f)); }\n"
            "kernel void split_rgba(texture2d<float, access::read> image [[texture(0)]], "
            "texture2d<float, access::write> color [[texture(1)]], device uchar* output [[buffer(0)]], "
            "uint2 p [[thread_position_in_grid]]) { if(p.x >= image.get_width() || p.y >= image.get_height()) return; "
            "float4 v=image.read(p); output[p.y * image.get_width() + p.x]=uchar(round(v.a*255.0f)); "
            "color.write(float4(v.a>0.0f ? clamp(v.rgb/v.a,0.0f,1.0f) : float3(0.0f),1.0f),p); }"
            options:nil error:&error];
        if (library) pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"extract_alpha"] error:&error];
        if (library) split_pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"split_rgba"] error:&error];
        const char* color_enabled = std::getenv("VIEWFLOW_MACOS_GPU_COLOR");
        if (color_enabled && std::strcmp(color_enabled, "0") == 0) split_pipeline = nil;
        queue = [device newCommandQueue];
        if (CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &cache) != kCVReturnSuccess) cache = nullptr;
        std::fprintf(stderr, "macos-source-alpha gpu=%u combined-color=%u\n", unsigned(pipeline && queue && cache), unsigned(split_pipeline && queue && cache));
    }
    ~GPUAlpha() {
        if (command) [command waitUntilCompleted];
        if (texture) CFRelease(texture);
        if (color_texture) CFRelease(color_texture);
        if (cache) CFRelease(cache);
    }
    bool begin(CVPixelBufferRef pixels, unsigned width, unsigned height, CVPixelBufferRef color = nullptr) {
        auto active_pipeline = color ? split_pipeline : pipeline;
        if (!active_pipeline || !queue || !cache) return false;
        if (command) { [command waitUntilCompleted]; command = nil; }
        if (texture) { CFRelease(texture); texture = nullptr; }
        if (color_texture) { CFRelease(color_texture); color_texture = nullptr; }
        if (CVMetalTextureCacheCreateTextureFromImage(nullptr, cache, pixels, nullptr,
            MTLPixelFormatBGRA8Unorm, width, height, 0, &texture) != kCVReturnSuccess) return false;
        if (color && CVMetalTextureCacheCreateTextureFromImage(nullptr, cache, color, nullptr,
            MTLPixelFormatBGRA8Unorm, width, height, 0, &color_texture) != kCVReturnSuccess) return false;
        const size_t count = size_t(width) * height;
        if (!bytes || bytes.length < count) bytes = [device newBufferWithLength:count options:MTLResourceStorageModeShared];
        if (!bytes) return false;
        command = [queue commandBuffer];
        if (!command) return false;
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        if (!encoder) { command = nil; return false; }
        [encoder setComputePipelineState:active_pipeline];
        [encoder setTexture:CVMetalTextureGetTexture(texture) atIndex:0];
        if (color) [encoder setTexture:CVMetalTextureGetTexture(color_texture) atIndex:1];
        [encoder setBuffer:bytes offset:0 atIndex:0];
        const NSUInteger group_width = active_pipeline.threadExecutionWidth;
        const NSUInteger group_height = std::min<NSUInteger>(8, active_pipeline.maxTotalThreadsPerThreadgroup / group_width);
        [encoder dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(group_width, group_height, 1)];
        [encoder endEncoding];
        [command commit];
        return true;
    }
    bool finish(std::vector<uint8_t>& result) {
        [command waitUntilCompleted];
        const bool success = command.status == MTLCommandBufferStatusCompleted;
        if (success) std::memcpy(result.data(), bytes.contents, result.size());
        command = nil;
        if (texture) { CFRelease(texture); texture = nullptr; }
        if (color_texture) { CFRelease(color_texture); color_texture = nullptr; }
        return success;
    }
};
}
Planes split_planes(CIContext* context, CIImage* image, unsigned width, unsigned height, CGColorSpaceRef color_space,
    CVPixelBufferRef captured, bool captured_srgb) {
    if (!context || !image || !width || !height || uint64_t(width) * height > reverse::max_pixels)
        throw std::runtime_error("invalid window pixel extent");
    if (captured && (CVPixelBufferGetWidth(captured) != width || CVPixelBufferGetHeight(captured) != height ||
        CVPixelBufferGetPixelFormatType(captured) != kCVPixelFormatType_32BGRA))
        throw std::runtime_error("invalid direct capture extent/format");
    PixelOwner pixels{captured ? CVPixelBufferRetain(captured) : allocate(width, height)};
    const auto rect = CGRectMake(0, 0, width, height);
    if (!captured) {
        [context render:image toCVPixelBuffer:pixels.pixels bounds:rect colorSpace:color_space];
        // Synchronize the newly rendered atlas before another Metal queue reads
        // it, preserving the previous CPU-readback synchronization boundary.
        if (CVPixelBufferLockBaseAddress(pixels.pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
            throw std::runtime_error("synchronize source atlas");
        CVPixelBufferUnlockBaseAddress(pixels.pixels, kCVPixelBufferLock_ReadOnly);
    }
    Planes result; result.alpha.resize(static_cast<size_t>(width) * height);
    thread_local GPUAlpha alpha;
    result.color = allocate(width, height);
    // Capture is explicitly configured as sRGB. For other callers, preserve
    // Core Image color conversion unless their input has the same guarantee.
    if ((!captured || captured_srgb) && color_space && CGColorSpaceGetName(color_space) &&
        CFEqual(CGColorSpaceGetName(color_space), kCGColorSpaceSRGB) &&
        alpha.begin(pixels.pixels, width, height, result.color) && alpha.finish(result.alpha)) return result;
    const bool submitted = alpha.begin(pixels.pixels, width, height);
    // CIColorMatrix operates on unpremultiplied values; a separate
    // unpremultiply filter would divide by alpha twice.
    CIImage* color = captured ? image : [CIImage imageWithCVPixelBuffer:pixels.pixels];
    color = [color imageByApplyingFilter:@"CIColorMatrix" withInputParameters:@{
        @"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:0], @"inputBiasVector": [CIVector vectorWithX:0 Y:0 Z:0 W:1]}];
    [context render:color toCVPixelBuffer:result.color bounds:rect colorSpace:color_space];
    // Color rendering and alpha extraction can overlap. The shared alpha buffer
    // is reused only after completion; the captured IOSurface remains retained.
    if (!submitted || !alpha.finish(result.alpha)) {
        if (CVPixelBufferLockBaseAddress(pixels.pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
            throw std::runtime_error("lock source alpha");
        const auto* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pixels.pixels));
        const auto stride = CVPixelBufferGetBytesPerRow(pixels.pixels);
        for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; ++x) result.alpha[y * width + x] = base[y * stride + x * 4 + 3];
        CVPixelBufferUnlockBaseAddress(pixels.pixels, kCVPixelBufferLock_ReadOnly);
    }
    return result;
}
namespace {
CIImage* join_data(CVPixelBufferRef color, NSData* bytes) {
    const auto width = CVPixelBufferGetWidth(color), height = CVPixelBufferGetHeight(color);
    if (width * height != bytes.length) throw std::runtime_error("proxy alpha extent mismatch");
    CIImage* mask = [CIImage imageWithBitmapData:bytes bytesPerRow:width
        size:CGSizeMake(width, height) format:kCIFormatL8 colorSpace:nil];
    if (!mask) throw std::runtime_error("create proxy alpha mask");
    return join_planes(color, mask);
}
}
CIImage* join_planes(CVPixelBufferRef color, std::span<const uint8_t> alpha) {
    return join_data(color, [NSData dataWithBytes:alpha.data() length:alpha.size()]);
}
CIImage* make_alpha_mask(unsigned width, unsigned height, std::shared_ptr<const std::vector<uint8_t>> alpha) {
    if (!alpha || static_cast<size_t>(width) * height != alpha->size())
        throw std::runtime_error("owned proxy alpha extent mismatch");
    // NSData owns a block holding the immutable vector, not its raw allocation.
    NSData* bytes = [[NSData alloc] initWithBytesNoCopy:const_cast<uint8_t*>(alpha->data())
        length:alpha->size() deallocator:^(void* data, NSUInteger length) {
            (void)data; (void)length; (void)alpha.get();
        }];
    CIImage* mask = [CIImage imageWithBitmapData:bytes bytesPerRow:width
        size:CGSizeMake(width, height) format:kCIFormatL8 colorSpace:nil];
    if (!mask) throw std::runtime_error("create owned proxy alpha mask");
    return mask;
}
CIImage* join_planes(CVPixelBufferRef color, CIImage* mask) {
    if (!mask || mask.extent.size.width != CVPixelBufferGetWidth(color) ||
        mask.extent.size.height != CVPixelBufferGetHeight(color))
        throw std::runtime_error("proxy mask extent mismatch");
    return [[CIImage imageWithCVPixelBuffer:color] imageByApplyingFilter:@"CIBlendWithMask" withInputParameters:@{
        kCIInputBackgroundImageKey: [CIImage imageWithColor:CIColor.clearColor], kCIInputMaskImageKey: mask}];
}
CIImage* join_planes(CVPixelBufferRef color, std::shared_ptr<const std::vector<uint8_t>> alpha) {
    return join_planes(color, make_alpha_mask(CVPixelBufferGetWidth(color), CVPixelBufferGetHeight(color), std::move(alpha)));
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
    for (const bool direct : {false, true}) {
    auto planes = split_planes(context, [CIImage imageWithCVPixelBuffer:input.pixels], width, height, space,
        direct ? input.pixels : nullptr, true);
    for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; ++x) {
        const unsigned a = y < 32 ? (x < 32 ? 255 : 128) : (x < 32 ? 64 : 0);
        if (planes.alpha[y * width + x] != a) throw std::runtime_error("source alpha must remain exact");
    }
    Encoder encoder; Decoder decoder;
    reverse::Frame frame; frame.codec = 1; frame.width = width; frame.height = height; frame.pts = 1;
    frame.alpha = reverse::encode_alpha(planes.alpha);
    frame = encoder.encode(planes.color, std::move(frame));
    PixelOwner decoded{decoder.decode(frame)};
    if (!decoded.pixels) throw std::runtime_error("fixture decode missing");
    PixelOwner output{allocate(width, height)};
    auto owned_alpha = std::make_shared<const std::vector<uint8_t>>(std::move(planes.alpha));
    CIImage* reconstructed = join_planes(decoded.pixels, owned_alpha);
    // Core Image may retain or upload the bytes immediately. Either way, the
    // producer may release its reference before the composed image is rendered.
    owned_alpha.reset();
    [context render:reconstructed toCVPixelBuffer:output.pixels bounds:CGRectMake(0, 0, width, height) colorSpace:space];
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
    if (!valid) throw std::runtime_error("window color/alpha/orientation fixture mismatch");
    }
    // Odd extents exercise dispatch edges and CV row padding; every alpha byte
    // must survive GPU extraction exactly, including low-opacity shadows.
    for (const auto extent : {std::pair{259u, 67u}, std::pair{71u, 31u}, std::pair{259u, 67u}}) {
        PixelOwner ramp{allocate(extent.first, extent.second)};
        if (CVPixelBufferLockBaseAddress(ramp.pixels, 0) != kCVReturnSuccess) throw std::runtime_error("alpha ramp lock");
        auto* data = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(ramp.pixels));
        const auto pitch = CVPixelBufferGetBytesPerRow(ramp.pixels);
        for (unsigned y = 0; y < extent.second; ++y) for (unsigned x = 0; x < extent.first; ++x) {
            auto* p = data + y * pitch + x * 4;
            const auto a = uint8_t(y * extent.first + x);
            p[0] = a / 4; p[1] = a / 2; p[2] = a; p[3] = a;
        }
        CVPixelBufferUnlockBaseAddress(ramp.pixels, 0);
        auto planes = split_planes(context, [CIImage imageWithCVPixelBuffer:ramp.pixels],
            extent.first, extent.second, space, ramp.pixels, true);
        for (size_t i = 0; i < planes.alpha.size(); ++i)
            if (planes.alpha[i] != uint8_t(i)) throw std::runtime_error("GPU source alpha byte mismatch");
        if (CVPixelBufferLockBaseAddress(planes.color, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
            throw std::runtime_error("GPU color fixture lock");
        const auto* colors = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(planes.color));
        const auto color_pitch = CVPixelBufferGetBytesPerRow(planes.color);
        bool valid = true;
        for (unsigned y = 0; y < extent.second; ++y) for (unsigned x = 0; x < extent.first; ++x) {
            const unsigned a = uint8_t(y * extent.first + x);
            const auto* p = colors + y * color_pitch + x * 4;
            for (unsigned c = 0; c < 3; ++c) {
                const unsigned raw = c == 0 ? a / 4 : c == 1 ? a / 2 : a;
                const int expected = a ? int(std::lround(raw * 255. / a)) : 0;
                valid &= std::abs(int(p[c]) - expected) <= 1;
            }
            valid &= p[3] == 255;
        }
        CVPixelBufferUnlockBaseAddress(planes.color, kCVPixelBufferLock_ReadOnly);
        if (!valid) throw std::runtime_error("GPU unpremultiplied color mismatch");
    }
    CGColorSpaceRelease(space);
    std::fprintf(stderr, "macos-window Metal color/alpha/orientation self-test passed; no windows/capture/input\n");
}
}

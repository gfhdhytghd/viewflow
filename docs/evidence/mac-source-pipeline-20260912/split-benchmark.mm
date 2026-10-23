#include "window_pixels.hpp"
#import <Metal/Metal.h>
#include <chrono>
#include <cstdio>
#include <stdexcept>

int main() {
    @autoreleasepool {
        constexpr unsigned width = 2560, height = 1440;
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CIContext* context = [CIContext contextWithMTLDevice:MTLCreateSystemDefaultDevice()
            options:@{kCIContextWorkingColorSpace: (__bridge id)space}];
        CVPixelBufferRef capture = nullptr;
        NSDictionary* attributes = @{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey: @YES};
        if (CVPixelBufferCreate(nullptr, width, height, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)attributes, &capture) != kCVReturnSuccess) return 1;
        for (unsigned i = 0; i < 48; ++i) {
            @autoreleasepool {
                CIImage* pattern = [[CIImage imageWithColor:[CIColor colorWithRed:(i % 17) / 17.
                    green:0.5 blue:0.25 alpha:0.5]] imageByCroppingToRect:CGRectMake(0, 0, width, height)];
                [context render:pattern toCVPixelBuffer:capture bounds:CGRectMake(0, 0, width, height) colorSpace:space];
                const auto start = std::chrono::steady_clock::now();
                auto planes = viewflow::macos::split_planes(context, [CIImage imageWithCVPixelBuffer:capture],
                    width, height, space, capture);
                // Await the color output as well as the completed alpha bytes.
                if (CVPixelBufferLockBaseAddress(planes.color, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return 2;
                CVPixelBufferUnlockBaseAddress(planes.color, kCVPixelBufferLock_ReadOnly);
                const auto ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
                if (i >= 8) std::printf("%.6f\n", ms);
                if (planes.alpha.front() != 128 || planes.alpha.back() != 128) return 3;
            }
        }
        CVPixelBufferRelease(capture);
        CGColorSpaceRelease(space);
    }
}

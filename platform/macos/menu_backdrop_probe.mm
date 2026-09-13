#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <algorithm>
#include <cmath>

@interface VFBackdropProbeWindow : NSWindow
@end
@implementation VFBackdropProbeWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static void pump(double seconds) {
    NSDate* end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

static bool snapshot(SCContentFilter* filter, CGRect crop, NSString* path) API_AVAILABLE(macos(14.0));
static bool snapshot(SCContentFilter* filter, CGRect crop, NSString* path) {
    SCStreamConfiguration* config = [SCStreamConfiguration new];
    config.width = static_cast<size_t>(crop.size.width * 2);
    config.height = static_cast<size_t>(crop.size.height * 2);
    config.showsCursor = NO;
    config.shouldBeOpaque = NO;
    config.ignoreShadowsSingleWindow = YES;
    config.ignoreShadowsDisplay = YES;
    if (crop.origin.x >= 0) config.sourceRect = crop;
    __block bool done = false;
    __block bool success = false;
    [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef image, NSError* error) {
        if (image) CGImageRetain(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image && !error) {
                NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
                NSData* png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                success = [png writeToFile:path atomically:YES];
            } else std::fprintf(stderr, "capture: %s\n", error.localizedDescription.UTF8String ?: "no image");
            if (image) CGImageRelease(image);
            done = true;
        });
    }];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done && deadline.timeIntervalSinceNow > 0) pump(0.01);
    return done && success;
}

// Retain the native display-composited material while restoring the independently
// captured window shape. Remove the background contribution at antialiased edges
// before storing premultiplied RGB, so the receiver does not blend it twice.
static bool extract_material(NSString* directory, NSString* phase) {
    auto read = [&](NSString* suffix) {
        NSString* path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.png", phase, suffix]];
        return [[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:path]];
    };
    NSBitmapImageRep* shape = read(@"window");
    NSBitmapImageRep* scene = read(@"display");
    NSBitmapImageRep* behind = read(@"behind");
    if (!shape || !scene || !behind) return false;
    const size_t width = scene.pixelsWide, height = scene.pixelsHigh;
    if (shape.pixelsWide != (NSInteger)width || shape.pixelsHigh != (NSInteger)height ||
        behind.pixelsWide != (NSInteger)width || behind.pixelsHigh != (NSInteger)height) return false;
    CGColorSpaceRef colors = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    auto pixels = [&](NSBitmapImageRep* image) {
        std::vector<unsigned char> bytes(width * height * 4);
        CGContextRef ctx = CGBitmapContextCreate(bytes.data(), width, height, 8, width * 4, colors,
            static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) | kCGBitmapByteOrder32Big);
        if (!ctx) return std::vector<unsigned char>{};
        CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image.CGImage);
        CGContextRelease(ctx);
        return bytes;
    };
    auto mask = pixels(shape), full = pixels(scene), background = pixels(behind);
    if (mask.empty() || full.empty() || background.empty()) { CGColorSpaceRelease(colors); return false; }
    for (size_t i = 0; i < full.size(); i += 4) {
        const unsigned alpha = mask[i + 3];
        for (unsigned c = 0; c < 3; ++c) {
            const int contribution = (background[i + c] * (255 - alpha) + 127) / 255;
            full[i + c] = static_cast<unsigned char>(std::clamp(int(full[i + c]) - contribution, 0, int(alpha)));
        }
        full[i + 3] = static_cast<unsigned char>(alpha);
    }
    CGContextRef ctx = CGBitmapContextCreate(full.data(), width, height, 8, width * 4, colors,
        static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) | kCGBitmapByteOrder32Big);
    CGImageRef result = ctx ? CGBitmapContextCreateImage(ctx) : nullptr;
    bool success = false;
    if (result) {
        NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithCGImage:result];
        NSData* png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        success = [png writeToFile:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-material.png", phase]] atomically:YES];
        CGImageRelease(result);
    }
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(colors);
    return success;
}

extern "C" int viewflow_menu_backdrop_probe(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc == 2 && std::strcmp(argv[1], "--help") == 0) {
            std::puts("menu-backdrop-probe WINDOW_ID BACKGROUND_IMAGE OUTPUT_DIRECTORY\nCaptures an already-open menu before/after a passive background; no input or activation.");
            return 0;
        }
        const bool list = argc == 2 && std::strcmp(argv[1], "--list") == 0;
        if (!list && argc != 4) return 2;
        if (@available(macOS 14.0, *)) {
            [NSApplication sharedApplication];
            const bool watch = !list && std::strcmp(argv[1], "--watch") == 0;
            const unsigned window_id = list ? 0 : static_cast<unsigned>(std::strtoul(argv[1], nullptr, 10));
            NSImage* image = list ? nil : [[NSImage alloc] initWithContentsOfFile:@(argv[2])];
            NSString* output = list ? nil : @(argv[3]);
            if (!list && ((!window_id && !watch) || !image || ![NSFileManager.defaultManager createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:nil])) return 2;
            __block SCShareableContent* content = nil;
            __block bool done = false;
            [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:^(SCShareableContent* value, NSError* error) {
                if (error) std::fprintf(stderr, "inventory: %s\n", error.localizedDescription.UTF8String);
                dispatch_async(dispatch_get_main_queue(), ^{ content = error ? nil : value; done = true; });
            }];
            NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:10];
            while (!done && deadline.timeIntervalSinceNow > 0) pump(0.01);
            if (list) {
                for (SCWindow* candidate in content.windows)
                    std::printf("id=%u layer=%ld pid=%d app=%s bounds=%.0f,%.0f,%.0f,%.0f\n", candidate.windowID, (long)candidate.windowLayer, candidate.owningApplication.processID, candidate.owningApplication.applicationName.UTF8String, candidate.frame.origin.x, candidate.frame.origin.y, candidate.frame.size.width, candidate.frame.size.height);
                return content ? 0 : 3;
            }
            SCWindow* menu = nil;
            NSDate* menu_deadline = [NSDate dateWithTimeIntervalSinceNow:60];
            do {
                for (SCWindow* candidate in content.windows) {
                    const bool popup = candidate.windowLayer == CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey);
                    const bool panel = candidate.windowLayer == 20 && candidate.frame.size.height < 300 && candidate.frame.size.width < 1200;
                    if ((watch || candidate.windowID == window_id) && (popup || panel)) { menu = candidate; break; }
                }
                if (menu || !watch || !content) break;
                pump(0.25);
                done = false;
                [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:^(SCShareableContent* value, NSError* error) {
                    dispatch_async(dispatch_get_main_queue(), ^{ content = error ? nil : value; done = true; });
                }];
                while (!done && menu_deadline.timeIntervalSinceNow > 0) pump(0.01);
            } while (menu_deadline.timeIntervalSinceNow > 0);
            if (!menu) { std::fprintf(stderr, "Requested on-screen popup menu or attached panel is absent\n"); return 3; }
            SCDisplay* display = nil;
            for (SCDisplay* candidate in content.displays)
                if (CGRectContainsRect(candidate.frame, menu.frame)) display = candidate;
            if (!display) return 3;
            auto independent = [[SCContentFilter alloc] initWithDesktopIndependentWindow:menu];
            auto screen = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
            auto selected = [[SCContentFilter alloc] initWithDisplay:display includingWindows:@[menu]];
            auto behind = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[menu]];
            CGRect crop = CGRectOffset(menu.frame, -display.frame.origin.x, -display.frame.origin.y);
            CGRect single = CGRectMake(-1, 0, menu.frame.size.width, menu.frame.size.height);
            bool success = snapshot(independent, single, [output stringByAppendingPathComponent:@"before-window.png"]);
            success = snapshot(screen, crop, [output stringByAppendingPathComponent:@"before-display.png"]) && success;
            success = snapshot(selected, crop, [output stringByAppendingPathComponent:@"before-selected.png"]) && success;
            success = snapshot(behind, crop, [output stringByAppendingPathComponent:@"before-behind.png"]) && success;
            CGRect bounds = CGRectInset(menu.frame, -64, -64);
            const double main_height = CGDisplayBounds(CGMainDisplayID()).size.height;
            NSRect cocoa = NSMakeRect(bounds.origin.x, main_height - CGRectGetMaxY(bounds), bounds.size.width, bounds.size.height);
            VFBackdropProbeWindow* backing = [[VFBackdropProbeWindow alloc] initWithContentRect:cocoa styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            backing.releasedWhenClosed = NO;
            backing.ignoresMouseEvents = YES;
            backing.hasShadow = NO;
            backing.level = menu.windowLayer;
            NSImageView* view = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, bounds.size.width, bounds.size.height)];
            view.image = image;
            view.imageScaling = NSImageScaleAxesIndependently;
            backing.contentView = view;
            [backing orderWindow:NSWindowBelow relativeTo:menu.windowID];
            pump(0.3);
            success = snapshot(independent, single, [output stringByAppendingPathComponent:@"after-window.png"]) && success;
            success = snapshot(screen, crop, [output stringByAppendingPathComponent:@"after-display.png"]) && success;
            success = snapshot(selected, crop, [output stringByAppendingPathComponent:@"after-selected.png"]) && success;
            success = snapshot(behind, crop, [output stringByAppendingPathComponent:@"after-behind.png"]) && success;
            [backing orderOut:nil];
            [backing close];
            success = extract_material(output, @"before") && success;
            success = extract_material(output, @"after") && success;
            std::printf("menu=%u output=%s success=%d\n", menu.windowID, output.UTF8String, success);
            return success ? 0 : 1;
        }
        return 2;
    }
}

#ifndef VIEWFLOW_BACKDROP_EMBEDDED
int main(int argc, const char* argv[]) { return viewflow_menu_backdrop_probe(argc, argv); }
#endif

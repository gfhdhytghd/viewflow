#include "window_native.hpp"
#include "window_parking.hpp"
#include "../reverse-common/window_scope.hpp"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <atomic>
#include <csignal>
#include <cstdio>

// CoreGraphics' virtual-display interfaces are not in the public SDK.
// Resolve classes dynamically so an unavailable implementation is reported.
// Interface reference: Chromium ui/display/mac/test/virtual_display_util_mac.mm.
@interface VFVirtualDescriptor : NSObject
@property unsigned vendorID;
@property unsigned productID;
@property unsigned serialNum;
@property unsigned serialNumber;
@property(strong) NSString* name;
@property CGSize sizeInMillimeters;
@property unsigned maxPixelsWide;
@property unsigned maxPixelsHigh;
@property CGPoint redPrimary;
@property CGPoint greenPrimary;
@property CGPoint bluePrimary;
@property CGPoint whitePoint;
@property(strong) id queue;
@end
@interface VFVirtualSettings : NSObject
@property(strong) NSArray* modes;
@property unsigned hiDPI;
@property unsigned rotation;
@end
@interface VFVirtualMode : NSObject
- (id)initWithWidth:(unsigned)width height:(unsigned)height refreshRate:(double)rate;
@end
@interface VFVirtualDisplay : NSObject
@property(readonly) unsigned displayID;
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end
namespace viewflow::macos {
namespace {
volatile std::sig_atomic_t stopping = 0;
void stop(int) { stopping = 1; }
}
bool is_parking_display(CGDirectDisplayID display) {
    return CGDisplayVendorNumber(display) == parking_vendor && CGDisplayModelNumber(display) == parking_product;
}
std::optional<bool> remote_window_needed(CGRect bounds) {
    CGDirectDisplayID displays[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) return std::nullopt;
    std::vector<reverse::ScopeRect> physical, remote;
    for (uint32_t i = 0; i < count; ++i) {
        const auto r = CGDisplayBounds(displays[i]);
        (is_parking_display(displays[i]) ? remote : physical).push_back({r.origin.x,r.origin.y,r.size.width,r.size.height});
    }
    return reverse::needs_remote({bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height},physical,remote);
}
CGPoint backing_position(CGPoint requested, CGSize size) {
    CGDirectDisplayID displays[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) return requested;
    CGRect parking = CGRectNull;
    const CGRect proposed{requested, size};
    for (uint32_t i = 0; i < count; ++i) {
        const CGRect bounds = CGDisplayBounds(displays[i]);
        if (is_parking_display(displays[i])) parking = bounds;
        else if (CGRectIntersectsRect(bounds, proposed)) return requested;
    }
    if (CGRectIsNull(parking)) return requested;
    return CGPointMake(std::clamp(requested.x, parking.origin.x,
                           parking.origin.x + std::max(0., parking.size.width - size.width)),
                       std::clamp(requested.y, parking.origin.y,
                           parking.origin.y + std::max(0., parking.size.height - size.height)));
}
int run_parking_display(int width, int height, int x, int y) {
    Class descriptor_class = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class display_class = NSClassFromString(@"CGVirtualDisplay");
    Class settings_class = NSClassFromString(@"CGVirtualDisplaySettings");
    Class mode_class = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descriptor_class || !display_class || !settings_class || !mode_class)
        throw std::runtime_error("macOS virtual display implementation unavailable");
    CGDirectDisplayID physical[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, physical, &count) != kCGErrorSuccess || !count)
        throw std::runtime_error("physical display inventory unavailable");
    for (uint32_t i = 0; i < count; ++i) {
        if (is_parking_display(physical[i])) throw std::runtime_error("Viewflow parking display already owned");
    }
    const auto original_main = CGMainDisplayID();
    VFVirtualDescriptor* descriptor = [(id)descriptor_class new];
    descriptor.vendorID = parking_vendor; descriptor.productID = parking_product;
    descriptor.serialNum = 1; descriptor.serialNumber = 1;
    descriptor.name = @"Viewflow Remote Windows";
    descriptor.maxPixelsWide = width * 2; descriptor.maxPixelsHigh = height * 2;
    descriptor.sizeInMillimeters = CGSizeMake(800, 422);
    descriptor.redPrimary = CGPointMake(.64, .33); descriptor.greenPrimary = CGPointMake(.30, .60);
    descriptor.bluePrimary = CGPointMake(.15, .06); descriptor.whitePoint = CGPointMake(.3127, .3290);
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    VFVirtualDisplay* display = [[(id)display_class alloc] initWithDescriptor:descriptor];
    if (!display) throw std::runtime_error("create Viewflow parking display failed");
    VFVirtualSettings* settings = [(id)settings_class new];
    // Virtual modes are in points; the descriptor holds the 2x pixel limits.
    settings.hiDPI = 1; settings.rotation = 0;
    settings.modes = @[[[(id)mode_class alloc] initWithWidth:width height:height refreshRate:60]];
    if (![display applySettings:settings]) throw std::runtime_error("configure Viewflow parking display failed");
    CGDisplayConfigRef transaction = nullptr;
    if (CGBeginDisplayConfiguration(&transaction) != kCGErrorSuccess)
        throw std::runtime_error("begin parking display arrangement failed");
    const auto changed = CGConfigureDisplayOrigin(transaction, display.displayID, x, y);
    if (changed != kCGErrorSuccess) { CGCancelDisplayConfiguration(transaction); throw std::runtime_error("arrange parking display failed"); }
    if (CGCompleteDisplayConfiguration(transaction, kCGConfigureForSession) != kCGErrorSuccess)
        throw std::runtime_error("commit parking display arrangement failed");
    if (CGMainDisplayID() != original_main) throw std::runtime_error("parking display unexpectedly changed main display");
    if (const auto mode = CGDisplayCopyDisplayMode(display.displayID)) {
        std::fprintf(stderr, "window-parking HiDPI logical=%zux%zu pixels=%zux%zu\n",
            CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode),
            CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode));
        CGDisplayModeRelease(mode);
    }
    std::signal(SIGINT, stop); std::signal(SIGTERM, stop);
    std::fprintf(stderr, "window-parking ready display=%u origin=%d,%d size=%dx%d main=%u\n", display.displayID, x, y, width, height, original_main);
    while (!stopping && transport_owner_alive()) {
        @autoreleasepool { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]]; }
    }
    // Releasing the display returns its windows to the remaining desktop.
    display = nil;
    return 0;
}
}

#include "window_native.hpp"
#include "window_parking.hpp"
#import <Foundation/Foundation.h>
#include "window_capture_scope.hpp"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <cstdio>

namespace viewflow::macos {
int discover_windows(bool enumerate) {
    const bool allowed = CGPreflightScreenCaptureAccess();
    NSMutableDictionary* report = [@{
        @"schema_version": @1,
        @"screen_recording_authorized": @(allowed),
        @"event_post_authorized": @(CGPreflightPostEventAccess()),
        @"bundle_identifier": NSBundle.mainBundle.bundleIdentifier ?: @"unbundled",
        @"enumeration": @"not_requested"
    } mutableCopy];
    NSMutableArray* physical = [NSMutableArray array];
    NSMutableArray* remote = [NSMutableArray array];
    CGDirectDisplayID displays[32]; uint32_t display_count = 0;
    if (CGGetOnlineDisplayList(32, displays, &display_count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < display_count; ++i) {
            const auto bounds = CGDisplayBounds(displays[i]);
            NSMutableArray* target = is_parking_display(displays[i]) ? remote : physical;
            [target addObject:@[@(bounds.origin.x), @(bounds.origin.y), @(bounds.size.width), @(bounds.size.height)]];
        }
        report[@"physical_displays"] = physical; report[@"remote_displays"] = remote;
    }
    int status = enumerate && !allowed ? 3 : 0;
    if (enumerate && !allowed) report[@"enumeration"] = @"permission_required";
    if (enumerate && allowed) {
        // Inventory is metadata only. Repeated ScreenCaptureKit discovery
        // creates capture-service clients and stalls unrelated live captures.
        CFArrayRef items = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
        if (!items) { report[@"enumeration"] = @"failed"; status = 1; }
        else {
            NSMutableArray* windows = [NSMutableArray array];
            for (NSDictionary* item in (__bridge NSArray*)items) {
                const auto pid = [item[(__bridge NSString*)kCGWindowOwnerPID] intValue];
                NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                CGRect bounds{};
                NSDictionary* geometry = item[(__bridge NSString*)kCGWindowBounds];
                if (!geometry || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)geometry, &bounds)) continue;
                if (sharing_control_window(pid, bounds)) continue;
                [windows addObject:@{
                    @"window_id": item[(__bridge NSString*)kCGWindowNumber] ?: @0,
                    @"pid": @(pid), @"bundle_id": app.bundleIdentifier ?: @"",
                    @"application_name": app.localizedName ?: item[(__bridge NSString*)kCGWindowOwnerName] ?: @"",
                    @"executable_name": app.executableURL.lastPathComponent ?: @"",
                    @"on_screen": item[(__bridge NSString*)kCGWindowIsOnscreen] ?: @NO,
                    @"layer": item[(__bridge NSString*)kCGWindowLayer] ?: @0,
                    @"title": item[(__bridge NSString*)kCGWindowName] ?: @"",
                    @"frame_points": @[@(bounds.origin.x), @(bounds.origin.y), @(bounds.size.width), @(bounds.size.height)]
                }];
            }
            CFRelease(items);
            report[@"windows"] = windows; report[@"enumeration"] = @"ok";
        }
    }
    NSData* data = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    if (!data || std::fwrite(data.bytes, 1, data.length, stdout) != data.length || std::puts("") == EOF) return 1;
    return status;
}
}

// Read-only native discovery. No permission prompts, capture, or input injection.
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

static int emit(NSDictionary *report, int status) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report
        options:NSJSONWritingSortedKeys error:&error];
    if (!data) {
        fprintf(stderr, "JSON serialization failed: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }
    if (fwrite(data.bytes, 1, data.length, stdout) != data.length || puts("") == EOF) {
        return 1;
    }
    return status;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL enumerate = NO;
        if (argc == 2 && strcmp(argv[1], "--help") == 0) {
            puts("Usage: viewflow-macos-probe [--list-windows]\n"
                 "Reports permissions and Metal availability as JSON.\n"
                 "--list-windows enumerates ScreenCaptureKit content if already authorized.");
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--list-windows") == 0) enumerate = YES;
        else if (argc != 1) {
            fputs("Usage: viewflow-macos-probe [--list-windows]\n", stderr);
            return 2;
        }
        BOOL screenAccess = CGPreflightScreenCaptureAccess();
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSMutableDictionary *report = [@{
            @"schema_version": @1,
            @"os_version": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"screen_recording_authorized": @(screenAccess),
            @"accessibility_authorized": @(AXIsProcessTrusted()),
            @"metal_device": (id)device.name ?: [NSNull null],
            @"capture_implemented": @NO,
            @"presentation_implemented": @NO,
            @"input_implemented": @NO,
            @"enumeration": @"not_requested"
        } mutableCopy];
        if (!enumerate) return emit(report, 0);
        if (!screenAccess) {
            report[@"enumeration"] = @"permission_required";
            return emit(report, 3);
        }
        // Deliver completion to the main queue so the report has one owner.
        // This watchdog bounds only this diagnostic process, never a session.
        __block BOOL done = NO;
        __block int status = 0;
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES
            onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error || !content) {
                        report[@"enumeration"] = @"failed";
                        report[@"error"] = error.localizedDescription ?: @"No shareable content";
                        status = 1;
                    } else {
                        NSMutableArray *windows = [NSMutableArray array];
                        for (SCWindow *window in content.windows) {
                            CGRect r = window.frame;
                            [windows addObject:@{
                                @"window_id": @(window.windowID),
                                @"pid": @(window.owningApplication.processID),
                                @"bundle_id": window.owningApplication.bundleIdentifier ?: @"",
                                @"title": window.title ?: @"",
                                @"on_screen": @(window.onScreen),
                                @"frame_points": @[@(r.origin.x), @(r.origin.y),
                                    @(r.size.width), @(r.size.height)]
                            }];
                        }
                        report[@"enumeration"] = @"ok";
                        report[@"windows"] = windows;
                        report[@"display_count"] = @(content.displays.count);
                    }
                    done = YES;
                });
            }];
        double deadline = NSProcessInfo.processInfo.systemUptime + 15.0;
        while (!done && NSProcessInfo.processInfo.systemUptime < deadline) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        if (!done) {
            report[@"enumeration"] = @"operation_timeout";
            status = 4;
        }
        return emit(report, status);
    }
}

#include "window_native.hpp"
#include "window_codec.hpp"
#include "window_io.hpp"
#include "window_keys.hpp"
#include "window_pixels.hpp"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <cmath>
#include <map>
#include <set>

namespace vf = viewflow::reverse;
namespace vm = viewflow::macos;
namespace {
struct Capture;
struct Source;
}
@interface VFWindowCapture : NSObject <SCStreamOutput, SCStreamDelegate> {
@public Capture* capture;
}
@end
namespace {
struct Capture {
    Source* owner{};
    unsigned native{}, pid{};
    uint64_t id{}, geometry_ack{};
    CGRect bounds{};
    std::string title;
    SCStream* __strong stream = nil;
    VFWindowCapture* __strong callback = nil;
    CVPixelBufferRef latest{};
    unsigned width{}, height{}, published_width{}, published_height{};
    bool active{true}, stopping{}, stopped{}, updating{}, restarting{}, starting{};
    double retry_after{};
    ~Capture() { if (callback) callback->capture = nullptr; if (latest) CVPixelBufferRelease(latest); }
    void stop() {
        active = false;
        if (stopping || !stream) { if (!stream) stopped = true; return; }
        if (stopped) { stopping = true; return; }
        stopping = true;
        [stream stopCaptureWithCompletionHandler:^(NSError* error) {
            if (error) std::fprintf(stderr, "window %u capture stop: %s\n", native, error.localizedDescription.UTF8String);
            dispatch_async(dispatch_get_main_queue(), ^{ stopped = true; });
        }];
    }
};
CGRect window_bounds(unsigned window, unsigned pid) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, window);
    CGRect bounds = CGRectNull;
    if (list) {
        for (NSDictionary* item in (__bridge NSArray*)list) {
            if ([item[(__bridge NSString*)kCGWindowNumber] unsignedIntValue] == window &&
                [item[(__bridge NSString*)kCGWindowOwnerPID] unsignedIntValue] == pid) {
                CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)item[(__bridge NSString*)kCGWindowBounds], &bounds);
                break;
            }
        }
        CFRelease(list);
    }
    return bounds;
}
// Public AX APIs don't expose CGWindowID. Match a unique native AX window by
// its current bounds within the already pinned PID; ambiguous matches report
// an operation failure instead of moving or closing a different window.
AXUIElementRef ax_window(const Capture& capture) {
    AXUIElementRef app = AXUIElementCreateApplication(static_cast<pid_t>(capture.pid));
    CFTypeRef list = nullptr;
    const auto status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &list);
    CFRelease(app);
    if (status != kAXErrorSuccess || !list) return nullptr;
    AXUIElementRef match = nullptr;
    if (CFGetTypeID(list) == CFArrayGetTypeID()) {
        const auto array = static_cast<CFArrayRef>(list);
        for (CFIndex i = 0; i < CFArrayGetCount(array); ++i) {
            const auto window = static_cast<AXUIElementRef>(const_cast<void*>(CFArrayGetValueAtIndex(array, i)));
            CFTypeRef position = nullptr, size = nullptr;
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &position);
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &size);
            CGPoint p{}; CGSize s{};
            const bool readable = position && size && CFGetTypeID(position) == AXValueGetTypeID() && CFGetTypeID(size) == AXValueGetTypeID() &&
                AXValueGetValue(static_cast<AXValueRef>(position), kAXValueTypeCGPoint, &p) &&
                AXValueGetValue(static_cast<AXValueRef>(size), kAXValueTypeCGSize, &s);
            if (position) CFRelease(position); if (size) CFRelease(size);
            if (readable && std::abs(p.x - capture.bounds.origin.x) < 2 && std::abs(p.y - capture.bounds.origin.y) < 2 &&
                std::abs(s.width - capture.bounds.size.width) < 2 && std::abs(s.height - capture.bounds.size.height) < 2) {
                if (match) { CFRelease(match); match = nullptr; break; }
                match = static_cast<AXUIElementRef>(CFRetain(window));
            }
        }
    }
    CFRelease(list); return match;
}
struct Held { uint64_t window{}; unsigned code{}; };
struct Source {
    vm::Options options;
    vm::Output output{1};
    vm::Encoder encoder;
    CIContext* __strong context;
    CGColorSpaceRef color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGEventSourceRef event_source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    std::map<unsigned, std::unique_ptr<Capture>> captures;
    std::map<unsigned, Held> keys, buttons;
    std::map<unsigned, std::pair<double, unsigned>> clicks;
    CGPoint pointer{};
    uint64_t sequence{}, frame_sequence{};
    bool dirty{}, discovery_done{}, quitting{}, caps{};
    std::string failure;
    Source(const vm::Options& config) : options(config) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) throw std::runtime_error("Metal device unavailable");
        context = [CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace: (__bridge id)color_space}];
        CGEventRef event = CGEventCreate(nullptr);
        if (event) { pointer = CGEventGetLocation(event); CFRelease(event); }
    }
    ~Source() {
        release(0);
        if (event_source) CFRelease(event_source);
        CGColorSpaceRelease(color_space);
    }
    CGEventFlags flags() const {
        CGEventFlags result = caps ? kCGEventFlagMaskAlphaShift : 0;
        for (const auto& [code, _] : keys) {
            switch (code) {
            case 42: result |= kCGEventFlagMaskShift | 0x02; break;
            case 54: result |= kCGEventFlagMaskShift | 0x04; break;
            case 29: result |= kCGEventFlagMaskControl | 0x01; break;
            case 97: result |= kCGEventFlagMaskControl | 0x2000; break;
            case 56: result |= kCGEventFlagMaskAlternate | 0x20; break;
            case 100: result |= kCGEventFlagMaskAlternate | 0x40; break;
            case 125: result |= kCGEventFlagMaskCommand | 0x08; break;
            case 126: result |= kCGEventFlagMaskCommand | 0x10; break;
            }
        }
        return result;
    }
    bool post(CGEventRef event) {
        if (!event) return false;
        if (!CGPreflightPostEventAccess()) { CFRelease(event); return false; }
        CGEventSetFlags(event, flags());
        CGEventSetIntegerValueField(event, kCGEventSourceUserData, 0x56464c57);
        CGEventPost(kCGHIDEventTap, event); CFRelease(event); return true;
    }
    bool mouse_button(unsigned evdev, bool down, unsigned count = 1) {
        const unsigned button = evdev - 272;
        if (button > 4) return false;
        const auto type = button == 0 ? (down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp)
                        : button == 1 ? (down ? kCGEventRightMouseDown : kCGEventRightMouseUp)
                                      : (down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp);
        const auto event = CGEventCreateMouseEvent(event_source, type, pointer, static_cast<CGMouseButton>(button));
        if (event) CGEventSetIntegerValueField(event, kCGMouseEventClickState, count);
        return post(event);
    }
    void release(uint64_t window) {
        for (auto it = keys.begin(); it != keys.end();) {
            if (window && it->second.window != window) { ++it; continue; }
            const auto held = *it; it = keys.erase(it);
            if (!post(CGEventCreateKeyboardEvent(event_source, static_cast<CGKeyCode>(held.second.code), false))) keys.insert(held);
        }
        for (auto it = buttons.begin(); it != buttons.end();) {
            if (window && it->second.window != window) { ++it; continue; }
            if (mouse_button(it->first, false)) it = buttons.erase(it); else ++it;
        }
    }
    bool focus(Capture& capture) {
        AXUIElementRef window = ax_window(capture);
        if (!window) { std::fprintf(stderr, "window %u AX target unavailable\n", capture.native); return false; }
        NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:static_cast<pid_t>(capture.pid)];
        const bool activated = app && (app.active || [app activateWithOptions:0]);
        const auto raised = AXUIElementPerformAction(window, kAXRaiseAction);
        CFRelease(window);
        if (!activated || raised != kAXErrorSuccess) {
            std::fprintf(stderr, "window %u native focus operation unavailable\n", capture.native); return false;
        }
        return true;
    }
    void input(const vf::Input& event) {
        if (event.sequence <= sequence) { std::fprintf(stderr, "window input sequence regression\n"); return; }
        sequence = event.sequence;
        if (event.kind == vf::InputKind::release) { release(event.id); return; }
        Capture* capture = nullptr;
        for (auto& [_, candidate] : captures) if (candidate->active && candidate->id == event.id) capture = candidate.get();
        if (!capture) { release(event.id); return; }
        const auto bounds = window_bounds(capture->native, capture->pid);
        if (CGRectIsNull(bounds)) { release(event.id); return; }
        capture->bounds = bounds;
        if (event.kind == vf::InputKind::geometry) { capture->geometry_ack = event.sequence; dirty = true; }
        if (!CGPreflightPostEventAccess()) { std::fprintf(stderr, "window input needs macOS event-post permission\n"); return; }
        switch (event.kind) {
        case vf::InputKind::pointer: {
            if (event.c != 0 && event.c != 1) return;
            pointer = event.c == 1 ? CGPointMake(event.a / options.scale, event.b / options.scale)
                : CGPointMake(bounds.origin.x + event.a * bounds.size.width / std::max(1u, capture->published_width),
                              bounds.origin.y + event.b * bounds.size.height / std::max(1u, capture->published_height));
            auto type = kCGEventMouseMoved; CGMouseButton button = kCGMouseButtonLeft;
            if (!buttons.empty()) {
                button = static_cast<CGMouseButton>(buttons.begin()->first - 272);
                type = button == 0 ? kCGEventLeftMouseDragged : button == 1 ? kCGEventRightMouseDragged : kCGEventOtherMouseDragged;
            }
            post(CGEventCreateMouseEvent(event_source, type, pointer, button)); break;
        }
        case vf::InputKind::button: {
            if (event.a < 272 || event.a > 276 || (event.b != 0 && event.b != 1)) return;
            const auto code = static_cast<unsigned>(event.a);
            if ((event.b != 0) == buttons.contains(code)) return;
            auto& click = clicks[code];
            if (event.b) {
                if (!focus(*capture)) return;
                const double now = NSProcessInfo.processInfo.systemUptime;
                click.second = now - click.first <= NSEvent.doubleClickInterval ? std::min(click.second + 1, 3u) : 1;
                click.first = now;
            }
            if (mouse_button(code, event.b != 0, click.second)) {
                if (event.b) buttons[code] = {event.id, code}; else buttons.erase(code);
            }
            break;
        }
        case vf::InputKind::key: {
            if (event.a < 0 || event.b < 0 || event.b > 2) return;
            const auto code = vm::mac_key(static_cast<unsigned>(event.a)); if (!code) return;
            const auto evdev = static_cast<unsigned>(event.a);
            const bool held = keys.contains(evdev), down = event.b != 0;
            if ((!down && !held) || (event.b == 1 && held) || (event.b == 2 && !held)) return;
            if (down && !held) { if (!focus(*capture)) return; keys[evdev] = {event.id, *code}; }
            if (!down) keys.erase(evdev);
            if (evdev == 58 && down && !held) caps = !caps;
            const auto native = CGEventCreateKeyboardEvent(event_source, static_cast<CGKeyCode>(*code), down);
            if (native) CGEventSetIntegerValueField(native, kCGKeyboardEventAutorepeat, event.b == 2);
            if (!post(native)) {
                if (held) keys[evdev] = {event.id, *code}; else keys.erase(evdev);
                if (evdev == 58 && down && !held) caps = !caps;
            }
            break;
        }
        case vf::InputKind::wheel: {
            if (event.a != 0 && event.a != 1) return;
            const auto pixels = static_cast<int32_t>(std::lround(event.b / 3.0));
            const auto native = CGEventCreateScrollWheelEvent(event_source, kCGScrollEventUnitPixel, 2,
                event.a == 0 ? pixels : 0, event.a == 1 ? -pixels : 0);
            if (native) CGEventSetLocation(native, pointer);
            post(native); break;
        }
        case vf::InputKind::focus: focus(*capture); break;
        case vf::InputKind::geometry:
        case vf::InputKind::close: {
            AXUIElementRef window = ax_window(*capture);
            if (!window) { std::fprintf(stderr, "window %u geometry/close target unavailable\n", capture->native); return; }
            if (event.kind == vf::InputKind::close) {
                CFTypeRef button = nullptr;
                if (AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute, &button) == kAXErrorSuccess && button) {
                    AXUIElementPerformAction(static_cast<AXUIElementRef>(button), kAXPressAction); CFRelease(button);
                }
            } else if (event.c > 0 && event.d > 0 && event.c <= 16384 && event.d <= 16384) {
                CGPoint p{event.a / options.scale, event.b / options.scale};
                CGSize size{event.c / options.scale, event.d / options.scale};
                AXValueRef position = AXValueCreate(kAXValueTypeCGPoint, &p), extent = AXValueCreate(kAXValueTypeCGSize, &size);
                const auto moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute, position);
                const auto resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute, extent);
                CFRelease(position); CFRelease(extent);
                if (moved == kAXErrorSuccess && resized == kAXErrorSuccess) capture->geometry_ack = event.sequence;
                else std::fprintf(stderr, "window %u move/resize unavailable: %d/%d\n", capture->native, moved, resized);
            }
            CFRelease(window); break;
        }
        default: std::fprintf(stderr, "window input kind %u unsupported on macOS\n", static_cast<unsigned>(event.kind)); break;
        }
    }
    SCStreamConfiguration* configuration(unsigned width, unsigned height) {
        auto config = [SCStreamConfiguration new];
        config.width = width; config.height = height;
        config.minimumFrameInterval = CMTimeMake(1, static_cast<int32_t>(options.fps));
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.scalesToFit = YES;
        if (@available(macOS 14.0, *)) {
            config.preservesAspectRatio = NO;
            config.ignoreShadowsSingleWindow = YES;
            config.ignoreGlobalClipSingleWindow = YES;
            config.shouldBeOpaque = NO;
        }
        config.queueDepth = 3;
        config.showsCursor = NO;
        config.capturesAudio = NO;
        config.backgroundColor = CGColorGetConstantColor(kCGColorClear);
        return config;
    }
    void start() {
        if (!CGPreflightScreenCaptureAccess()) throw std::runtime_error("Screen Recording permission required for selected-window capture");
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO
            completionHandler:^(SCShareableContent* content, NSError* error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (quitting) { discovery_done = true; return; }
                    if (error || !content) { failure = error.localizedDescription.UTF8String ?: "window discovery failed"; discovery_done = true; return; }
                    try {
                        std::set<unsigned> requested(options.windows.begin(), options.windows.end());
                        uint64_t id = 0;
                        for (SCWindow* window in content.windows) {
                            if (!requested.erase(window.windowID)) continue;
                            auto capture = std::make_unique<Capture>();
                            capture->owner = this; capture->native = window.windowID;
                            capture->pid = static_cast<unsigned>(window.owningApplication.processID); capture->id = ++id;
                            capture->bounds = window.frame; capture->title = window.title.UTF8String ?: "Shared window";
                            capture->width = static_cast<unsigned>(std::ceil(window.frame.size.width * options.scale / 2)) * 2;
                            capture->height = static_cast<unsigned>(std::ceil(window.frame.size.height * options.scale / 2)) * 2;
                            if (!capture->width || !capture->height || capture->width > 8192 || capture->height > 8192)
                                throw std::runtime_error("selected window exceeds supported capture extent");
                            capture->callback = [VFWindowCapture new]; capture->callback->capture = capture.get();
                            auto filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
                            capture->stream = [[SCStream alloc] initWithFilter:filter configuration:configuration(capture->width, capture->height) delegate:capture->callback];
                            NSError* stream_error = nil;
                            if (![capture->stream addStreamOutput:capture->callback type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&stream_error])
                                throw std::runtime_error(stream_error.localizedDescription.UTF8String ?: "attach capture output");
                            Capture* entry = capture.get(); captures.emplace(capture->native, std::move(capture));
                            entry->starting = true;
                            [entry->stream startCaptureWithCompletionHandler:^(NSError* start_error) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    entry->starting = false;
                                    if (start_error) {
                                        std::fprintf(stderr, "window %u capture start: %s\n", entry->native, start_error.localizedDescription.UTF8String);
                                        entry->stopped = true; entry->retry_after = NSProcessInfo.processInfo.systemUptime + 1;
                                    }
                                    dirty = true;
                                });
                            }];
                        }
                        for (const auto missing : requested) std::fprintf(stderr, "selected window %u is no longer available\n", missing);
                        dirty = true;
                    } catch (const std::exception& e) { failure = e.what(); }
                    discovery_done = true;
                });
            }];
    }
    void recover(Capture* capture) {
        capture->restarting = true;
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO
            completionHandler:^(SCShareableContent* content, NSError* error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    capture->restarting = false;
                    capture->retry_after = NSProcessInfo.processInfo.systemUptime + 1;
                    if (quitting || !capture->active || error || !content) return;
                    SCWindow* selected = nil;
                    for (SCWindow* window in content.windows)
                        if (window.windowID == capture->native && window.owningApplication.processID == static_cast<pid_t>(capture->pid)) selected = window;
                    if (!selected) { release(capture->id); capture->stop(); dirty = true; return; }
                    auto filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:selected];
                    auto next = [[SCStream alloc] initWithFilter:filter configuration:configuration(capture->width, capture->height) delegate:capture->callback];
                    NSError* output_error = nil;
                    if (![next addStreamOutput:capture->callback type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&output_error]) return;
                    capture->stream = next; capture->stopped = false; capture->starting = true;
                    [next startCaptureWithCompletionHandler:^(NSError* start_error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            capture->starting = false;
                            if (capture->stream != next) return;
                            if (start_error) capture->stopped = true;
                            dirty = true;
                        });
                    }];
                });
            }];
    }
    void refresh() {
        for (auto& [_, item] : captures) {
            auto* capture = item.get(); if (!capture->active) continue;
            const auto bounds = window_bounds(capture->native, capture->pid);
            if (CGRectIsNull(bounds)) { release(capture->id); capture->stop(); dirty = true; continue; }
            if (capture->stopped && !capture->restarting && !capture->starting && NSProcessInfo.processInfo.systemUptime >= capture->retry_after) {
                recover(capture); continue;
            }
            if (!CGRectEqualToRect(bounds, capture->bounds)) { capture->bounds = bounds; dirty = true; }
            const auto width = static_cast<unsigned>(std::ceil(bounds.size.width * options.scale / 2)) * 2;
            const auto height = static_cast<unsigned>(std::ceil(bounds.size.height * options.scale / 2)) * 2;
            if (!width || !height || width > 8192 || height > 8192 || capture->updating || capture->stopped || capture->starting ||
                (width == capture->width && height == capture->height)) continue;
            capture->updating = true;
            [capture->stream updateConfiguration:configuration(width, height) completionHandler:^(NSError* error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    capture->updating = false;
                    if (error) { std::fprintf(stderr, "window %u capture resize: %s\n", capture->native, error.localizedDescription.UTF8String); return; }
                    capture->width = width; capture->height = height; dirty = true;
                });
            }];
        }
    }
    void emit() {
        if (!dirty || !output.ready()) return;
        vf::Frame frame; frame.codec = options.codec;
        frame.pts = static_cast<int64_t>(++frame_sequence * 1'000'000 / options.fps);
        unsigned largest = 64; uint64_t area = 0;
        for (const auto& [_, capture] : captures) if (capture->active && capture->latest) {
            largest = std::max(largest, static_cast<unsigned>(CVPixelBufferGetWidth(capture->latest)));
            area += CVPixelBufferGetWidth(capture->latest) * CVPixelBufferGetHeight(capture->latest);
        }
        const unsigned canvas = std::min(8192u, std::max(largest, static_cast<unsigned>(std::ceil(std::sqrt(double(area)) / 2)) * 2));
        unsigned x = 0, y = 0, row = 0;
        CIImage* atlas = [[CIImage imageWithColor:CIColor.clearColor] imageByCroppingToRect:CGRectMake(0, 0, 8192, 8192)];
        // First lay out tiles. Atlas source rectangles use top-left coordinates.
        for (const auto& [_, capture] : captures) if (capture->active && capture->latest) {
            const auto width = static_cast<unsigned>(CVPixelBufferGetWidth(capture->latest));
            const auto height = static_cast<unsigned>(CVPixelBufferGetHeight(capture->latest));
            if (x + width > canvas) { y += row; x = 0; row = 0; }
            if (y + height > 8192 || uint64_t(canvas) * (y + height) > vf::max_pixels) continue;
            frame.tiles.push_back({capture->id, 0,
                static_cast<int32_t>(std::lround(capture->bounds.origin.x * options.scale)),
                static_cast<int32_t>(std::lround(capture->bounds.origin.y * options.scale)),
                width, height, x, y, capture->title.substr(0, 4096), 0, capture->geometry_ack});
            x += width; row = std::max(row, height);
        }
        frame.width = canvas; frame.height = std::max(64u, y + row);
        for (const auto& tile : frame.tiles) {
            Capture* capture = nullptr;
            for (auto& [_, item] : captures) if (item->id == tile.id) capture = item.get();
            CIImage* image = [CIImage imageWithCVPixelBuffer:capture->latest];
            image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(tile.atlas_x, frame.height - tile.atlas_y - tile.height)];
            atlas = [image imageByCompositingOverImage:atlas];
        }
        auto planes = vm::split_planes(context, atlas, frame.width, frame.height, color_space);
        frame.alpha = vf::encode_alpha(planes.alpha);
        frame = encoder.encode(planes.color, std::move(frame));
        if (!output.push(vf::pack_frame(frame))) throw std::runtime_error("window output stopped");
        for (const auto& tile : frame.tiles) for (auto& [_, item] : captures) if (item->id == tile.id) {
            item->published_width = tile.width; item->published_height = tile.height;
        }
        dirty = false;
    }
};
}
@implementation VFWindowCapture
- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (!capture || stream != capture->stream || !capture->active || type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray* attachments = (__bridge NSArray*)CMSampleBufferGetSampleAttachmentsArray(sample, false);
    NSNumber* status = attachments.firstObject[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sample); if (!image) return;
    if (capture->latest) CVPixelBufferRelease(capture->latest);
    capture->latest = CVPixelBufferRetain(image); capture->owner->dirty = true;
}
- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!capture || stream != capture->stream) return;
        std::fprintf(stderr, "window %u capture stopped: %s\n", capture->native, error.localizedDescription.UTF8String);
        capture->stopped = true; capture->retry_after = NSProcessInfo.processInfo.systemUptime + 1;
        capture->owner->release(capture->id); capture->owner->dirty = true;
    });
}
@end
namespace viewflow::macos {
int run_source(const Options& options) {
    [NSApplication sharedApplication];
    Source source(options);
    source.start();
    std::atomic<bool> input_ended{false};
    Input input([&](std::vector<uint8_t> bytes) {
        const auto event = vf::unpack_input(bytes);
        dispatch_sync(dispatch_get_main_queue(), ^{ if (!source.quitting) source.input(event); });
    }, [&] { input_ended = true; });
    double next_frame = 0, next_refresh = 0;
    while (!input_ended && source.output.alive() && source.failure.empty()) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
            const double now = NSProcessInfo.processInfo.systemUptime;
            if (now >= next_refresh) { source.refresh(); next_refresh = now + 0.25; }
            if (now >= next_frame) {
                try { source.emit(); }
                catch (const std::exception& error) { std::fprintf(stderr, "window encode recovering: %s\n", error.what()); }
                next_frame = now + 1.0 / options.fps;
            }
        }
    }
    source.quitting = true; input.stop(); source.release(0);
    for (auto& [_, capture] : source.captures) capture->stop();
    // Complete callbacks while their native owners still exist. No frame age
    // is consulted, and no focus/input event is generated by this shutdown.
    while (!input.finished() || !source.discovery_done || std::any_of(source.captures.begin(), source.captures.end(),
        [](const auto& item) { return !item.second->stopped || item.second->starting || item.second->restarting || item.second->updating; }))
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    if (!source.failure.empty()) throw std::runtime_error(source.failure);
    return 0;
}
}

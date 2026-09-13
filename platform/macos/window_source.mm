#include "window_native.hpp"
#include "window_codec.hpp"
#include "window_io.hpp"
#include "window_keys.hpp"
#include "window_pixels.hpp"
#include "window_popup_material.hpp"
#include "window_frame_schedule.hpp"
#include "window_placement.hpp"
#include "window_parking.hpp"
#include "window_hid.hpp"
#include "window_frame_geometry.hpp"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#include <pthread/qos.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <optional>
#include <set>

#include "window_capture_scope.hpp"
#include "window_worker.hpp"
#include "../reverse-common/window_scope.hpp"
#include "../reverse-common/backdrop.hpp"
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
    uint64_t id{}, geometry_ack{}, parent_id{}, bounds_revision{};
    CGRect bounds{}, body_pixels = CGRectNull;
    CGSize frame_points{};
    vm::WindowPlacement placement;
    std::string title;
    SCStream* __strong stream = nil;
    VFWindowCapture* __strong callback = nil;
    CVPixelBufferRef latest{};
    CIImage* __strong preview = nil;
    unsigned pixel_width() const { return latest ? static_cast<unsigned>(CVPixelBufferGetWidth(latest)) : width; }
    unsigned pixel_height() const { return latest ? static_cast<unsigned>(CVPixelBufferGetHeight(latest)) : height; }
    bool has_pixels() const { return latest || preview; }
    std::unique_ptr<vm::PopupMaterial> material;
    double shape_timestamp{};
    SCWindow* __strong native_window = nil;
    bool bootstrap_pending{}, first_sample_logged{}, first_publish_logged{}, fullscreen{};
    uint64_t backdrop_sequence{};
    NSImage* __strong backdrop_image = nil;
    CGRect backdrop_bounds = CGRectNull;
    unsigned width{}, height{}, published_width{}, published_height{};
    uint64_t samples{}, coalesced{};
    bool metadata_logged{}, alpha_logged{}, dormant{}, suspending{}, transient{};
    bool active{true}, stopping{}, stopped{}, updating{}, restarting{}, starting{}, pending_sample{};
    double retry_after{}, next_title_refresh{}, created_at{};
    ~Capture() { if (callback) callback->capture = nullptr; if (latest) CVPixelBufferRelease(latest); }
    void stop() {
        active = false;
        if (material) material->stop();
        if (suspending) { stopping = true; return; }
        if (stopping || !stream) { if (!stream) stopped = true; return; }
        if (stopped) { stopping = true; return; }
        stopping = true;
        [stream stopCaptureWithCompletionHandler:^(NSError* error) {
            if (error) std::fprintf(stderr, "window %u capture stop: %s\n", native, error.localizedDescription.UTF8String);
            dispatch_async(dispatch_get_main_queue(), ^{ stopped = true; });
        }];
    }
};
// ScreenCaptureKit may provide an additional complete sample for an unchanged
// desktop.  Compare the visible BGRA rows exactly (never a sampled hash) before
// advancing the capture version.  A same-buffer callback is deliberately not
// deduplicated: a producer may update that IOSurface in place.
bool same_pixels(CVPixelBufferRef newer, CVPixelBufferRef older) {
    if (!newer || !older || newer == older || CVPixelBufferGetPixelFormatType(newer) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetPixelFormatType(older) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetWidth(newer) != CVPixelBufferGetWidth(older) || CVPixelBufferGetHeight(newer) != CVPixelBufferGetHeight(older)) return false;
    const auto width = CVPixelBufferGetWidth(newer), height = CVPixelBufferGetHeight(newer);
    if (CVPixelBufferLockBaseAddress(newer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return false;
    if (CVPixelBufferLockBaseAddress(older, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(newer, kCVPixelBufferLock_ReadOnly); return false;
    }
    const auto newer_stride = CVPixelBufferGetBytesPerRow(newer), older_stride = CVPixelBufferGetBytesPerRow(older);
    bool same = newer_stride >= width * 4 && older_stride >= width * 4;
    const auto* newer_bytes = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(newer));
    const auto* older_bytes = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(older));
    for (size_t row = 0; same && row < height; ++row)
        same = std::memcmp(newer_bytes + row * newer_stride, older_bytes + row * older_stride, width * 4) == 0;
    CVPixelBufferUnlockBaseAddress(older, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(newer, kCVPixelBufferLock_ReadOnly);
    return same;
}
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
std::optional<std::string> window_title(unsigned window, unsigned pid) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, window);
    std::optional<std::string> title;
    if (list) {
        for (NSDictionary* item in (__bridge NSArray*)list) {
            if ([item[(__bridge NSString*)kCGWindowNumber] unsignedIntValue] == window &&
                [item[(__bridge NSString*)kCGWindowOwnerPID] unsignedIntValue] == pid) {
                NSString* value = item[(__bridge NSString*)kCGWindowName];
                title.emplace();
                if ([value isKindOfClass:NSString.class] && value.UTF8String) *title = value.UTF8String;
                break;
            }
        }
        CFRelease(list);
    }
    return title;
}
// Public AX APIs don't expose CGWindowID. Match a unique native AX window by
// its current bounds within the already pinned PID; ambiguous matches report
// an operation failure instead of moving or closing a different window.
AXUIElementRef ax_window(unsigned pid, CGRect bounds) {
    AXUIElementRef app = AXUIElementCreateApplication(static_cast<pid_t>(pid));
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
            if (readable && std::abs(p.x - bounds.origin.x) < 2 && std::abs(p.y - bounds.origin.y) < 2 &&
                std::abs(s.width - bounds.size.width) < 2 && std::abs(s.height - bounds.size.height) < 2) {
                if (match) { CFRelease(match); match = nullptr; break; }
                match = static_cast<AXUIElementRef>(CFRetain(window));
            }
        }
    }
    CFRelease(list); return match;
}
AXUIElementRef ax_window(const Capture& capture) { return ax_window(capture.pid, capture.bounds); }
std::optional<bool> window_fullscreen(unsigned pid, CGRect bounds) {
    AXUIElementRef window = ax_window(pid, bounds);
    if (!window) return std::nullopt;
    CFTypeRef value = nullptr;
    const auto error = AXUIElementCopyAttributeValue(window, CFSTR("AXFullScreen"), &value);
    CFRelease(window);
    std::optional<bool> result;
    if (error == kAXErrorSuccess && value && CFGetTypeID(value) == CFBooleanGetTypeID())
        result = CFBooleanGetValue(static_cast<CFBooleanRef>(value));
    if (value) CFRelease(value);
    return result;
}
struct Held { uint64_t window{}; unsigned code{}; };
struct Source {
    vm::WindowHID hid;
    bool hid_available{}, hid_requested{};
    vm::Options options;
    vm::Output output;
    vm::Encoder encoder;
    vm::FrameSchedule frame_schedule;
    vm::ExactAlphaCache alpha_cache;
    dispatch_queue_t capture_queue;
    vm::SerialWorker encode_worker;
    vm::SerialWorker completion_worker;
    unsigned encoder_pending{};
    uint64_t completed_frames{};
    double completion_report_at{};
    uint64_t emit_ticks{}, prepare_busy{}, pipeline_full{}, no_change{}, output_busy{};
    unsigned stable_canvas_width{}, stable_canvas_height{};
    vm::SerialWorker inventory_worker;
    bool inventory_busy{};
    bool encoding{};
    CIContext* __strong context;
    CGColorSpaceRef color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGEventSourceRef event_source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    std::map<unsigned, std::unique_ptr<Capture>> captures;
    NSArray<SCDisplay*>* __strong displays = nil;
    std::map<uint32_t, std::unique_ptr<vm::PopupPreview>> popup_previews;
    vm::DesktopBackdrop desktop_backdrop;
    std::map<pid_t, bool> input_method_cache;
    std::map<unsigned, bool> sharing_control_cache;
    std::map<unsigned, Held> keys, buttons;
    std::map<unsigned, std::pair<double, unsigned>> clicks;
    CGPoint pointer{};
    Capture* input_target{};
    uint64_t sequence{}, frame_sequence{}, next_capture_id{};
    bool menu_discovery_busy{};
    double next_menu_scan{};
    bool dirty{}, discovery_done{}, quitting{}, caps{};
    std::string failure;
    Source(const vm::Options& config) : options(config),
        output(config.performance_mode == vm::PerformanceMode::latency ? 1 : 3),
        encoder(config.fps, config.performance_mode == vm::PerformanceMode::latency) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) throw std::runtime_error("Metal device unavailable");
        capture_queue = dispatch_queue_create("org.viewflow.window-capture",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
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
        if (!input_target) { CFRelease(event); return false; }
        const auto type = CGEventGetType(event);
        if (type == kCGEventKeyDown || type == kCGEventKeyUp || type == kCGEventFlagsChanged) {
            CGEventPostToPid(static_cast<pid_t>(input_target->pid), event);
        } else {
            // Mouse events need WindowServer hit testing and real cursor state.
            // The target's backing rectangle is on an actual (possibly virtual)
            // display; process-only posting does not establish that mouse state.
            CGEventPost(kCGHIDEventTap, event);
        }
        CFRelease(event); return true;
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
        hid.release(window);
        for (auto it = keys.begin(); it != keys.end();) {
            if (window && it->second.window != window) { ++it; continue; }
            const auto held = *it; it = keys.erase(it);
            for (auto& [_, capture] : captures) if (capture->id == held.second.window) input_target = capture.get();
            if (!post(CGEventCreateKeyboardEvent(event_source, static_cast<CGKeyCode>(held.second.code), false))) keys.insert(held);
        }
        for (auto it = buttons.begin(); it != buttons.end();) {
            if (window && it->second.window != window) { ++it; continue; }
            for (auto& [_, capture] : captures) if (capture->id == it->second.window) input_target = capture.get();
            if (mouse_button(it->first, false)) it = buttons.erase(it); else ++it;
        }
    }
    bool focus(Capture& capture) {
        if (capture.parent_id) {
            for (auto& [_, parent] : captures)
                if (parent->id == capture.parent_id) return focus(*parent);
        }
        NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:static_cast<pid_t>(capture.pid)];
        const bool activated = app && (app.active || [app activateWithOptions:0]);
        if (AXUIElementRef window = ax_window(capture)) {
            const auto raised = AXUIElementPerformAction(window, kAXRaiseAction);
            if (raised != kAXErrorSuccess)
                std::fprintf(stderr, "window %u native raise unavailable: %d\n", capture.native, raised);
            CFRelease(window);
        }
        // Raising is best effort; a correctly routed click can select the
        // window itself. Do not discard input just because AXRaise is unsupported.
        return activated;
    }
    void input(const vf::Input& event) {
        if (event.sequence <= sequence) { std::fprintf(stderr, "window input sequence regression\n"); return; }
        sequence = event.sequence;
        if (event.kind == vf::InputKind::release) { release(event.id); return; }
        Capture* capture = nullptr;
        for (auto& [_, candidate] : captures) if (candidate->active && candidate->id == event.id) capture = candidate.get();
        if (!capture || capture->dormant) { release(event.id); return; }
        input_target = capture;
        if (event.kind == vf::InputKind::touchpad_frame && event.a == 0 && event.b == 0 && event.c == 0 && event.d == 2) {
            hid_requested = true; dirty = true; return;
        }
        if (event.kind == vf::InputKind::native_touchpad_chunk || event.kind == vf::InputKind::native_touchpad_commit) {
            hid.input(event, NSProcessInfo.processInfo.systemUptime); return;
        }
        ++capture->bounds_revision;
        const auto bounds = window_bounds(capture->native, capture->pid);
        if (CGRectIsNull(bounds)) { release(event.id); return; }
        capture->bounds = bounds; capture->placement.observe(bounds.origin.x, bounds.origin.y);
        if (event.kind == vf::InputKind::geometry) { capture->geometry_ack = event.sequence; dirty = true; }
        if (!CGPreflightPostEventAccess()) { std::fprintf(stderr, "window input needs macOS event-post permission\n"); return; }
        switch (event.kind) {

        case vf::InputKind::pointer: {
            if (event.c != 0 && event.c != 1) return;
            pointer = event.c == 1 ? CGPointMake(capture->placement.pointer_x(event.a / options.scale),
                capture->placement.pointer_y(event.b / options.scale))
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
                focus(*capture);
                const double now = NSProcessInfo.processInfo.systemUptime;
                click.second = now - click.first <= NSEvent.doubleClickInterval ? std::min(click.second + 1, 3u) : 1;
                click.first = now;
            }
            const bool posted = mouse_button(code, event.b != 0, click.second);
            std::fprintf(stderr, "window-input button window=%u pid=%u button=%u down=%d native=%.1f,%.1f posted=%u\n",
                capture->native, capture->pid, code, event.b, pointer.x, pointer.y, unsigned(posted));
            if (posted) {
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
            if (down && !held) { focus(*capture); keys[evdev] = {event.id, *code}; }
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
                const CGPoint requested{event.a / options.scale, event.b / options.scale};
                CGSize size{event.c / options.scale, event.d / options.scale};
                CGPoint p = vm::backing_position(requested, size);
                AXValueRef position = AXValueCreate(kAXValueTypeCGPoint, &p), extent = AXValueCreate(kAXValueTypeCGSize, &size);
                const auto moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute, position);
                const auto resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute, extent);
                CFRelease(position); CFRelease(extent);
                // AX setters can return before CGWindowList reflects the move.
                // Its later position update is an acknowledgement, not a second drag.
                if (moved == kAXErrorSuccess) capture->placement.expect_backing(p.x, p.y);
                const auto actual = window_bounds(capture->native, capture->pid);
                if (!CGRectIsNull(actual)) {
                    capture->bounds = actual;
                    capture->placement.observe(actual.origin.x, actual.origin.y);
                }
                capture->placement.place(requested.x, requested.y);
                if (moved == kAXErrorSuccess && resized == kAXErrorSuccess) capture->geometry_ack = event.sequence;
                else std::fprintf(stderr, "window %u move/resize unavailable: %d/%d\n", capture->native, moved, resized);
            }
            CFRelease(window); break;
        }
        default: std::fprintf(stderr, "window input kind %u unsupported on macOS\n", static_cast<unsigned>(event.kind)); break;
        }
    }
    SCStreamConfiguration* configuration(unsigned width, unsigned height, bool /*transient*/=false) {
        auto config = [SCStreamConfiguration new];
        // Linux now draws the macOS-style shadow as a Hyprland decoration.
        // Capture only the native window body/title, not a padded shadow atlas.
        config.width = std::min(8192u, width);
        config.height = std::min(8192u, height);
        config.minimumFrameInterval = CMTimeMake(1, static_cast<int32_t>(options.fps));
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.colorSpaceName = kCGColorSpaceSRGB;
        config.scalesToFit = !options.native_decorations;
        if (@available(macOS 14.0, *)) {
            config.preservesAspectRatio = options.native_decorations;
            config.ignoreShadowsSingleWindow = YES;
            config.ignoreGlobalClipSingleWindow = YES;
            // Preserve the window shape for native popup material extraction.
            config.shouldBeOpaque = NO;
        }
        // latest retains one IOSurface until its replacement arrives. A
        // single-buffer pool cannot deliver that replacement; queue size here
        // is capture storage capacity, not a queue of frames to present.
        // Menus/popovers are part of interacting with the selected window.
        // The inventory excludes OS sharing controls by AX identity separately.
        // Native tiles carry their own body geometry. Folding another window
        // into this surface changes its extent/density and duplicates children
        // that are already discovered as separate tiles.
        if (@available(macOS 14.2, *)) config.includeChildWindows = !options.native_decorations;
        config.queueDepth = 3;
        config.showsCursor = NO;
        config.capturesAudio = NO;
        config.backgroundColor = CGColorGetConstantColor(kCGColorClear);
        return config;
    }
    void setup_material(Capture* capture, SCWindow* window) {
        if (!options.native_decorations || !capture->transient || !capture->active || capture->dormant) return;
        SCDisplay* display = nil;
        for (SCDisplay* candidate in displays) if (vm::is_parking_display(candidate.displayID) && CGRectContainsRect(candidate.frame, capture->bounds)) { display = candidate; break; }
        if (!display) return;
        const auto id = capture->id;
        capture->material = std::make_unique<vm::PopupMaterial>(display, window, capture->bounds, static_cast<unsigned>(std::ceil(capture->bounds.size.width * options.scale)), static_cast<unsigned>(std::ceil(capture->bounds.size.height * options.scale)), options.fps, [this, id] {
            if (quitting) return;
            for (auto& [_, item] : captures) if (item->id == id && item->active) { item->preview = nil; ++item->samples; dirty = true; break; }
        });
        if (capture->latest) capture->material->shape(capture->latest, capture->body_pixels, capture->shape_timestamp);
    }
    void ensure_preview(CGRect bounds) {
        if (!options.native_decorations) return;
        for (SCDisplay* display in displays) if (vm::is_parking_display(display.displayID) && CGRectIntersectsRect(display.frame, bounds) && !popup_previews.contains(display.displayID)) {
            popup_previews.emplace(display.displayID, std::make_unique<vm::PopupPreview>(display, static_cast<unsigned>(options.scale), options.fps,
                [this](CIImage* scene, CGRect display_bounds, double timestamp) {
                    if (quitting) return;
                    for (auto& [_, item] : captures) {
                        if (!item->active || item->dormant || !item->transient || !CGRectContainsRect(display_bounds, item->bounds)) continue;
                        if (item->material) item->material->scene(scene, display_bounds, timestamp);
                        if (item->material && item->material->image()) continue;
                        if (timestamp < item->created_at) continue;
                        const double sx=scene.extent.size.width/display_bounds.size.width, sy=scene.extent.size.height/display_bounds.size.height;
                        CGRect crop=CGRectMake((item->bounds.origin.x-display_bounds.origin.x)*sx,
                            scene.extent.size.height-(CGRectGetMaxY(item->bounds)-display_bounds.origin.y)*sy,item->bounds.size.width*sx,item->bounds.size.height*sy);
                        CIImage* image=[scene imageByCroppingToRect:crop];
                        image=[image imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x,-crop.origin.y)];
                        item->preview=[image imageByApplyingTransform:CGAffineTransformMakeScale(item->width/crop.size.width,item->height/crop.size.height)];
                        if (!item->latest) { item->body_pixels=CGRectMake(0,0,item->width,item->height);item->frame_points=item->bounds.size; }
                        ++item->samples; dirty=true;
                        if (!item->first_sample_logged) { item->first_sample_logged=true;std::fprintf(stderr,"menu-first-preview window=%u elapsed-ms=%.2f\n",item->native,(NSProcessInfo.processInfo.systemUptime-item->created_at)*1000); }
                    }
                }));
        }
    }
    Capture* prepare_capture(unsigned native, unsigned pid, CGRect bounds, uint64_t parent, const std::string& title) {
        if (auto found=captures.find(native);found!=captures.end())return found->second.get();
        auto capture=std::make_unique<Capture>();
        capture->owner=this;capture->native=native;capture->pid=pid;capture->id=++next_capture_id;capture->parent_id=parent;
        capture->transient=parent!=0;capture->created_at=NSProcessInfo.processInfo.systemUptime;
        capture->bounds=bounds;capture->placement.observe(bounds.origin.x,bounds.origin.y);capture->title=title;
        capture->width=static_cast<unsigned>(std::ceil(bounds.size.width*options.scale/2))*2;
        capture->height=static_cast<unsigned>(std::ceil(bounds.size.height*options.scale/2))*2;
        if(!capture->width || !capture->height || capture->width>8192 || capture->height>8192)throw std::runtime_error("selected window exceeds supported capture extent");
        auto* result=capture.get();captures.emplace(native,std::move(capture));return result;
    }
    void add_capture(SCWindow* window,uint64_t parent=0) {
    auto* capture=prepare_capture(window.windowID,static_cast<unsigned>(window.owningApplication.processID),window.frame,parent,window.title.UTF8String ?: "Shared window");
    if(capture->stream || !capture->active)return;
    capture->native_window=window;
    if (capture->transient && !capture->first_publish_logged) return;
    capture->callback = [VFWindowCapture new]; capture->callback->capture = capture;
    if (options.native_decorations && vm::remote_window_needed(window.frame) == false) {
        capture->dormant = true; capture->stopped = true;
        std::fprintf(stderr, "window %u capture idle: outside remote region\n", capture->native);
        return;
    }
    ensure_preview(capture->bounds);
    auto filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
    capture->stream = [[SCStream alloc] initWithFilter:filter configuration:configuration(capture->width, capture->height, capture->transient) delegate:capture->callback];
    NSError* stream_error = nil;
    if (![capture->stream addStreamOutput:capture->callback type:SCStreamOutputTypeScreen sampleHandlerQueue:capture_queue error:&stream_error])
        throw std::runtime_error(stream_error.localizedDescription.UTF8String ?: "attach capture output");
    Capture* entry = capture;
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
    void start() {
        if (!CGPreflightScreenCaptureAccess()) throw std::runtime_error("Screen Recording permission required for selected-window capture");
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO
            completionHandler:^(SCShareableContent* content, NSError* error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (quitting) { discovery_done = true; return; }
                    if (error || !content) { failure = error.localizedDescription.UTF8String ?: "window discovery failed"; discovery_done = true; return; }
                    try {
                        displays = content.displays;
                        std::set<unsigned> requested(options.windows.begin(), options.windows.end());
                        for (SCWindow* window in content.windows) {
                            if (!requested.erase(window.windowID)) continue;
                            if (vm::sharing_control_window(window.owningApplication.processID,window.frame)) {
                                std::fprintf(stderr,"window %u ignored: macOS sharing-session control\n",window.windowID);
                                continue;
                            }
                            sharing_control_cache[window.windowID]=false;
                            add_capture(window);
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
                    if (quitting || !capture->active || capture->dormant || error || !content) return;
                    SCWindow* selected = nil;
                    for (SCWindow* window in content.windows)
                        if (window.windowID == capture->native && window.owningApplication.processID == static_cast<pid_t>(capture->pid)) selected = window;
                    if (!selected) { release(capture->id); capture->stop(); dirty = true; return; }
                    displays = content.displays;
                    capture->native_window = selected;
                    auto filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:selected];
                    auto next = [[SCStream alloc] initWithFilter:filter configuration:configuration(capture->width, capture->height, capture->transient) delegate:capture->callback];
                    NSError* output_error = nil;
                    if (![next addStreamOutput:capture->callback type:SCStreamOutputTypeScreen sampleHandlerQueue:capture_queue error:&output_error]) return;
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
    void scan_menus(double now) {
        if(!options.native_decorations || !discovery_done || quitting || now<next_menu_scan)return;
        next_menu_scan=now+1.0/60.0;
        CFArrayRef list=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
        if(!list)return;
        NSArray* windows=CFBridgingRelease(list);
        std::set<unsigned> visible;
        for(NSDictionary* item in windows)visible.insert([item[(__bridge NSString*)kCGWindowNumber] unsignedIntValue]);
        for(auto it=captures.begin();it!=captures.end();) {
            auto* c=it->second.get();
            if(c->parent_id && !visible.contains(c->native) && c->active){release(c->id);c->stop();dirty=true;}
            if(c->parent_id && !c->active && c->stopped && !c->starting && !c->updating && !c->restarting && !c->suspending && !c->bootstrap_pending) {
                if(input_target==c)input_target=nullptr;
                it=captures.erase(it);
            } else ++it;
        }

        std::map<unsigned,uint64_t> requested;

        for(NSDictionary* item in windows) {
            const unsigned native=[item[(__bridge NSString*)kCGWindowNumber] unsignedIntValue];
            const int pid=[item[(__bridge NSString*)kCGWindowOwnerPID] intValue];
            auto known=input_method_cache.find(pid);
            if(known==input_method_cache.end()) {
                NSRunningApplication* app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                NSString* bundle=app.bundleIdentifier ?: @"";
                known=input_method_cache.emplace(pid,[bundle containsString:@".inputmethod."] || [app.bundleURL.path containsString:@"/Input Methods/"]).first;
            }
            const bool input_method=known->second;
            // Modern macOS hosts the visible IME candidate strip under the
            // client app at observed IME-panel level 20; the inputmethod-owned
            // counterpart can be off-screen. Treat this attached panel like
            // a menu and resolve its parent in the same owning process.
            const int layer=[item[(__bridge NSString*)kCGWindowLayer] intValue];
            const bool attached_panel=layer==20;
            if((!input_method && !attached_panel && layer!=CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey)) || (captures.contains(native) && captures.at(native)->native_window))continue;
            const pid_t parent_pid = input_method ? NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier : pid;
            CGRect menu{};if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)item[(__bridge NSString*)kCGWindowBounds],&menu))continue;
            // Match the popup anchor to the frontmost ordinary window of this
            // process. Nested menus outside it use the nearest body rectangle.
            std::vector<vf::MenuParent> parents;
            for(NSDictionary* candidate in windows) {
                if([candidate[(__bridge NSString*)kCGWindowOwnerPID] intValue]!=parent_pid || [candidate[(__bridge NSString*)kCGWindowLayer] intValue]!=0)continue;
                CGRect rect{};if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)candidate[(__bridge NSString*)kCGWindowBounds],&rect))continue;
                const unsigned parent_native_id=[candidate[(__bridge NSString*)kCGWindowNumber] unsignedIntValue];
                auto control=sharing_control_cache.find(parent_native_id);
                if(control==sharing_control_cache.end())control=sharing_control_cache.emplace(parent_native_id,vm::sharing_control_window(parent_pid,rect)).first;
                if(control->second)continue;
                parents.push_back({[candidate[(__bridge NSString*)kCGWindowNumber] unsignedIntValue],{rect.origin.x,rect.origin.y,rect.size.width,rect.size.height}});
            }
            const unsigned parent_native=vf::menu_parent(menu.origin.x,menu.origin.y,parents);
            const auto parent=captures.find(parent_native);
            if(parent==captures.end() || !parent->second->active || parent->second->dormant || parent->second->transient)continue;
            if(!captures.contains(native)) {
                NSString* title=item[(__bridge NSString*)kCGWindowName];
                prepare_capture(native,static_cast<unsigned>(pid),menu,parent->second->id,title.UTF8String ?: "Shared popup");
                dirty=true;
            }
            requested.emplace(native,parent->second->id);
            if(requested.size()>=8)break;
        }
        if(requested.empty() || menu_discovery_busy)return;
        menu_discovery_busy=true;
        const double detected=NSProcessInfo.processInfo.systemUptime;
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:^(SCShareableContent* content,NSError* error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                menu_discovery_busy=false;
                if(quitting || error || !content)return;
                displays = content.displays;
                for(SCWindow* window in content.windows) {
                    const auto found=requested.find(window.windowID);
                    if(found==requested.end() || (captures.contains(window.windowID) && captures.at(window.windowID)->native_window))continue;
                    try {
                        add_capture(window,found->second);
                        std::fprintf(stderr,"menu joined parent stream window=%u discovery_ms=%.1f\n",window.windowID,(NSProcessInfo.processInfo.systemUptime-detected)*1000);
                    } catch(const std::exception& error) {std::fprintf(stderr,"menu capture retry: %s\n",error.what());}
                }
                dirty=true;
            });
        }];
    }
    void refresh() {
        const auto now = NSProcessInfo.processInfo.systemUptime;
        hid.drain(now);
        const bool needs_display=std::any_of(captures.begin(),captures.end(),[](const auto& entry){
            const auto& c=entry.second;return c->active && !c->dormant && vm::remote_window_needed(c->bounds).value_or(false);
        });
        if(!needs_display){popup_previews.clear();desktop_backdrop.clear();}
        for(auto& [_, preview]:popup_previews)preview->recover(now);
        scan_menus(now);
        const bool available = hid_requested && hid.available(now);
        if (available != hid_available) { hid_available = available; dirty = true;
            std::fprintf(stderr, "window HID capability=%u\n", unsigned(available)); }
        if (inventory_busy || quitting) return;
        std::vector<Observation> observations;
        for (auto& [_, item] : captures) {
            if (!item->active) continue;
            observations.push_back({item->native, item->pid, item->id, item->bounds_revision,
                now >= item->next_title_refresh, CGRectNull, std::nullopt, std::nullopt, std::nullopt, item->transient});
        }
        if (observations.empty()) return;
        inventory_busy = true;
        if (!inventory_worker.submit([this, observations = std::move(observations)]() mutable {
            @autoreleasepool {
                for (auto& observation : observations) {
                    observation.bounds = window_bounds(observation.native, observation.pid);
                    if (options.native_decorations && !CGRectIsNull(observation.bounds))
                        observation.needed = vm::remote_window_needed(observation.bounds);
                    if (observation.read_title) {
                        observation.title = window_title(observation.native, observation.pid);
                        if (!observation.transient && !CGRectIsNull(observation.bounds))
                            observation.fullscreen = window_fullscreen(observation.pid, observation.bounds);
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!quitting) apply_inventory(observations);
                    inventory_busy = false;
                });
            }
        })) inventory_busy = false;
    }
    struct Observation {
        unsigned native, pid;
        uint64_t id, revision;
        bool read_title;
        CGRect bounds;
        std::optional<std::string> title;
        std::optional<bool> needed, fullscreen;
        bool transient;
    };
    void apply_inventory(const std::vector<Observation>& observations) {
        const auto now = NSProcessInfo.processInfo.systemUptime;
        for (const auto& observation : observations) {
            const auto found = std::find_if(captures.begin(), captures.end(), [&](const auto& item) {
                return item.second->id == observation.id;
            });
            if (found == captures.end()) continue;
            auto* capture = found->second.get();
            // Input may have moved or queried this window while WindowServer
            // answered the background request. Never roll that newer state back.
            if (!capture->active || capture->bounds_revision != observation.revision) continue;
            if (observation.fullscreen && capture->fullscreen != *observation.fullscreen) {
                capture->fullscreen = *observation.fullscreen; dirty = true;
                std::fprintf(stderr, "window %u source fullscreen=%u\n", capture->native, unsigned(capture->fullscreen));
            }
            const auto bounds = observation.bounds;
            if (CGRectIsNull(bounds)) { release(capture->id); capture->stop(); dirty = true; continue; }
            if (!CGRectEqualToRect(bounds, capture->bounds)) { capture->bounds = bounds; capture->placement.observe(bounds.origin.x, bounds.origin.y); dirty = true; }
            if (options.native_decorations) {
                const auto needed = observation.needed;
                if (needed && !*needed) {
                    if (!capture->dormant) {
                        capture->dormant = true; release(capture->id); dirty = true;
                        if (capture->material) { capture->material->stop(); capture->material.reset(); }
                        if (capture->latest) { CVPixelBufferRelease(capture->latest); capture->latest = nullptr; }
                        std::fprintf(stderr, "window %u capture idle: returned to Mac\n", capture->native);
                    }
                    if (capture->stream && !capture->stopped && !capture->starting && !capture->suspending) {
                        capture->suspending = true;
                        [capture->stream stopCaptureWithCompletionHandler:^(NSError* error) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                capture->suspending = false;
                                if (!error || capture->stopping) capture->stopped = true;
                                else std::fprintf(stderr, "window %u capture suspend retry: %s\n", capture->native, error.localizedDescription.UTF8String);
                            });
                        }];
                    }
                    continue;
                }
                if (needed && *needed && capture->dormant) {
                    capture->dormant = false; dirty = true; ensure_preview(bounds);
                    std::fprintf(stderr, "window %u capture resumed: entered remote region\n", capture->native);
                }
            }
            if (capture->dormant || capture->suspending) { if (capture->material) { capture->material->stop(); capture->material.reset(); } continue; }
            if (capture->transient && !capture->stream) {
                // A preview may be published while the opening animation is
                // still tiny. Size the independent stream from current CG
                // bounds; never send updateConfiguration to a nil stream.
                capture->width = static_cast<unsigned>(std::ceil(bounds.size.width * options.scale / 2)) * 2;
                capture->height = static_cast<unsigned>(std::ceil(bounds.size.height * options.scale / 2)) * 2;
                if (capture->first_publish_logged && capture->native_window) add_capture(capture->native_window, capture->parent_id);
            }
            // Publish the first ordinary window frame before doing auxiliary
            // material setup. Short-lived IME windows need no extra streams.
            if (!capture->material && capture->transient && capture->first_publish_logged && !capture->starting && capture->native_window) setup_material(capture, capture->native_window);
            if (capture->material) capture->material->recover(now);
            if (capture->material && !CGRectEqualToRect(capture->material->bounds(), bounds) && !capture->restarting && !capture->starting && !capture->updating) {
                capture->material->stop(); capture->material.reset();
                // CG geometry tracks popup animations sooner than SCWindow.
                // Rebuild only the region streams using those current bounds.
                setup_material(capture, capture->native_window);
            }
            if (capture->stopped && !capture->restarting && !capture->starting && now >= capture->retry_after) {
                capture->width = static_cast<unsigned>(std::ceil(bounds.size.width * options.scale / 2)) * 2;
                capture->height = static_cast<unsigned>(std::ceil(bounds.size.height * options.scale / 2)) * 2;
                recover(capture); continue;
            }
            if (observation.read_title) {
                capture->next_title_refresh = now + 1.;
                if (const auto& title = observation.title; title && *title != capture->title) {
                    capture->title = title->substr(0, 4096); dirty = true;
                }
            }
            const auto width = static_cast<unsigned>(std::ceil(bounds.size.width * options.scale / 2)) * 2;
            const auto height = static_cast<unsigned>(std::ceil(bounds.size.height * options.scale / 2)) * 2;
            if (!capture->stream || !width || !height || width > 8192 || height > 8192 || capture->updating || capture->stopped || capture->starting ||
                (width == capture->width && height == capture->height)) continue;
            capture->updating = true;
            [capture->stream updateConfiguration:configuration(width, height, capture->transient) completionHandler:^(NSError* error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    capture->updating = false;
                    if (error) { std::fprintf(stderr, "window %u capture resize: %s\n", capture->native, error.localizedDescription.UTF8String); return; }
                    capture->width = width; capture->height = height; dirty = true;
                });
            }];
        }
    }
    void emit() {
        const auto now = NSProcessInfo.processInfo.systemUptime;
        ++emit_ticks;
        if (encoding) { ++prepare_busy; return; }
        if (encoder_pending >= 2) { ++pipeline_full; return; }
        if (!dirty && !frame_schedule.refresh_due(now)) { ++no_change; return; }
        if (!output.ready()) { ++output_busy; return; }
        vf::Frame frame; frame.codec = options.codec;
        frame.pts = static_cast<int64_t>(++frame_sequence * 1'000'000 / options.fps);
        // NVDEC HEVC has a 144-pixel minimum decoded extent. Pad bootstrap
        // frames and small popup atlases; tile/body geometry stays independent.
        const unsigned minimum_extent = options.codec == 2 ? 144u : 64u;
        unsigned largest = minimum_extent; uint64_t area = 0;
        for (const auto& [_, capture] : captures) if (capture->active && capture->has_pixels()) {
            largest = std::max(largest, capture->pixel_width());
            area += uint64_t(capture->pixel_width()) * capture->pixel_height();
        }
        unsigned canvas = std::min(8192u, std::max(largest, static_cast<unsigned>(std::ceil(std::sqrt(double(area)) / 2)) * 2));
        if (options.native_decorations) { stable_canvas_width = std::max(stable_canvas_width, canvas); canvas = stable_canvas_width; }
        unsigned x = 0, y = 0, row = 0;
        vm::FrameSchedule::Versions versions;
        // First lay out tiles. Atlas source rectangles use top-left coordinates.
        for (const auto& [_, capture] : captures) if (capture->active && capture->has_pixels()) {
            const auto width = capture->pixel_width();
            const auto height = capture->pixel_height();
            if (x + width > canvas) { y += row; x = 0; row = 0; }
            if (y + height > 8192 || uint64_t(canvas) * (y + height) > vf::max_pixels) continue;
            frame.tiles.push_back({capture->id, capture->parent_id,
                static_cast<int32_t>(std::lround(capture->placement.x * options.scale)),
                static_cast<int32_t>(std::lround(capture->placement.y * options.scale)),
                width, height, x, y, capture->title.substr(0, 4096), (capture->fullscreen ? vf::fullscreen_flag : 0u) | (hid_available ? 8u : 0u) | (capture->transient ? 2u : 0u) | (options.native_decorations && !capture->transient ? vf::backdrop_capability : 0u) | (options.native_decorations ? 16u : 0u), capture->geometry_ack});
            if (options.native_decorations) {
                auto& tile = frame.tiles.back();
                tile.body_x = std::lround(capture->body_pixels.origin.x);
                tile.body_y = std::lround(capture->body_pixels.origin.y);
                tile.body_width = std::lround(capture->body_pixels.size.width);
                tile.body_height = std::lround(capture->body_pixels.size.height);
                tile.logical_width = std::max(1l, std::lround(capture->frame_points.width));
                tile.logical_height = std::max(1l, std::lround(capture->frame_points.height));
                tile.pixel_scale = static_cast<unsigned>(options.scale);
            }
            versions.emplace(capture->id, capture->samples);
            x += width; row = std::max(row, height);
        }
        frame.width = canvas; frame.height = std::max(minimum_extent, y + row);
        if (options.native_decorations) {
            // Reserve a popup strip before the first menu, and never shrink on
            // close. Otherwise every IME opening recreates VT and NVDEC.
            if (!stable_canvas_height && std::any_of(frame.tiles.begin(), frame.tiles.end(), [](const auto& tile) { return !(tile.flags & 2); })) stable_canvas_height = std::min(8192u, frame.height + 512u);
            if (stable_canvas_height) {
                stable_canvas_height = std::max(stable_canvas_height, frame.height);
                if (uint64_t(canvas) * stable_canvas_height <= vf::max_pixels) frame.height = stable_canvas_height;
            }
        }
        if (!frame_schedule.needs_frame(frame.tiles, versions, frame.width, frame.height, now)) {
            dirty = false;
            return;
        }
        CIImage* atlas = nil;
        std::shared_ptr<__CVBuffer> direct_pixels;
        if (frame.tiles.size() == 1 && frame.tiles.front().atlas_x == 0 && frame.tiles.front().atlas_y == 0 &&
            frame.tiles.front().width == frame.width && frame.tiles.front().height == frame.height) {
            for (auto& [_, item] : captures) if (item->id == frame.tiles.front().id) {
                atlas = item->material ? item->material->image() : nil;
                if (!atlas) atlas=item->preview;
                if (atlas) break;
                atlas = [CIImage imageWithCVPixelBuffer:item->latest];
                direct_pixels = std::shared_ptr<__CVBuffer>(CVPixelBufferRetain(item->latest),
                    [](CVPixelBufferRef pixels) { CVPixelBufferRelease(pixels); });
                break;
            }
        }
        if (!atlas) atlas = [[CIImage imageWithColor:CIColor.clearColor] imageByCroppingToRect:CGRectMake(0, 0, 8192, 8192)];
        for (const auto& tile : frame.tiles) {
            if (frame.tiles.size() == 1 && atlas.extent.size.width == frame.width && atlas.extent.size.height == frame.height) continue;
            Capture* capture = nullptr;
            for (auto& [_, item] : captures) if (item->id == tile.id) capture = item.get();
            CIImage* image = capture->material ? capture->material->image() : nil;
            if (!image) image = capture->preview;
            if (!image) image = [CIImage imageWithCVPixelBuffer:capture->latest];
            image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(tile.atlas_x, frame.height - tile.atlas_y - tile.height)];
            atlas = [image imageByCompositingOverImage:atlas];
        }
        // Snapshot owns the CI graph (and its captured pixel buffers) until the
        // serial preparation completes. At most two frames are in flight;
        // captures continue replacing latest while ordered completion runs.
        auto job = std::make_shared<vf::Frame>(frame);
        encoding = true;
        ++encoder_pending;
        const bool accepted = encode_worker.submit([this, job, atlas, direct_pixels, versions] {
            @autoreleasepool {
                const auto start = NSProcessInfo.processInfo.systemUptime;
                try {
                    auto planes = vm::split_planes(context, atlas, job->width, job->height, color_space, direct_pixels.get(), true);
                    const auto split = NSProcessInfo.processInfo.systemUptime;
                    job->alpha = alpha_cache.encode(planes.alpha, job->width, job->height);
                    const auto alpha = NSProcessInfo.processInfo.systemUptime;
                    auto ticket = encoder.submit(planes.color, std::move(*job));
                    auto complete = [this, job, versions, ticket, start, split, alpha] {
                        @autoreleasepool {
                            bool succeeded = false;
                            try {
                                *job = vm::Encoder::finish(ticket);
                                const auto encoded_at = NSProcessInfo.processInfo.systemUptime;
                                // Preserve inter-frame references during backpressure.
                                // This bounded worker waits; capture keeps only latest.
                                succeeded = output.push(vf::pack_frame(*job), true);
                                if (job->pts % 4'000'000 < 1'000'000 / options.fps)
                                    std::fprintf(stderr, "macos-source-worker split-ms=%.3f alpha-ms=%.3f encode-ms=%.3f pack-ms=%.3f color-bytes=%zu alpha-bytes=%zu\n",
                                        (split-start)*1000, (alpha-split)*1000, (encoded_at-alpha)*1000,
                                        (NSProcessInfo.processInfo.systemUptime-encoded_at)*1000, job->color.size(), job->alpha.size());
                            } catch (const std::exception& error) {
                                std::fprintf(stderr, "window encode completion recovering: %s\n", error.what());
                            }
                            dispatch_async(dispatch_get_main_queue(), ^{ completed(job, versions, succeeded); });
                        }
                    };
                    if (!completion_worker.submit_wait(complete)) throw std::runtime_error("completion worker stopped");
                } catch (const std::exception& error) {
                    std::fprintf(stderr, "window encode recovering: %s\n", error.what());
                    dispatch_async(dispatch_get_main_queue(), ^{ completed(job, versions, false); });
                }
                dispatch_async(dispatch_get_main_queue(), ^{ encoding = false; });
            }
        });
        if (!accepted) { encoding = false; --encoder_pending; return; }
        dirty = false;
        if (frame_sequence == 1 || frame_sequence % 120 == 0) {
            uint64_t samples = 0, coalesced = 0;
            for (const auto& [_, item] : captures) { samples += item->samples; coalesced += item->coalesced; }
            std::fprintf(stderr, "macos-window-source-stats frames=%llu samples=%llu coalesced=%llu windows=%zu\n",
                static_cast<unsigned long long>(frame_sequence), static_cast<unsigned long long>(samples),
                static_cast<unsigned long long>(coalesced), frame.tiles.size());
        }
    }
    void completed(const std::shared_ptr<vf::Frame>& job, const vm::FrameSchedule::Versions& versions, bool succeeded) {
        --encoder_pending;
        if (!succeeded) { dirty = true; return; }
        const double now = NSProcessInfo.processInfo.systemUptime;
        if (completion_report_at == 0) completion_report_at = now;
        ++completed_frames;
        if (now - completion_report_at >= 2.) {
            std::fprintf(stderr, "macos-source-throughput width=%u height=%u target-fps=%u completed-fps=%.2f in-flight=%u\n",
                job->width, job->height, options.fps, completed_frames / (now - completion_report_at), encoder_pending);
            std::fprintf(stderr, "macos-source-cadence ticks=%llu prepare-busy=%llu pipeline-full=%llu unchanged=%llu output-busy=%llu interval-ms=%.1f\n",
                (unsigned long long)emit_ticks, (unsigned long long)prepare_busy, (unsigned long long)pipeline_full,
                (unsigned long long)no_change, (unsigned long long)output_busy, (now - completion_report_at) * 1000);
            emit_ticks = prepare_busy = pipeline_full = no_change = output_busy = 0;
            completion_report_at = now; completed_frames = 0;
        }
        frame_schedule.submitted(job->tiles, versions, job->width, job->height, NSProcessInfo.processInfo.systemUptime);
        for (const auto& tile : job->tiles) for (auto& [_, item] : captures) if (item->id == tile.id) {
            item->published_width = tile.width; item->published_height = tile.height;
            if (item->transient && !item->first_publish_logged) {
                item->first_publish_logged = true;
                std::fprintf(stderr, "menu-first-published window=%u elapsed-ms=%.2f atlas=%ux%u\n", item->native, (now-item->created_at)*1000, job->width, job->height);
            }
            const auto version = versions.find(item->id);
            if (version != versions.end() && version->second == item->samples) item->pending_sample = false;
        }
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
    if (!capture->metadata_logged && capture->owner->options.native_decorations) {
        capture->metadata_logged = true;
        std::fprintf(stderr, "native-decoration sample pixels=%zux%zu metadata=%s\n",
            CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image), attachments.description.UTF8String);
    }
    CGRect body = CGRectNull;
    CGSize points{};
    if (capture->owner->options.native_decorations) {
        if (@available(macOS 14.0, *)) {
            NSDictionary* geometry = attachments.firstObject[SCStreamFrameInfoBoundingRect];
            NSDictionary* screen = attachments.firstObject[SCStreamFrameInfoScreenRect];
            NSNumber* factor = attachments.firstObject[SCStreamFrameInfoScaleFactor];
            NSNumber* content_scale = attachments.firstObject[SCStreamFrameInfoContentScale];
            CGRect rect{}, native{};
            if (geometry && screen && factor.doubleValue > 0 && content_scale.doubleValue > 0 &&
                CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)geometry, &rect) &&
                CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)screen, &native)) {
                const double scale = factor.doubleValue;
                const CGRect outer = CGRectMake(std::round(rect.origin.x * scale), std::round(rect.origin.y * scale),
                                                std::round(rect.size.width * scale), std::round(rect.size.height * scale));
                const CGRect surface = CGRectMake(0, 0, CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image));
                const double density = scale * content_scale.doubleValue;
                points = native.size;
                if (!CGRectIsEmpty(outer) && CGRectContainsRect(surface, outer) &&
                    CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
                    const auto found = vm::window_body(static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(image)),
                        CVPixelBufferGetBytesPerRow(image),
                        {unsigned(outer.origin.x), unsigned(outer.origin.y), unsigned(outer.size.width), unsigned(outer.size.height)},
                        std::lround(native.size.width * density), std::lround(native.size.height * density));
                    if(capture->transient && !capture->alpha_logged && found.width && found.height) {
                        capture->alpha_logged=true;uint64_t translucent=0,opaque=0,clear=0;
                        const auto* pixels=static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(image));
                        for(unsigned y=found.y;y<found.y+found.height;++y)for(unsigned x=found.x;x<found.x+found.width;++x) {
                            const unsigned alpha=pixels[y*CVPixelBufferGetBytesPerRow(image)+x*4+3];
                            if(alpha==255)++opaque;else if(alpha==0)++clear;else ++translucent;
                        }
                        std::fprintf(stderr,"menu alpha window=%u body_opaque=%llu body_translucent=%llu body_clear=%llu\n",capture->native,(unsigned long long)opaque,(unsigned long long)translucent,(unsigned long long)clear);
                    }
                    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
                    if (found.width && found.height) body = CGRectMake(found.x, found.y, found.width, found.height);
                }
            }
        }
        // Keep the previous valid frame during a capture reconfiguration. Never
        // reinterpret an unknown shadow extent as the actual window rectangle.
        if (CGRectIsNull(body) || CGRectIsEmpty(body)) return;
    }
    // Retain a main-owned snapshot briefly, then do the exact full-image
    // comparison on ScreenCaptureKit's serial worker. The main thread never
    // waits for that worker and can continue delivering ordered input.
    __block CVPixelBufferRef previous = nullptr;
    VFWindowCapture* callback = self;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (callback->capture && stream == callback->capture->stream && callback->capture->latest)
            previous = CVPixelBufferRetain(callback->capture->latest);
    });
    const bool unchanged = same_pixels(image, previous);
    if (previous) CVPixelBufferRelease(previous);
    const double shape_timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
    CVPixelBufferRetain(image);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (callback->capture && stream == callback->capture->stream && callback->capture->active && !callback->capture->dormant) {
            const bool geometry_changed = !CGRectEqualToRect(body, callback->capture->body_pixels);
            if (callback->capture->transient && !callback->capture->first_sample_logged) {
                callback->capture->first_sample_logged = true;
                std::fprintf(stderr, "menu-first-sample window=%u elapsed-ms=%.2f\n", callback->capture->native, (NSProcessInfo.processInfo.systemUptime-callback->capture->created_at)*1000);
            }
            callback->capture->body_pixels = body;
            callback->capture->frame_points = points;
            if (!unchanged || geometry_changed) callback->capture->shape_timestamp = shape_timestamp;
            if (callback->capture->material) callback->capture->material->shape(image, body, callback->capture->shape_timestamp);
            if (!geometry_changed && unchanged) {
                ++callback->capture->coalesced;
            } else {
                ++callback->capture->samples;
                if (callback->capture->pending_sample) ++callback->capture->coalesced;
                if (callback->capture->latest) CVPixelBufferRelease(callback->capture->latest);
                callback->capture->latest = CVPixelBufferRetain(image);
                callback->capture->pending_sample = true;
                callback->capture->owner->dirty = true;
            }
        }
        CVPixelBufferRelease(image);
    });
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
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    [NSApplication sharedApplication];
    std::fprintf(stderr, "macos-window-source performance-mode=%s capture-queue-depth=%u qos=user-interactive\n",
        options.performance_mode == PerformanceMode::latency ? "latency" : "frame-rate",
        3u);
    Source source(options);
    source.start();
    std::atomic<bool> input_ended{false};
    Input input([&](std::vector<uint8_t> bytes) {
        vf::Reader tag{bytes};
        if (tag.u32() == 3) {
            const auto background = vf::unpack_backdrop(bytes);
            @autoreleasepool {
                NSData* data = [NSData dataWithBytes:background.png.data() length:background.png.size()];
                NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithData:data];
                if (!rep || rep.pixelsWide != background.pixel_width || rep.pixelsHigh != background.pixel_height) { std::fprintf(stderr,"popup-backdrop PNG decode mismatch id=%llu\n",(unsigned long long)background.id); return; }
                NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(rep.pixelsWide, rep.pixelsHigh)];
                [image addRepresentation:rep];
                dispatch_sync(dispatch_get_main_queue(), ^{
                    if (source.quitting) return;
                    for (auto& [_, capture] : source.captures) if (capture->id == background.id && capture->active && !capture->transient && !capture->dormant && background.sequence > capture->backdrop_sequence) {
                        capture->backdrop_sequence = background.sequence;
                        capture->backdrop_image=image;
                        capture->backdrop_bounds=CGRectMake(background.x / 1000., background.y / 1000., background.width / 1000., background.height / 1000.);
                        source.desktop_backdrop.update(image,capture->backdrop_bounds);
                        if(background.sequence==1)std::fprintf(stderr,"popup-backdrop received id=%llu native=%u png=%zu\n",(unsigned long long)background.id,capture->native,background.png.size());
                        break;
                    }
                });
            }
            return;
        }
        const auto event = vf::unpack_input(bytes);
        dispatch_sync(dispatch_get_main_queue(), ^{ if (!source.quitting) source.input(event); });
    }, [&] { input_ended = true; });
    vm::FrameCadence cadence;
    double next_refresh = 0;
    while (transport_owner_alive() && !input_ended && source.output.alive() && source.failure.empty()) {
        @autoreleasepool {
            const double before_wait = NSProcessInfo.processInfo.systemUptime;
            const double wait = cadence.wait(before_wait);
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:wait]];
            const double now = NSProcessInfo.processInfo.systemUptime;
            if (now >= next_refresh) { source.refresh(); next_refresh = now + 1.0/60.0; }
            if (cadence.due(now)) {
                try { source.emit(); }
                catch (const std::exception& error) { std::fprintf(stderr, "window encode recovering: %s\n", error.what()); }
                // Preserve cadence instead of accumulating run-loop lateness.
                // Missed slots are skipped; they never create a catch-up queue.
                cadence.advance(now, options.fps);
            }
        }
    }
    source.quitting = true; source.popup_previews.clear(); source.desktop_backdrop.clear(); input.stop(); source.output.stop(); source.release(0);
    for (auto& [_, capture] : source.captures) capture->stop();
    // Complete callbacks while their native owners still exist. No frame age
    // is consulted, and no focus/input event is generated by this shutdown.
    while (source.encoding || source.encoder_pending || source.inventory_busy || !input.finished() || !source.discovery_done || source.menu_discovery_busy || std::any_of(source.captures.begin(), source.captures.end(),
        [](const auto& item) { return !item.second->stopped || item.second->starting || item.second->restarting || item.second->updating || item.second->bootstrap_pending; }))
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    // Service any final callback snapshot/handoff before destroying Source.
    __block bool captures_drained = false;
    dispatch_async(source.capture_queue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{ captures_drained = true; });
    });
    while (!captures_drained)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    if (!source.failure.empty()) throw std::runtime_error(source.failure);
    return 0;
}
}

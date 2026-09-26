#include "../reverse-common/activity_input.hpp"
#include "../reverse-common/activity_feedback.hpp"
#include "../reverse-common/activity_hint.hpp"
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
#include "../reverse-common/window_residency.hpp"
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
    std::string app_id;std::vector<uint8_t> icon_png;bool icon_sent{};
    Source* owner{};
    AXUIElementRef ax_target{};
    double ax_diagnostic_after{};
    unsigned native{}, pid{};
    uint64_t id{}, geometry_ack{}, parent_id{}, bounds_revision{};
    CGRect bounds{}, body_pixels = CGRectNull;
    CGSize frame_points{};
    vm::WindowPlacement placement;
    vm::PendingGeometry geometry_request;
    double geometry_retry_after{};
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
    std::optional<vf::PixelRect> residency;
    unsigned residency_width{}, residency_height{};
    vf::PixelRect resident() const {
        if(residency && residency_width==pixel_width() && residency_height==pixel_height())return *residency;
        return {0,0,pixel_width(),pixel_height()};
    }
    bool native_drag{}, native_drag_bootstrap{}, native_drag_last_left{};
    CGPoint native_drag_grab{};
    bool metadata_logged{}, alpha_logged{}, dormant{}, suspending{}, transient{};
    bool active{true}, stopping{}, stopped{}, updating{}, restarting{}, starting{}, pending_sample{};
    double retry_after{}, next_title_refresh{}, created_at{};
    ~Capture() { if (ax_target) CFRelease(ax_target); if (callback) callback->capture = nullptr; if (latest) CVPixelBufferRelease(latest); }
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
AXUIElementRef ax_window(unsigned pid, CGRect bounds, bool diagnostic = false) {
    AXUIElementRef app = AXUIElementCreateApplication(static_cast<pid_t>(pid));
    CFTypeRef list = nullptr;
    const auto status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &list);
    CFRelease(app);
    if (status != kAXErrorSuccess || !list) {
        if (diagnostic) std::fprintf(stderr, "window-ax-lookup pid=%u list-status=%d trusted=%d\n", pid, status, AXIsProcessTrusted());
        return nullptr;
    }
    AXUIElementRef match = nullptr;
    if (CFGetTypeID(list) == CFArrayGetTypeID()) {
        const auto array = static_cast<CFArrayRef>(list);
        for (CFIndex i = 0; i < CFArrayGetCount(array); ++i) {
            const auto window = static_cast<AXUIElementRef>(const_cast<void*>(CFArrayGetValueAtIndex(array, i)));
            CFTypeRef position = nullptr, size = nullptr;
            const auto position_status = AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &position);
            const auto size_status = AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &size);
            CGPoint p{}; CGSize s{};
            const bool readable = position && size && CFGetTypeID(position) == AXValueGetTypeID() && CFGetTypeID(size) == AXValueGetTypeID() &&
                AXValueGetValue(static_cast<AXValueRef>(position), kAXValueTypeCGPoint, &p) &&
                AXValueGetValue(static_cast<AXValueRef>(size), kAXValueTypeCGSize, &s);
            if (position) CFRelease(position); if (size) CFRelease(size);
            if (diagnostic) std::fprintf(stderr, "window-ax-candidate pid=%u index=%ld position-status=%d size-status=%d rect=%.1f,%.1f,%.1f,%.1f expected=%.1f,%.1f,%.1f,%.1f\n",
                pid, long(i), position_status, size_status, p.x, p.y, s.width, s.height,
                bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);
            if (readable && std::abs(p.x - bounds.origin.x) < 2 && std::abs(p.y - bounds.origin.y) < 2 &&
                std::abs(s.width - bounds.size.width) < 2 && std::abs(s.height - bounds.size.height) < 2) {
                if (match) { CFRelease(match); match = nullptr; break; }
                match = static_cast<AXUIElementRef>(CFRetain(window));
            }
        }
    }
    CFRelease(list); return match;
}
AXUIElementRef ax_window(Capture& capture) {
    // AX references identify a native object across its moves. Re-matching
    // every command by an asynchronous capture rectangle loses the target as
    // soon as an earlier AX move lands before the next capture observation.
    if (capture.ax_target) {
        CFTypeRef position = nullptr;
        const auto status = AXUIElementCopyAttributeValue(capture.ax_target, kAXPositionAttribute, &position);
        if (position) CFRelease(position);
        // Busy apps may temporarily return CannotComplete. Their object
        // identity remains valid; only InvalidUIElement requires rebinding.
        if (status != kAXErrorInvalidUIElement) return static_cast<AXUIElementRef>(CFRetain(capture.ax_target));
        CFRelease(capture.ax_target); capture.ax_target = nullptr;
    }
    const auto fresh = window_bounds(capture.native, capture.pid);
    if (!CGRectIsNull(fresh)) capture.ax_target = ax_window(capture.pid, fresh);
    if (capture.ax_target) {
        std::fprintf(stderr, "window-ax-bound window=%u pid=%u cg=%.1f,%.1f,%.1f,%.1f capture=%.1f,%.1f,%.1f,%.1f\n",
            capture.native, capture.pid, fresh.origin.x, fresh.origin.y, fresh.size.width, fresh.size.height,
            capture.bounds.origin.x, capture.bounds.origin.y, capture.bounds.size.width, capture.bounds.size.height);
        return static_cast<AXUIElementRef>(CFRetain(capture.ax_target));
    }
    const auto now = CFAbsoluteTimeGetCurrent();
    if (now >= capture.ax_diagnostic_after) {
        capture.ax_diagnostic_after = now + 1.;
        std::fprintf(stderr, "window-ax-unavailable window=%u pid=%u cg=%.1f,%.1f,%.1f,%.1f capture=%.1f,%.1f,%.1f,%.1f\n",
            capture.native, capture.pid, fresh.origin.x, fresh.origin.y, fresh.size.width, fresh.size.height,
            capture.bounds.origin.x, capture.bounds.origin.y, capture.bounds.size.width, capture.bounds.size.height);
        if (!CGRectIsNull(fresh)) { if (auto probe = ax_window(capture.pid, fresh, true)) CFRelease(probe); }
    }
    return nullptr;
}
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
    vf::NativeTouchpadAssembler activity_gestures;
    bool hid_available{}, hid_requested{};
    vm::Options options;
    vm::Output output;
    struct Lane {
        vm::Encoder encoder;
        vm::FrameSchedule frame_schedule;
        vm::ExactAlphaCache alpha_cache;
        vm::SerialWorker encode_worker,completion_worker;
        unsigned encoder_pending{};
        bool encoding{},force_keyframe=true,dirty=true;
        unsigned stable_canvas_width{},stable_canvas_height{};
        double residency_shrink_since{},next_frame{};
        std::uint64_t epoch{};
        viewflow::activity::Feedback feedback[3];
        viewflow::activity::Congestion congestion;
        explicit Lane(const vm::Options& config):encoder(config.fps,config.performance_mode==vm::PerformanceMode::latency){}
    };
    std::unique_ptr<Lane> lanes[2];
    bool activity_enabled=viewflow::activity::negotiated(),dual=activity_enabled;
    viewflow::activity::Priority<std::uint64_t> activity;
    viewflow::activity::SingleLaneBudget single_budget;
    std::vector<std::uint64_t> activity_members;
    std::uint64_t activity_epoch=1,activity_preferred{},activity_focus{};
    unsigned host_background_fps{};double host_sample_at{};
    void poll_host_budget(){
        if(!activity_enabled || options.activity_coordinator.empty())return;
        const double now=NSProcessInfo.processInfo.systemUptime;if(now-host_sample_at<.25)return;host_sample_at=now;
        std::uint64_t queue_us=0;bool saturated=false;
        for(const auto& lane:lanes)if(lane)for(const auto& feedback:lane->feedback){queue_us=std::max(queue_us,feedback.queue_us);saturated|=feedback.saturated;}
        NSString* path=@(options.activity_coordinator.c_str());
        NSDictionary* state=@{@"updated":@(now),@"queue_us":@(queue_us),@"saturated":@(saturated),@"target_fps":@(options.fps)};
        [[NSJSONSerialization dataWithJSONObject:state options:0 error:nil] writeToFile:path atomically:YES];
        NSData* data=[NSData dataWithContentsOfFile:[[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"budget.json"]];
        id budget=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        host_background_fps=0;
        if([budget isKindOfClass:NSDictionary.class] && [budget[@"updated"] isKindOfClass:NSNumber.class] && [budget[@"background_fps"] isKindOfClass:NSNumber.class]){
            const double age=now-[budget[@"updated"] doubleValue];const auto fps=[budget[@"background_fps"] unsignedIntValue];
            if(age>=0 && age<2 && (fps==0 || fps==30 || fps==15 || fps==5))host_background_fps=fps;
        }
    }
    vm::InputPriority input_priority;
    vm::FrameSchedule::Versions submitted_popup_versions;
    uint64_t priority_submitted{},priority_reserved{},priority_scans{};
    dispatch_queue_t capture_queue,popup_capture_queue;
    uint64_t completed_frames{};double completion_report_at{};
    uint64_t emit_ticks{},prepare_busy{},pipeline_full{},no_change{},output_busy{};
    bool busy()const{return lanes[0]->encoding || lanes[0]->encoder_pending || (lanes[1] && (lanes[1]->encoding || lanes[1]->encoder_pending));}
    vm::SerialWorker inventory_worker;
    bool inventory_busy{};
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
        output(config.performance_mode == vm::PerformanceMode::latency ? 1 : 3) {
        lanes[0]=std::make_unique<Lane>(config);
        if(activity_enabled)lanes[1]=std::make_unique<Lane>(config);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) throw std::runtime_error("Metal device unavailable");
        capture_queue = dispatch_queue_create("org.viewflow.window-capture",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        popup_capture_queue = dispatch_queue_create("org.viewflow.popup-capture",
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
        activity.release(window,viewflow::activity::now_us());
        if(access("/tmp/viewflow-secondary-trace",F_OK)==0)std::fprintf(stderr,"secondary-source at=%.6f release=%llu held-buttons=%zu\n",NSProcessInfo.processInfo.systemUptime,static_cast<unsigned long long>(window),buttons.size());
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
        if(access("/tmp/viewflow-secondary-trace",F_OK)==0)std::fprintf(stderr,"secondary-source at=%.6f focus=%u parent=%llu\n",NSProcessInfo.processInfo.systemUptime,capture.native,static_cast<unsigned long long>(capture.parent_id));
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
    void apply_geometry(Capture& capture, double now) {
        if (!capture.geometry_request.latest || now < capture.geometry_retry_after) return;
        capture.geometry_retry_after = now + 1. / 60.;
        const auto request = *capture.geometry_request.latest;
        AXUIElementRef window = ax_window(capture);
        if (!window) return; // Keep the final requested placement for recovery.
        const CGPoint requested{request.x / options.scale, request.y / options.scale};
        const CGSize size{request.width / options.scale, request.height / options.scale};
        const CGPoint backing = vm::backing_position(requested, size);
        AXValueRef position = AXValueCreate(kAXValueTypeCGPoint, &backing), extent = AXValueCreate(kAXValueTypeCGSize, &size);
        const auto moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute, position);
        const auto resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute, extent);
        CFRelease(position); CFRelease(extent); CFRelease(window);
        if (moved == kAXErrorSuccess) capture.placement.expect_backing(backing.x, backing.y);
        const auto actual = window_bounds(capture.native, capture.pid);
        if (!CGRectIsNull(actual)) {
            ++capture.bounds_revision; capture.bounds = actual;
            capture.placement.observe(actual.origin.x, actual.origin.y);
        }
        capture.placement.place(requested.x, requested.y);
        if (moved == kAXErrorSuccess && resized == kAXErrorSuccess && capture.geometry_request.complete(request.sequence)) {
            capture.geometry_ack = request.sequence; dirty = true;
            std::fprintf(stderr, "window-geometry-applied window=%u sequence=%llu requested=%.1f,%.1f,%.1f,%.1f backing=%.1f,%.1f\n",
                capture.native, (unsigned long long)request.sequence, requested.x, requested.y, size.width, size.height, backing.x, backing.y);
        } else {
            std::fprintf(stderr, "window-geometry-pending window=%u sequence=%llu move=%d resize=%d ack=%llu\n",
                capture.native, (unsigned long long)request.sequence, moved, resized, (unsigned long long)capture.geometry_ack);
        }
    }
    void input(const vf::Input& event) {
        if (event.sequence <= sequence) { std::fprintf(stderr, "window input sequence regression\n"); return; }
        sequence = event.sequence;
        viewflow::activity::observe(activity,event,viewflow::activity::now_us());
        if (event.kind == vf::InputKind::release) {
            // Explicit target cancellation is different from the HID route's
            // local button release while handing an active drag across screens.
            for (auto& [_, candidate] : captures) if (!event.id || candidate->id == event.id) {
                if (candidate->native_drag || candidate->native_drag_bootstrap) dirty = true;
                candidate->native_drag = candidate->native_drag_bootstrap = false;
            }
            release(event.id); return;
        }
        Capture* capture = nullptr;
        for (auto& [_, candidate] : captures) if (candidate->active && candidate->id == event.id) capture = candidate.get();
        if (event.kind == vf::InputKind::visibility) {
            if(!capture)return;
            capture->residency=vf::clip_resident(capture->pixel_width(),capture->pixel_height(),event.a,event.b,event.c,event.d);
            capture->residency_width=capture->pixel_width(); capture->residency_height=capture->pixel_height();
            dirty=true; return;
        }
        if (capture && event.kind == vf::InputKind::geometry) {
            if (event.c <= 0 || event.d <= 0 || event.c > 16384 || event.d > 16384) return;
            capture->geometry_request.queue({event.sequence, event.a, event.b, event.c, event.d});
            capture->native_drag = capture->native_drag_bootstrap = false;
            const CGPoint requested{event.a / options.scale, event.b / options.scale};
            const auto backing = vm::backing_position(requested, {event.c / options.scale, event.d / options.scale});
            capture->placement.expect_backing(backing.x, backing.y);
            capture->placement.place(requested.x, requested.y); dirty = true;
            std::fprintf(stderr, "window-geometry-queued window=%u sequence=%llu ack=%llu\n",
                capture->native, (unsigned long long)event.sequence, (unsigned long long)capture->geometry_ack);
            return;
        }
        if (!capture || capture->dormant) { release(event.id); return; }
        input_target = capture;
        if (event.kind == vf::InputKind::touchpad_frame && event.a == 0 && event.b == 0 && event.c == 0 && event.d == 2) {
            hid_requested = true; dirty = true; return;
        }
        if (event.kind == vf::InputKind::native_touchpad_chunk || event.kind == vf::InputKind::native_touchpad_commit) {
            vf::NativeTouchpadReport report{};
            if(activity_gestures.input(event,report)){
                bool touching=report[1]!=0;for(unsigned i=0;i<report[0];++i)touching|=report[13+12*i]!=0;
                activity.hold(event.id,3,0,touching,viewflow::activity::now_us());
            }
            hid.input(event, NSProcessInfo.processInfo.systemUptime); return;
        }
        ++capture->bounds_revision;
        const auto bounds = window_bounds(capture->native, capture->pid);
        if (CGRectIsNull(bounds)) { release(event.id); return; }
        capture->bounds = bounds; capture->placement.observe(bounds.origin.x, bounds.origin.y);
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
            if(access("/tmp/viewflow-secondary-trace",F_OK)==0)std::fprintf(stderr,"secondary-source at=%.6f seq=%llu button=%u down=%d clicks=%u\n",NSProcessInfo.processInfo.systemUptime,static_cast<unsigned long long>(event.sequence),code,event.b,click.second);
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
            if(down) { input_priority.key(NSProcessInfo.processInfo.systemUptime); next_menu_scan=0; }
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
        case vf::InputKind::close: {
            capture->geometry_request.latest.reset();
            capture->native_drag = capture->native_drag_bootstrap = false;
            AXUIElementRef window = ax_window(*capture);
            if (!window) { std::fprintf(stderr, "window %u close target unavailable\n", capture->native); return; }
            CFTypeRef button = nullptr;
            if (AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute, &button) == kAXErrorSuccess && button) {
                AXUIElementPerformAction(static_cast<AXUIElementRef>(button), kAXPressAction); CFRelease(button);
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
                        const bool had_material = item->material && item->material->image();
                        if (item->material) item->material->scene(scene, display_bounds, timestamp);
                        if (!scene) { if(item->preview || had_material){item->preview=nil;++item->samples;dirty=true;}continue; }
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
        if (!parent && options.native_drag && !options.windows.empty() && native == options.windows.front()) {
            capture->native_drag = capture->native_drag_bootstrap = true;
            capture->native_drag_last_left = CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft);
            capture->native_drag_grab = CGPointMake(options.native_drag_grab_x, options.native_drag_grab_y);
        }
        capture->transient=parent!=0;capture->created_at=NSProcessInfo.processInfo.systemUptime;
        capture->bounds=bounds;capture->placement.observe(bounds.origin.x,bounds.origin.y);capture->title=title;
        capture->width=static_cast<unsigned>(std::ceil(bounds.size.width*options.scale/2))*2;
        capture->height=static_cast<unsigned>(std::ceil(bounds.size.height*options.scale/2))*2;
        if(!capture->width || !capture->height || capture->width>8192 || capture->height>8192)throw std::runtime_error("selected window exceeds supported capture extent");
        if(!parent) {
            NSRunningApplication* application=[NSRunningApplication runningApplicationWithProcessIdentifier:static_cast<pid_t>(pid)];
            NSString* identity=application.bundleIdentifier ?: application.localizedName;
            NSImage* icon=application.icon;
            if(identity.length && icon) {
                NSBitmapImageRep* bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:128 pixelsHigh:128 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                [NSGraphicsContext saveGraphicsState];[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
                [icon drawInRect:NSMakeRect(0,0,128,128) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
                [NSGraphicsContext restoreGraphicsState];
                NSData* png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                if(png.length && png.length<=256*1024) {
                    capture->app_id="macos:"+std::string(identity.UTF8String);capture->app_id.resize(std::min<size_t>(capture->app_id.size(),256));
                    capture->icon_png.assign(static_cast<const uint8_t*>(png.bytes),static_cast<const uint8_t*>(png.bytes)+png.length);
                    std::fprintf(stderr,"macos-application-icon window=%u bytes=%zu\n",native,capture->icon_png.size());
                }
            }
        }
        auto* result=capture.get();captures.emplace(native,std::move(capture));return result;
    }
    void add_capture(SCWindow* window,uint64_t parent=0) {
    auto* capture=prepare_capture(window.windowID,static_cast<unsigned>(window.owningApplication.processID),window.frame,parent,window.title.UTF8String ?: "Shared window");
    if(capture->stream || !capture->active)return;
    capture->native_window=window;
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
    if (![capture->stream addStreamOutput:capture->callback type:SCStreamOutputTypeScreen sampleHandlerQueue:(capture->transient ? popup_capture_queue : capture_queue) error:&stream_error])
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
                    if (![next addStreamOutput:capture->callback type:SCStreamOutputTypeScreen sampleHandlerQueue:(capture->transient ? popup_capture_queue : capture_queue) error:&output_error]) return;
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
        next_menu_scan=now+input_priority.discovery_period(now);
        if(input_priority.active(now))++priority_scans;
        CFArrayRef list=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
        if(!list)return;
        NSArray* windows=CFBridgingRelease(list);
        std::set<unsigned> visible;
        for(NSDictionary* item in windows)visible.insert([item[(__bridge NSString*)kCGWindowNumber] unsignedIntValue]);
        for(auto it=captures.begin();it!=captures.end();) {
            auto* c=it->second.get();
            if(c->parent_id && !visible.contains(c->native) && c->active){if(access("/tmp/viewflow-secondary-trace",F_OK)==0)std::fprintf(stderr,"secondary-source at=%.6f menu-gone=%u\n",now,c->native);release(c->id);c->stop();dirty=true;}
            if(c->parent_id && !c->active && c->stopped && !c->starting && !c->updating && !c->restarting && !c->suspending && !c->bootstrap_pending) {
                if(input_target==c)input_target=nullptr;
                submitted_popup_versions.erase(c->id);
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
                if(input_priority.active(now))std::fprintf(stderr,"ime-priority-discovered window=%u since-key-ms=%.2f\n",native,input_priority.key_age(now)*1000);
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
        for (auto& [_, capture] : captures) if (capture->active) apply_geometry(*capture, now);
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
                    observation.left_down = CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft);
                    if (CGEventRef event = CGEventCreate(nullptr)) {
                        observation.pointer = CGEventGetLocation(event); CFRelease(event);
                        observation.pointer_valid = true;
                    }
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
        bool left_down{}, pointer_valid{};
        CGPoint pointer{};
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
            // Routing to another target deliberately releases the Mac HID
            // button. Keep the inherited handoff until geometry acknowledges
            // ownership, or a new local press starts a different gesture.
            if (capture->native_drag_bootstrap && observation.left_down && !capture->native_drag_last_left) {
                capture->native_drag = capture->native_drag_bootstrap = false; dirty = true;
            }
            capture->native_drag_last_left = observation.left_down;
            if (!observation.left_down && !capture->native_drag_bootstrap && capture->native_drag) {
                capture->native_drag = false; dirty = true;
            }
            if (!capture->transient && observation.left_down && observation.pointer_valid &&
                !capture->placement.backing_pending && CGSizeEqualToSize(bounds.size, capture->bounds.size) &&
                !CGPointEqualToPoint(bounds.origin, capture->bounds.origin) && !capture->native_drag) {
                capture->native_drag = true;
                capture->native_drag_grab = CGPointMake(observation.pointer.x - bounds.origin.x, observation.pointer.y - bounds.origin.y);
                dirty = true;
            }
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
                if (capture->native_window) add_capture(capture->native_window, capture->parent_id);
            }
            // Publish the first ordinary window frame before doing auxiliary
            // material setup. Short-lived IME windows need no extra streams.
            if (!capture->material && capture->transient && !capture->starting && capture->native_window) setup_material(capture, capture->native_window);
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
    bool changed_popup() const {
        for(const auto& [_, capture]:captures)if(capture->active && capture->transient && capture->has_pixels() && capture->resident().width && capture->resident().height) {
            const auto found=submitted_popup_versions.find(capture->id);
            if(found==submitted_popup_versions.end() || found->second!=capture->samples)return true;
        }
        return false;
    }
    bool urgent_popup(double now) const { return input_priority.urgent(now,changed_popup(),options.fps); }
    bool emit() {
        poll_host_budget();
        if(!dual && lanes[1] && !lanes[1]->encoding && !lanes[1]->encoder_pending)lanes[1].reset();
        if(dirty){for(auto& lane:lanes)if(lane)lane->dirty=true;dirty=false;}
        if(activity_enabled){
            std::vector<std::pair<std::uint64_t,std::uint64_t>> visible;
            std::vector<std::uint64_t> members;
            for(const auto& [_,capture]:captures)if(capture->active && !capture->dormant){visible.emplace_back(capture->id,capture->parent_id);members.push_back(capture->id);}
            activity.membership(visible);std::sort(members.begin(),members.end());
            const auto preferred=dual?activity.preferred(viewflow::activity::now_us()):0;
            if(preferred!=activity_preferred || activity.last_focus()!=activity_focus || members!=activity_members){
                activity_preferred=preferred;activity_focus=activity.last_focus();activity_members=std::move(members);++activity_epoch;
            }
        }
        bool admitted=false;
        if(dual && activity_preferred)admitted=emit_lane(1);
        return emit_lane(0) || admitted;
    }
    bool emit_lane(unsigned lane_index) {
        auto& lane=*lanes[lane_index];
        auto& encoding=lane.encoding;auto& encoder_pending=lane.encoder_pending;
        auto& frame_schedule=lane.frame_schedule;auto& dirty=lane.dirty;
        auto& stable_canvas_width=lane.stable_canvas_width;auto& stable_canvas_height=lane.stable_canvas_height;
        auto& residency_shrink_since=lane.residency_shrink_since;
        auto& encode_worker=lane.encode_worker;
        if(activity_enabled && lane.epoch!=activity_epoch){lane.epoch=activity_epoch;lane.force_keyframe=true;dirty=true;lane.next_frame=0;}
        std::uint64_t queue_us=0;bool saturated=false;
        for(auto& feedback:lane.feedback){lane.force_keyframe|=feedback.keyframe;feedback.keyframe=false;
            queue_us=std::max(queue_us,feedback.queue_us);saturated|=feedback.saturated;}
        lane.congestion.observe(viewflow::activity::now_us(),queue_us,saturated,options.fps);
        auto target_fps=activity_enabled && !lane_index?lane.congestion.background_fps(options.fps):options.fps;
        if(!lane_index && host_background_fps)target_fps=std::min(target_fps,host_background_fps);
        const auto preferred_window=activity.preferred(viewflow::activity::now_us());
        const bool weighted_single=activity_enabled && !dual && preferred_window;
        const bool background_due=!weighted_single || single_budget.background_due(viewflow::activity::now_us(),target_fps);
        if(weighted_single)target_fps=options.fps;
        const auto publish=[&](std::uint64_t id,std::uint64_t owner){
            (void)owner;return !weighted_single || background_due || activity.belongs(id,preferred_window);
        };
        const auto selected=[&](std::uint64_t id,std::uint64_t owner){(void)owner;return activity.belongs(id,activity_preferred);};
        const auto now = NSProcessInfo.processInfo.systemUptime;
        if(NSProcessInfo.processInfo.systemUptime<lane.next_frame)return false;
        ++emit_ticks;
        if (encoding) { ++prepare_busy; return false; }
        const bool popup_changed=changed_popup();
        if (encoder_pending >= input_priority.queue_limit(now,popup_changed)) {
            if(input_priority.active(now) && !popup_changed)++priority_reserved;
            ++pipeline_full; return false;
        }
        if (!dirty && !frame_schedule.refresh_due(now) && !(weighted_single && background_due)) { ++no_change; return false; }
        if (!output.ready()) { ++output_busy; return false; }
        vf::Frame frame; frame.codec = options.codec;frame.keyframe=lane.force_keyframe;
        if(activity_enabled){frame.activity_lane=lane_index;frame.activity_epoch=activity_epoch;frame.activity_preferred=activity_preferred;frame.activity_focus=activity_focus;frame.activity_members=activity_members;}
        frame.pts = static_cast<int64_t>(++frame_sequence * 1'000'000 / options.fps);
        // NVDEC HEVC has a 144-pixel minimum decoded extent. Pad bootstrap
        // frames and small popup atlases; tile/body geometry stays independent.
        const unsigned minimum_extent = options.codec == 2 ? 144u : 64u;
        unsigned largest = minimum_extent; uint64_t area = 0;
        for (const auto& [_, capture] : captures) if (capture->active && capture->has_pixels() && (!lane_index || selected(capture->id,capture->parent_id))) {
            const auto resident=capture->resident();
            largest = std::max(largest, resident.width);
            area += uint64_t(resident.width) * resident.height;
        }
        unsigned canvas = std::min(8192u, std::max(largest, static_cast<unsigned>(std::ceil(std::sqrt(double(area)) / 2)) * 2));
        if (options.native_decorations) {
            // Keep menu churn from restarting codecs, but release a sustained
            // large invisible area after viewport demand has settled.
            const bool saving=stable_canvas_width && area*2<uint64_t(stable_canvas_width)*stable_canvas_height;
            if(saving) {
                if(!residency_shrink_since)residency_shrink_since=now;
                if(now-residency_shrink_since>=.5 && encoder_pending==0) {
                    stable_canvas_width=canvas;stable_canvas_height=0;residency_shrink_since=0;
                }
            } else residency_shrink_since=0;
            stable_canvas_width = std::max(stable_canvas_width, canvas); canvas = stable_canvas_width;
        }
        unsigned x = 0, y = 0, row = 0;
        vm::FrameSchedule::Versions versions;
        // First lay out tiles. Atlas source rectangles use top-left coordinates.
        for (const auto& [_, capture] : captures) if (capture->active && capture->has_pixels() && (!lane_index || selected(capture->id,capture->parent_id))) {
            const auto width = capture->pixel_width();
            const auto height = capture->pixel_height();
            const auto resident=capture->resident();
            if (x + resident.width > canvas) { y += row; x = 0; row = 0; }
            if (y + resident.height > 8192 || uint64_t(canvas) * (y + resident.height) > vf::max_pixels) continue;
            frame.tiles.push_back({capture->id, capture->parent_id,
                static_cast<int32_t>(std::lround(capture->placement.x * options.scale)),
                static_cast<int32_t>(std::lround(capture->placement.y * options.scale)),
                width, height, x, y, capture->title.substr(0, 4096), vf::residency_capability | (capture->native_drag ? 5u : 0u) | (capture->fullscreen ? vf::fullscreen_flag : 0u) | (hid_available ? 8u : 0u) | (capture->transient ? 2u : 0u) | (options.native_decorations && !capture->transient ? vf::backdrop_capability : 0u) | (options.native_decorations ? 16u : 0u), capture->geometry_ack});
            if(!capture->icon_sent && !capture->icon_png.empty()) {
                auto& tile=frame.tiles.back();tile.flags|=vf::application_icon_flag;tile.app_id=capture->app_id;tile.icon_png=capture->icon_png;
            }
            if (capture->native_drag) {
                auto& tile = frame.tiles.back();
                tile.grab_x = std::lround(capture->native_drag_grab.x);
                tile.grab_y = std::lround(capture->native_drag_grab.y);
            }
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
            if(capture->residency)vf::set_resident_rect(frame.tiles.back(),resident);
            if(resident.width && resident.height && publish(capture->id,capture->parent_id) && (lane_index || !selected(capture->id,capture->parent_id)))versions.emplace(capture->id, capture->samples);
            x += resident.width; row = std::max(row, resident.height);
        }
        frame.width = canvas; frame.height = std::max(minimum_extent, y + row);
        if (options.native_decorations) {
            // Reserve a popup strip before the first menu, and never shrink on
            // close. Otherwise every IME opening recreates VT and NVDEC.
            if (!stable_canvas_height && std::any_of(frame.tiles.begin(), frame.tiles.end(), [](const auto& tile) { return !(tile.flags & 2) && vf::resident_rect(tile).height; })) stable_canvas_height = std::min(8192u, frame.height + 512u);
            if (stable_canvas_height) {
                stable_canvas_height = std::max(stable_canvas_height, frame.height);
                if (uint64_t(canvas) * stable_canvas_height <= vf::max_pixels) frame.height = stable_canvas_height;
            }
        }
        if(weighted_single && !background_due)std::erase_if(frame.tiles,[&](const auto& tile){return !publish(tile.id,tile.owner);});
        if (!lane.force_keyframe && !frame_schedule.needs_frame(frame.tiles, versions, frame.width, frame.height, now)) {
            dirty = false;
            return false;
        }
        CIImage* atlas = nil;
        std::shared_ptr<__CVBuffer> direct_pixels;
        if (frame.tiles.size() == 1 && (lane_index || !selected(frame.tiles[0].id,frame.tiles[0].owner)) && vf::resident_rect(frame.tiles.front()) == vf::PixelRect{0,0,frame.tiles.front().width,frame.tiles.front().height} && frame.tiles.front().atlas_x == 0 && frame.tiles.front().atlas_y == 0 &&
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
        const bool single_direct=atlas!=nil;
        if (!atlas) atlas = [[CIImage imageWithColor:CIColor.clearColor] imageByCroppingToRect:CGRectMake(0, 0, 8192, 8192)];
        const auto copy_order=viewflow::activity::ordered_tiles(frame.tiles,preferred_window,activity_focus);
        for (const auto* ordered : copy_order) {
            const auto& tile=*ordered;
            if(!lane_index && selected(tile.id,tile.owner))continue;
            const auto resident=vf::resident_rect(tile);
            if(!resident.width || !resident.height)continue;
            if(single_direct)continue;
            Capture* capture = nullptr;
            for (auto& [_, item] : captures) if (item->id == tile.id) capture = item.get();
            CIImage* image = capture->material ? capture->material->image() : nil;
            if (!image) image = capture->preview;
            if (!image) image = [CIImage imageWithCVPixelBuffer:capture->latest];
            const auto source_y=tile.height-resident.y-resident.height;
            image = [image imageByCroppingToRect:CGRectMake(resident.x,source_y,resident.width,resident.height)];
            image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(double(tile.atlas_x)-resident.x, double(frame.height)-tile.atlas_y-resident.height-source_y)];
            atlas = [image imageByCompositingOverImage:atlas];
        }
        // Snapshot owns the CI graph (and its captured pixel buffers) until the
        // serial preparation completes. At most two frames are in flight;
        // captures continue replacing latest while ordered completion runs.
        auto job = std::make_shared<vf::Frame>(frame);
        encoding = true;
        ++encoder_pending;
        const bool accepted = encode_worker.submit([this, job, atlas, direct_pixels, versions, lane_index] {
            @autoreleasepool {
                auto& lane=*lanes[lane_index];auto& alpha_cache=lane.alpha_cache;
                auto& encoder=lane.encoder;auto& completion_worker=lane.completion_worker;
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
                dispatch_async(dispatch_get_main_queue(), ^{ lanes[lane_index]->encoding = false; });
            }
        });
        if (!accepted) { encoding = false; --encoder_pending; return false; }
        for(const auto& tile:frame.tiles)if(tile.flags&2) {
            if(const auto version=versions.find(tile.id);version!=versions.end())submitted_popup_versions[tile.id]=version->second;
        }
        if(popup_changed) { input_priority.submitted_popup(now); if(input_priority.active(now))++priority_submitted; }
        dirty = false;lane.force_keyframe=false;lane.next_frame=now+1./std::max(1u,target_fps);
        if(weighted_single && background_due)single_budget.submitted_background(viewflow::activity::now_us());
        if (frame_sequence == 1 || frame_sequence % 120 == 0) {
            uint64_t samples = 0, coalesced = 0;
            for (const auto& [_, item] : captures) { samples += item->samples; coalesced += item->coalesced; }
            std::fprintf(stderr, "macos-window-source-stats frames=%llu samples=%llu coalesced=%llu windows=%zu\n",
                static_cast<unsigned long long>(frame_sequence), static_cast<unsigned long long>(samples),
                static_cast<unsigned long long>(coalesced), frame.tiles.size());
        }
        return true;
    }
    void completed(const std::shared_ptr<vf::Frame>& job, const vm::FrameSchedule::Versions& versions, bool succeeded) {
        const auto lane_index=job->activity_epoch?job->activity_lane:0;
        auto& lane=*lanes[lane_index];auto& encoder_pending=lane.encoder_pending;auto& frame_schedule=lane.frame_schedule;
        if(!succeeded && lane_index){dual=false;lane.force_keyframe=true;
            std::fprintf(stderr,"activity_priority fallback=single reason=optional-encoder-failure\n");}
        --encoder_pending;
        if (!succeeded) { dirty = true; submitted_popup_versions.clear(); return; }
        const double now = NSProcessInfo.processInfo.systemUptime;
        if (completion_report_at == 0) completion_report_at = now;
        ++completed_frames;
        if (now - completion_report_at >= 2.) {
            std::fprintf(stderr, "macos-source-throughput width=%u height=%u target-fps=%u completed-fps=%.2f in-flight=%u\n",
                job->width, job->height, options.fps, completed_frames / (now - completion_report_at), encoder_pending);
            uint64_t full_pixels=0,resident_pixels=0;
            for(const auto& tile:job->tiles){const auto r=vf::resident_rect(tile);full_pixels+=uint64_t(tile.width)*tile.height;resident_pixels+=uint64_t(r.width)*r.height;}
            std::fprintf(stderr,"macos-source-residency full-pixels=%llu resident-pixels=%llu canvas-pixels=%llu windows=%zu\n",
                (unsigned long long)full_pixels,(unsigned long long)resident_pixels,(unsigned long long)(uint64_t(job->width)*job->height),job->tiles.size());
            std::fprintf(stderr, "macos-source-cadence ticks=%llu prepare-busy=%llu pipeline-full=%llu unchanged=%llu output-busy=%llu interval-ms=%.1f\n",
                (unsigned long long)emit_ticks, (unsigned long long)prepare_busy, (unsigned long long)pipeline_full,
                (unsigned long long)no_change, (unsigned long long)output_busy, (now - completion_report_at) * 1000);
            std::fprintf(stderr,"macos-ime-priority active=%u popup-submitted=%llu reserved-slot-waits=%llu discovery-scans=%llu\n",
                unsigned(input_priority.active(now)),(unsigned long long)priority_submitted,(unsigned long long)priority_reserved,(unsigned long long)priority_scans);
            priority_submitted=priority_reserved=priority_scans=0;
            emit_ticks = prepare_busy = pipeline_full = no_change = output_busy = 0;
            completion_report_at = now; completed_frames = 0;
        }
        frame_schedule.submitted(job->tiles, versions, job->width, job->height, NSProcessInfo.processInfo.systemUptime);
        for (const auto& tile : job->tiles) for (auto& [_, item] : captures) if (item->id == tile.id) {
            if(tile.flags&vf::application_icon_flag)item->icon_sent=true;
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
        vf::Reader tag{bytes};const auto record_type=tag.u32();
        if(record_type==6 && source.activity_enabled){
            const auto hint=viewflow::activity::unpack_hint(bytes);
            dispatch_sync(dispatch_get_main_queue(), ^{if(!source.quitting)viewflow::activity::observe(source.activity,hint,viewflow::activity::now_us());});return;
        }
        if(record_type==5 && source.activity_enabled){
            const auto feedback=viewflow::activity::unpack_feedback(bytes);
            dispatch_sync(dispatch_get_main_queue(), ^{if(!source.quitting){
                if(!source.lanes[feedback.lane])return;
                auto& previous=source.lanes[feedback.lane]->feedback[feedback.stage];
                const bool keyframe=previous.keyframe || feedback.keyframe;previous=feedback;previous.keyframe=keyframe;
                if(feedback.single_lane)source.dual=false;
            }});return;
        }
        if (record_type == 3) {
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
            const double wait = std::min(cadence.wait(before_wait),source.input_priority.active(before_wait)?.002:.005);
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:wait]];
            const double now = NSProcessInfo.processInfo.systemUptime;
            if (now >= next_refresh) { source.refresh(); next_refresh = now + 1.0/60.0; }
            if(source.input_priority.active(now))source.scan_menus(now);
            const bool regular=cadence.due(now);
            if (regular || source.urgent_popup(now)) {
                bool admitted=false;
                try { admitted=source.emit(); }
                catch (const std::exception& error) { std::fprintf(stderr, "window encode recovering: %s\n", error.what()); }
                // Failed urgent attempts do not move the ordinary deadline.
                if(regular)cadence.advance(now,options.fps);
                else if(admitted)cadence.restart(now,options.fps);
            }
        }
    }
    source.quitting = true; source.popup_previews.clear(); source.desktop_backdrop.clear(); input.stop(); source.output.stop(); source.release(0);
    for (auto& [_, capture] : source.captures) capture->stop();
    // Complete callbacks while their native owners still exist. No frame age
    // is consulted, and no focus/input event is generated by this shutdown.
    while (source.busy() || source.inventory_busy || !input.finished() || !source.discovery_done || source.menu_discovery_busy || std::any_of(source.captures.begin(), source.captures.end(),
        [](const auto& item) { return !item.second->stopped || item.second->starting || item.second->restarting || item.second->updating || item.second->bootstrap_pending; }))
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    // Service any final callback snapshot/handoff before destroying Source.
    __block unsigned captures_drained = 0;
    dispatch_async(source.capture_queue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{ ++captures_drained; });
    });
    dispatch_async(source.popup_capture_queue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{ ++captures_drained; });
    });
    while (captures_drained<2)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    if (!source.failure.empty()) throw std::runtime_error(source.failure);
    return 0;
}
}

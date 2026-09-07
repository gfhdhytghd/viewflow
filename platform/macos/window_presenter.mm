#include "window_native.hpp"
#include "window_codec.hpp"
#include "window_io.hpp"
#include "window_keys.hpp"
#include "window_pixels.hpp"
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include <cmath>
#include <map>
#include <set>

namespace vf = viewflow::reverse;
namespace vm = viewflow::macos;
namespace { struct Presenter; struct Proxy; }
@interface VFProxyWindow : NSWindow
@end
@interface VFProxyView : NSView <NSWindowDelegate> {
@public Proxy* proxy;
}
@end
namespace {
struct Proxy {
    Presenter* owner{};
    vf::Tile tile;
    VFProxyWindow* __strong window = nil;
    VFProxyView* __strong view = nil;
    CAMetalLayer* __strong layer = nil;
    CIImage* __strong image = nil;
    bool applying{}, drawing{}, dragging{}, needs_draw{};
    uint64_t geometry_pending{};
    std::set<unsigned> modifiers;
    ~Proxy();
};
struct Presenter {
    vm::Options options;
    vm::Output output{4096};
    id<MTLDevice> __strong device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> __strong commands;
    CIContext* __strong context;
    CGColorSpaceRef color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    std::map<uint64_t, std::unique_ptr<Proxy>> windows;
    uint64_t sequence{};
    unsigned outstanding{};
    bool quitting{}, recovery_release{};
    explicit Presenter(const vm::Options& config) : options(config) {
        if (!device) throw std::runtime_error("Metal device unavailable");
        commands = [device newCommandQueue];
        context = [CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace: (__bridge id)color_space}];
    }
    ~Presenter() { windows.clear(); CGColorSpaceRelease(color_space); }
    uint64_t send(uint64_t id, vf::InputKind kind, int a = 0, int b = 0, int c = 0, int d = 0) {
        if (quitting) return 0;
        if (recovery_release) {
            if (!output.push(vf::pack_input({0, ++sequence, vf::InputKind::release, 0, 0, 0, 0}))) return 0;
            recovery_release = false;
        }
        const auto current = ++sequence;
        if (!output.push(vf::pack_input({id, current, kind, a, b, c, d}))) {
            recovery_release = true;
            std::fprintf(stderr, "proxy input backpressure: queue retained, releasing held input when pipe resumes\n");
            return 0;
        }
        return current;
    }
    void pointer(Proxy& proxy, NSEvent* event) {
        const auto point = [proxy.view convertPoint:event.locationInWindow fromView:nil];
        const auto size = proxy.view.bounds.size;
        if (size.width <= 0 || size.height <= 0) return;
        send(proxy.tile.id, vf::InputKind::pointer,
            static_cast<int>(std::lround(point.x * proxy.tile.width / size.width)),
            static_cast<int>(std::lround(point.y * proxy.tile.height / size.height)));
    }
    void geometry(Proxy& proxy) {
        if (proxy.applying || quitting) return;
        const auto rect = proxy.window.frame;
        const double desktop_top = NSScreen.screens.firstObject.frame.size.height;
        proxy.geometry_pending = send(proxy.tile.id, vf::InputKind::geometry,
            static_cast<int>(std::lround((rect.origin.x - options.origin_x) * options.scale)),
            static_cast<int>(std::lround((desktop_top - NSMaxY(rect) - options.origin_y) * options.scale)),
            static_cast<int>(std::lround(rect.size.width * options.scale)),
            static_cast<int>(std::lround(rect.size.height * options.scale)));
    }
    void draw(Proxy& proxy) {
        if (!proxy.image || proxy.drawing || !proxy.needs_draw) return;
        const auto scale = proxy.window.backingScaleFactor;
        const auto bounds = proxy.view.bounds;
        if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
        proxy.layer.contentsScale = scale;
        proxy.layer.drawableSize = CGSizeMake(std::ceil(bounds.size.width * scale), std::ceil(bounds.size.height * scale));
        id<CAMetalDrawable> drawable = [proxy.layer nextDrawable];
        if (!drawable) return;
        id<MTLCommandBuffer> command = [commands commandBuffer];
        const auto extent = proxy.image.extent;
        CIImage* rendered = [proxy.image imageByApplyingTransform:CGAffineTransformMakeScale(
            proxy.layer.drawableSize.width / extent.size.width, proxy.layer.drawableSize.height / extent.size.height)];
        [context render:rendered toMTLTexture:drawable.texture commandBuffer:command
            bounds:CGRectMake(0, 0, proxy.layer.drawableSize.width, proxy.layer.drawableSize.height) colorSpace:color_space];
        [command presentDrawable:drawable];
        // Keep both the decoded image and its alpha mask through GPU reads.
        __block CIImage* retained = rendered;
        const auto window_id = proxy.tile.id;
        Presenter* owner = this;
        proxy.drawing = true; proxy.needs_draw = false; ++outstanding;
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            retained = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                --owner->outstanding;
                auto it = owner->windows.find(window_id);
                if (it != owner->windows.end()) it->second->drawing = false;
                if (completed.status == MTLCommandBufferStatusError)
                    std::fprintf(stderr, "window Metal submission failed: %s\n", completed.error.localizedDescription.UTF8String);
            });
        }];
        [command commit];
    }
    void present(const vf::Frame& frame, CVPixelBufferRef buffer) {
        auto alpha = vf::decode_alpha(frame.alpha, static_cast<size_t>(frame.width) * frame.height);
        CIImage* composed = vm::join_planes(buffer, alpha);
        std::set<uint64_t> live;
        for (const auto& tile : frame.tiles) {
            live.insert(tile.id);
            auto& entry = windows[tile.id];
            if (!entry) {
                entry = std::make_unique<Proxy>(); auto& proxy = *entry;
                proxy.owner = this; proxy.tile = tile;
                proxy.window = [[VFProxyWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1, 1)
                    styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
                proxy.window.releasedWhenClosed = NO;
                proxy.window.opaque = NO; proxy.window.backgroundColor = NSColor.clearColor;
                proxy.window.hasShadow = NO; proxy.window.acceptsMouseMovedEvents = YES;
                proxy.window.title = [[NSString alloc] initWithBytes:tile.title.data() length:tile.title.size() encoding:NSUTF8StringEncoding] ?: @"Shared window";
                proxy.view = [[VFProxyView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)]; proxy.view->proxy = &proxy;
                proxy.layer = [CAMetalLayer layer]; proxy.layer.device = device;
                proxy.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
                proxy.layer.framebufferOnly = NO; proxy.layer.opaque = NO;
                proxy.view.wantsLayer = YES; proxy.view.layer = proxy.layer;
                proxy.window.contentView = proxy.view; proxy.window.delegate = proxy.view;
                [proxy.window makeFirstResponder:proxy.view];
            }
            auto& proxy = *entry; proxy.tile = tile;
            const double desktop_top = NSScreen.screens.firstObject.frame.size.height;
            const auto rect = NSMakeRect(options.origin_x + tile.x / options.scale,
                desktop_top - options.origin_y - (tile.y + double(tile.height)) / options.scale,
                tile.width / options.scale, tile.height / options.scale);
            if (!proxy.dragging && (!proxy.geometry_pending || tile.geometry_ack >= proxy.geometry_pending)) {
                proxy.geometry_pending = 0; proxy.applying = true;
                if (!NSEqualRects(proxy.window.frame, rect)) [proxy.window setFrame:rect display:NO];
                proxy.applying = false;
            }
            const auto crop = CGRectMake(tile.atlas_x, frame.height - tile.atlas_y - tile.height, tile.width, tile.height);
            proxy.image = [[composed imageByCroppingToRect:crop] imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x, -crop.origin.y)];
            proxy.needs_draw = true;
            if (!proxy.window.isVisible) [proxy.window orderFront:nil]; // No activation or key-window change.
            draw(proxy);
        }
        for (auto it = windows.begin(); it != windows.end();) {
            if (!live.contains(it->first)) { send(it->first, vf::InputKind::release); it = windows.erase(it); }
            else ++it;
        }
    }
};
Proxy::~Proxy() { window.delegate = nil; view->proxy = nullptr; [window close]; }
}
@implementation VFProxyWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end
@implementation VFProxyView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (void)updateTrackingAreas {
    for (NSTrackingArea* area in self.trackingAreas.copy) [self removeTrackingArea:area];
    [super updateTrackingAreas];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent*)event { if (proxy) proxy->owner->pointer(*proxy, event); }
- (void)mouseEntered:(NSEvent*)event { [self mouseMoved:event]; }
- (void)mouseDragged:(NSEvent*)event { [self mouseMoved:event]; }
- (void)rightMouseDragged:(NSEvent*)event { [self mouseMoved:event]; }
- (void)otherMouseDragged:(NSEvent*)event { [self mouseMoved:event]; }
- (void)button:(NSEvent*)event down:(BOOL)down {
    if (!proxy || event.buttonNumber > 4) return;
    proxy->owner->pointer(*proxy, event);
    proxy->owner->send(proxy->tile.id, vf::InputKind::button, 272 + static_cast<int>(event.buttonNumber), down);
}
- (void)mouseDown:(NSEvent*)event {
    if (!proxy) return;
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        proxy->owner->send(proxy->tile.id, vf::InputKind::release);
        proxy->dragging = true; [self.window performWindowDragWithEvent:event]; proxy->dragging = false;
        proxy->owner->geometry(*proxy); return;
    }
    [self button:event down:YES];
}
- (void)mouseUp:(NSEvent*)event { [self button:event down:NO]; }
- (void)rightMouseDown:(NSEvent*)event { [self button:event down:YES]; }
- (void)rightMouseUp:(NSEvent*)event { [self button:event down:NO]; }
- (void)otherMouseDown:(NSEvent*)event { [self button:event down:YES]; }
- (void)otherMouseUp:(NSEvent*)event { [self button:event down:NO]; }
- (void)scrollWheel:(NSEvent*)event {
    if (!proxy) return; proxy->owner->pointer(*proxy, event);
    const double multiplier = event.hasPreciseScrollingDeltas ? 3 : 120;
    const auto vertical = static_cast<int>(std::lround(event.scrollingDeltaY * multiplier));
    const auto horizontal = static_cast<int>(std::lround(-event.scrollingDeltaX * multiplier));
    if (vertical) proxy->owner->send(proxy->tile.id, vf::InputKind::wheel, 0, vertical);
    if (horizontal) proxy->owner->send(proxy->tile.id, vf::InputKind::wheel, 1, horizontal);
}
- (void)keyDown:(NSEvent*)event {
    if (!proxy) return;
    if (const auto key = vm::evdev_key(event.keyCode)) proxy->owner->send(proxy->tile.id, vf::InputKind::key, static_cast<int>(*key), event.isARepeat ? 2 : 1);
}
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    if (self.window.isKeyWindow && event.type == NSEventTypeKeyDown) { [self keyDown:event]; return YES; }
    return NO;
}
- (void)keyUp:(NSEvent*)event {
    if (!proxy) return;
    if (const auto key = vm::evdev_key(event.keyCode)) proxy->owner->send(proxy->tile.id, vf::InputKind::key, static_cast<int>(*key), 0);
}
- (void)flagsChanged:(NSEvent*)event {
    if (!proxy) return;
    const auto key = vm::evdev_key(event.keyCode); if (!key) return;
    if (*key == 58) {
        proxy->owner->send(proxy->tile.id, vf::InputKind::key, 58, 1);
        proxy->owner->send(proxy->tile.id, vf::InputKind::key, 58, 0); return;
    }
    unsigned mask = 0;
    switch (event.keyCode) { case 56: mask=0x02; break; case 60: mask=0x04; break;
        case 59: mask=0x01; break; case 62: mask=0x2000; break; case 58: mask=0x20; break;
        case 61: mask=0x40; break; case 55: mask=0x08; break; case 54: mask=0x10; break; default: return; }
    const bool down = (event.modifierFlags & mask) != 0;
    if (down == proxy->modifiers.contains(*key)) return;
    if (down) proxy->modifiers.insert(*key); else proxy->modifiers.erase(*key);
    proxy->owner->send(proxy->tile.id, vf::InputKind::key, static_cast<int>(*key), down);
}
- (void)windowDidResignKey:(NSNotification*)notification {
    (void)notification;
    if (proxy) { proxy->modifiers.clear(); proxy->owner->send(proxy->tile.id, vf::InputKind::release); }
}
- (void)windowDidBecomeKey:(NSNotification*)notification {
    (void)notification; if (proxy) proxy->owner->send(proxy->tile.id, vf::InputKind::focus);
}
- (void)windowDidMove:(NSNotification*)notification {
    (void)notification; if (proxy) proxy->owner->geometry(*proxy);
}
- (BOOL)windowShouldClose:(NSWindow*)sender {
    (void)sender; if (proxy) proxy->owner->send(proxy->tile.id, vf::InputKind::close); return NO;
}
@end
namespace viewflow::macos {
int run_presenter(const Options& options) {
    if (options.validate) {
        Decoder decoder; unsigned count = 0; std::vector<uint8_t> bytes;
        while (vf::read_record(STDIN_FILENO, bytes)) {
            const auto frame = vf::unpack_frame(bytes);
            const auto alpha = vf::decode_alpha(frame.alpha, static_cast<size_t>(frame.width) * frame.height);
            CVPixelBufferRef buffer = decoder.decode(frame);
            if (!buffer) throw std::runtime_error("validation decoded no image for access unit");
            CVPixelBufferRelease(buffer);
            std::fprintf(stderr, "macos-window-validated frame=%u width=%u height=%u tiles=%zu alpha=%zu\n", ++count, frame.width, frame.height, frame.tiles.size(), alpha.size());
        }
        if (!count) throw std::runtime_error("validation received no frames");
        return 0;
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    Presenter presenter(options); Presenter* owner = &presenter;
    auto decoder = std::make_unique<Decoder>();
    std::atomic<bool> input_ended{false};
    Input input([&](std::vector<uint8_t> bytes) {
        @autoreleasepool {
            const auto frame = vf::unpack_frame(bytes);
            CVPixelBufferRef buffer = nullptr;
            try { buffer = decoder->decode(frame); }
            catch (const std::exception& error) {
                std::fprintf(stderr, "window decode recovering: %s\n", error.what());
                decoder = std::make_unique<Decoder>(); return;
            }
            if (!buffer) return;
            dispatch_sync(dispatch_get_main_queue(), ^{
                if (!owner->quitting) {
                    try { owner->present(frame, buffer); }
                    catch (const std::exception& error) { std::fprintf(stderr, "window presentation recovering: %s\n", error.what()); }
                }
            });
            CVPixelBufferRelease(buffer);
        }
    }, [&] { input_ended = true; });
    while (!input_ended && presenter.output.alive()) {
        @autoreleasepool {
            NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                inMode:NSDefaultRunLoopMode dequeue:YES];
            if (event) [NSApp sendEvent:event];
            for (auto& [_, proxy] : presenter.windows) presenter.draw(*proxy);
        }
    }
    presenter.quitting = true; input.stop();
    while (!input.finished() || presenter.outstanding != 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return 0;
}
}

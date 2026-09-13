#include "window_native.hpp"
#include "window_codec.hpp"
#include "window_io.hpp"
#include "window_keys.hpp"
#include "window_pixels.hpp"
#include "window_shortcut_policy.hpp"
#include "window_background.hpp"
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include <pthread/qos.h>
#include <cmath>
#include <chrono>
#include <algorithm>
#include <map>
#include <set>

namespace vf = viewflow::reverse;
namespace vm = viewflow::macos;
namespace { struct Presenter; struct Proxy; }
// Visual children must leave native input targeting on the proxy root.
@interface VFPassiveSurface : NSView
@end
@implementation VFPassiveSurface
- (NSView*)hitTest:(NSPoint)point { (void)point; return nil; }
@end
@interface VFProxyWindow : NSWindow
@end
@interface VFProxyView : NSView <NSWindowDelegate> {
@public Proxy* proxy;
}
@end
namespace {
struct DecodedAlpha {
    unsigned width{}, height{};
    uint64_t revision{};
    std::vector<uint8_t> encoded;
    std::shared_ptr<const std::vector<uint8_t>> pixels;
    CIImage* __strong mask = nil;
    void update(const vf::Frame& frame) {
        if (mask && width == frame.width && height == frame.height && encoded == frame.alpha) return;
        auto next_pixels = std::make_shared<const std::vector<uint8_t>>(
            vf::decode_alpha(frame.alpha, static_cast<size_t>(frame.width) * frame.height));
        CIImage* next_mask = vm::make_alpha_mask(frame.width, frame.height, next_pixels);
        auto next_encoded = frame.alpha;
        // Commit only after every potentially failing allocation has succeeded.
        encoded.swap(next_encoded); pixels = std::move(next_pixels); mask = next_mask;
        width = frame.width; height = frame.height; ++revision;
    }
};
struct Proxy {
    Presenter* owner{};
    vf::Tile tile;
    VFProxyWindow* __strong window = nil;
    VFProxyView* __strong view = nil;
    CAMetalLayer* __strong layer = nil;
    std::unique_ptr<vm::WindowBackground> background;
    bool translucent{};
    uint64_t background_revision{};
    bool evidence_written{};
    std::chrono::steady_clock::time_point last_video{};
    uint64_t alpha_revision{};
    unsigned alpha_x{}, alpha_y{}, alpha_width{}, alpha_height{};
    CIImage* __strong image = nil;
    bool applying{}, drawing{}, dragging{}, needs_draw{}, video_pending{};
    bool fullscreen_transition{}, fullscreen_remote{};
    bool source_raise_known{}, source_raised{};
    uint64_t fullscreen_pending{};
    NSPoint drag_offset{};
    uint64_t geometry_pending{}, generation{};
    std::set<unsigned> modifiers;
    std::set<unsigned> keys;
    ~Proxy();
};
struct Presenter {
    vm::Options options;
    vm::Output output{4096};
    id<MTLDevice> __strong device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> __strong commands;
    dispatch_queue_t render_queue = dispatch_queue_create("org.viewflow.window-render", DISPATCH_QUEUE_SERIAL);
    CIContext* __strong context;
    CGColorSpaceRef color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    std::map<uint64_t, std::unique_ptr<Proxy>> windows;
    uint64_t sequence{}, presented{}, coalesced_draws{}, last_drawn{}, next_generation{};
    unsigned outstanding{};
    std::chrono::steady_clock::time_point statistics_start = std::chrono::steady_clock::now();
    uint64_t statistics_frames{};
    double statistics_gpu_ms{};
    bool quitting{}, recovery_release{};
    vm::ShortcutPolicy shortcut_policy;
    explicit Presenter(const vm::Options& config) : options(config) {
        if (!device) throw std::runtime_error("Metal device unavailable");
        commands = [device newCommandQueueWithMaxCommandBufferCount:
            config.performance_mode == vm::PerformanceMode::latency ? 1 : 3];
        context = [CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace: (__bridge id)color_space}];
        for (const auto& rule : config.linux_shortcuts) shortcut_policy.add(rule);
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
        (void)event;
        if(proxy.window.styleMask & NSWindowStyleMaskFullScreen) {
            const auto point=[proxy.view convertPoint:event.locationInWindow fromView:nil];
            const auto size=proxy.view.bounds.size;
            if(size.width<=0 || size.height<=0)return;
            send(proxy.tile.id,vf::InputKind::pointer,
                int(std::lround(proxy.tile.x+point.x*proxy.tile.width/size.width)),
                int(std::lround(proxy.tile.y+point.y*proxy.tile.height/size.height)),1);
            return;
        }
        // Send desktop coordinates, independent of delayed video/window moves.
        const auto point = NSEvent.mouseLocation;
        const double desktop_top = NSScreen.screens.firstObject.frame.size.height;
        send(proxy.tile.id, vf::InputKind::pointer,
            static_cast<int>(std::lround((point.x-options.origin_x)*options.scale)),
            static_cast<int>(std::lround((desktop_top-point.y-options.origin_y)*options.scale)),1);
    }
    void geometry(Proxy& proxy) {
        proxy.needs_draw = true;
        if (proxy.applying || quitting || proxy.fullscreen_transition || (proxy.window.styleMask & NSWindowStyleMaskFullScreen)) return;
        const auto rect = proxy.window.frame;
        const double desktop_top = NSScreen.screens.firstObject.frame.size.height;
        proxy.geometry_pending = send(proxy.tile.id, vf::InputKind::geometry,
            static_cast<int>(std::lround((rect.origin.x - options.origin_x) * options.scale)),
            static_cast<int>(std::lround((desktop_top - NSMaxY(rect) - options.origin_y) * options.scale)),
            static_cast<int>(std::lround(rect.size.width * options.scale)),
            static_cast<int>(std::lround(rect.size.height * options.scale)));
    }
    void draw(Proxy& proxy) {
        if (proxy.background) {
            proxy.background->request(proxy.window, proxy.translucent);
        }
        if(proxy.drawing)return;
        uint64_t background_revision = 0;
        CIImage* background_image = proxy.translucent && proxy.background ?
            proxy.background->image(proxy.window, background_revision) : nil;
        // When video is arriving, incorporate background changes in its next
        // draw. An extra background-only drawable would otherwise consume the
        // display slot of a new video frame. Static/paused video still redraws
        // independently at the background cadence; this is not a validity cutoff.
        if (background_revision != proxy.background_revision && (proxy.video_pending ||
            std::chrono::steady_clock::now()-proxy.last_video>=std::chrono::milliseconds(33)))proxy.needs_draw=true;
        if (!proxy.image || proxy.drawing || !proxy.needs_draw) return;
        // The queue limit belongs to the presenter, not to each window. Never
        // block AppKit waiting for another window's GPU command to retire.
        const unsigned limit = options.performance_mode == vm::PerformanceMode::latency ? 1u : 3u;
        if (outstanding >= limit) return;
        const auto scale = proxy.window.backingScaleFactor;
        const auto bounds = proxy.view.bounds;
        if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
        proxy.layer.contentsScale = scale;
        proxy.layer.drawableSize = CGSizeMake(std::ceil(bounds.size.width * scale), std::ceil(bounds.size.height * scale));
        // Drawable acquisition may wait for WindowServer even after GPU work
        // completed. Keep that wait and Core Image encoding off the input loop.
        CAMetalLayer* layer = proxy.layer;
        CIImage* source_image = proxy.image;
        const auto drawable_size = proxy.layer.drawableSize;
        const auto window_id = proxy.tile.id;
        const auto generation = proxy.generation;
        NSString* evidence_directory=nil;
        if(background_image&&!proxy.evidence_written&&!options.evidence_dir.empty()) {
            proxy.evidence_written=true;
            evidence_directory=@(options.evidence_dir.c_str());
        }
        Presenter* owner = this;
        proxy.drawing = true; proxy.needs_draw = false; proxy.video_pending = false; ++outstanding;
        proxy.background_revision=background_revision;
        dispatch_async(render_queue, ^{
        @autoreleasepool {
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable) {
            dispatch_async(dispatch_get_main_queue(), ^{
                --owner->outstanding;
                auto it = owner->windows.find(window_id);
                if (it != owner->windows.end() && it->second->generation == generation) {
                    it->second->drawing = false; it->second->needs_draw = true;
                }
            });
            return;
        }
        id<MTLCommandBuffer> command = [owner->commands commandBuffer];
        const auto extent = source_image.extent;
        CIImage* rendered = [source_image imageByApplyingTransform:CGAffineTransformMakeScale(
            drawable_size.width / extent.size.width, drawable_size.height / extent.size.height)];
        if (background_image) {
            // Same SOURCE_IN coverage and foreground-over composition as the
            // Windows sparse compositor: added background coverage is a*(1-a).
            // Reuse the foreground GPU alpha; no CPU mask or second upload.
            CIImage* covered = [background_image imageByApplyingFilter:@"CISourceInCompositing"
                withInputParameters:@{kCIInputBackgroundImageKey:rendered}];
            rendered = [rendered imageByCompositingOverImage:covered];
        }
        if(evidence_directory) {
            CIContext* evidence_context=owner->context;
            CIImage* evidence_foreground=[source_image imageByApplyingTransform:CGAffineTransformMakeScale(
                drawable_size.width / extent.size.width,drawable_size.height / extent.size.height)];
            CIImage* evidence_composed=rendered;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
                @autoreleasepool {
                    NSError* error=nil;
                    [[NSFileManager defaultManager] createDirectoryAtPath:evidence_directory withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions:@0700} error:&error];
                    NSArray<CIImage*>* images=@[evidence_foreground,background_image,evidence_composed];
                    NSArray<NSString*>* names=@[@"foreground",@"background",@"composed"];
                    CGColorSpaceRef colors=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                    for(unsigned i=0;i<3;++i) {
                        NSString* filename=[NSString stringWithFormat:@"%d-%llu-%@.png",getpid(),(unsigned long long)window_id,names[i]];
                        NSURL* url=[NSURL fileURLWithPath:[evidence_directory stringByAppendingPathComponent:filename]];
                        CIImage* image=[images[i] imageByCroppingToRect:CGRectMake(0,0,drawable_size.width,drawable_size.height)];
                        if(![evidence_context writePNGRepresentationOfImage:image toURL:url format:kCIFormatRGBA8 colorSpace:colors options:@{} error:&error])
                            std::fprintf(stderr,"background evidence export: %s\n",error.localizedDescription.UTF8String);
                    }
                    CGColorSpaceRelease(colors);
                }
            });
        }
        [owner->context render:rendered toMTLTexture:drawable.texture commandBuffer:command
            bounds:CGRectMake(0, 0, drawable_size.width, drawable_size.height) colorSpace:owner->color_space];
        [command presentDrawable:drawable];
        __block CIImage* retained = rendered;
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            retained = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                --owner->outstanding;
                auto it = owner->windows.find(window_id);
                if (it != owner->windows.end() && it->second->generation == generation) it->second->drawing = false;
                if (completed.status == MTLCommandBufferStatusError)
                    std::fprintf(stderr, "window Metal submission failed: %s\n", completed.error.localizedDescription.UTF8String);
                else {
                    ++owner->presented;
                    ++owner->statistics_frames;
                    owner->statistics_gpu_ms += std::max(0.0, completed.GPUEndTime - completed.GPUStartTime) * 1000.0;
                    const auto now = std::chrono::steady_clock::now();
                    const double seconds = std::chrono::duration<double>(now - owner->statistics_start).count();
                    if (seconds >= 5.0) {
                        std::fprintf(stderr, "macos-window-render-stats seconds=%.3f completions=%llu completions-per-second=%.2f gpu-mean-ms=%.3f superseded-total=%llu\n",
                            seconds, static_cast<unsigned long long>(owner->statistics_frames),
                            owner->statistics_frames / seconds, owner->statistics_gpu_ms / owner->statistics_frames,
                            static_cast<unsigned long long>(owner->coalesced_draws));
                        owner->statistics_start = now; owner->statistics_frames = 0; owner->statistics_gpu_ms = 0;
                    }
                }
                if (owner->presented == 1 || owner->presented % 120 == 0)
                    std::fprintf(stderr, "macos-window-presented frame=%llu window=%llu windows=%zu coalesced=%llu\n",
                        static_cast<unsigned long long>(owner->presented),
                        static_cast<unsigned long long>(window_id), owner->windows.size(),
                        static_cast<unsigned long long>(owner->coalesced_draws));
                if (!owner->quitting) {
                    try { owner->draw_pending(); }
                    catch (const std::exception& error) { std::fprintf(stderr, "window draw retry: %s\n", error.what()); }
                }
            });
        }];
        [command commit];
        }
        });
        last_drawn = window_id;
    }
    void draw_pending() {
        if (windows.empty()) return;
        auto it = windows.upper_bound(last_drawn);
        for (size_t remaining = windows.size(); remaining; --remaining) {
            if (it == windows.end()) it = windows.begin();
            draw(*it->second); ++it;
        }
    }
    void update_backdrop(Proxy& proxy, const vf::Frame& frame, std::span<const uint8_t> alpha, uint64_t revision = 0) {
        const auto& tile = proxy.tile;
        if (revision && revision == proxy.alpha_revision && proxy.alpha_x == tile.atlas_x &&
            proxy.alpha_y == tile.atlas_y && proxy.alpha_width == tile.width && proxy.alpha_height == tile.height) return;
        const auto remember = [&] {
            proxy.alpha_revision = revision; proxy.alpha_x = tile.atlas_x; proxy.alpha_y = tile.atlas_y;
            proxy.alpha_width = tile.width; proxy.alpha_height = tile.height;
        };
        bool translucent = false;
        for (unsigned y = 0; y < tile.height; ++y) {
            const auto row = alpha.subspan(static_cast<size_t>(tile.atlas_y + y) * frame.width + tile.atlas_x, tile.width);
            if (!translucent)
                translucent = std::any_of(row.begin(), row.end(), [](uint8_t a) { return a > 0 && a < 255; });
        }
        proxy.translucent = translucent; remember();
    }
    void present(const vf::Frame& frame, CIImage* composed, std::span<const uint8_t> alpha, uint64_t revision,
        const std::optional<vf::BlurRecipe>& blur_recipe) {
        std::set<uint64_t> live;
        for (const auto& tile : frame.tiles) {
            live.insert(tile.id);
            auto& entry = windows[tile.id];
            if (!entry) {
                entry = std::make_unique<Proxy>(); auto& proxy = *entry;
                proxy.owner = this; proxy.tile = tile; proxy.generation = ++next_generation;
                proxy.window = [[VFProxyWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1, 1)
                    styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
                proxy.window.releasedWhenClosed = NO;
                proxy.window.opaque = NO; proxy.window.backgroundColor = NSColor.clearColor;
                proxy.window.hasShadow = NO; proxy.window.acceptsMouseMovedEvents = YES;
                proxy.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
                proxy.window.title = [[NSString alloc] initWithBytes:tile.title.data() length:tile.title.size() encoding:NSUTF8StringEncoding] ?: @"Shared window";
                proxy.view = [[VFProxyView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)]; proxy.view->proxy = &proxy;
                proxy.layer = [CAMetalLayer layer]; proxy.layer.device = device;
                proxy.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
                proxy.layer.framebufferOnly = NO; proxy.layer.opaque = NO;
                proxy.layer.maximumDrawableCount = options.performance_mode == vm::PerformanceMode::latency ? 2 : 3;
                proxy.layer.allowsNextDrawableTimeout = YES;
                proxy.layer.presentsWithTransaction = NO;
                proxy.view.wantsLayer = YES;
                proxy.background = std::make_unique<vm::WindowBackground>(device);
                VFPassiveSurface* surface = [[VFPassiveSurface alloc] initWithFrame:proxy.view.bounds];
                surface.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                surface.wantsLayer = YES; surface.layer = proxy.layer;
                [proxy.view addSubview:surface];
                proxy.window.contentView = proxy.view; proxy.window.delegate = proxy.view;
                [proxy.window makeFirstResponder:proxy.view];
            }
            auto& proxy = *entry; proxy.tile = tile;
            proxy.background->configure(blur_recipe);
            const double desktop_top = NSScreen.screens.firstObject.frame.size.height;
            const auto rect = NSMakeRect(options.origin_x + tile.x / options.scale,
                desktop_top - options.origin_y - (tile.y + double(tile.height)) / options.scale,
                tile.width / options.scale, tile.height / options.scale);
            if (!proxy.fullscreen_transition && !proxy.fullscreen_pending && !(proxy.window.styleMask & NSWindowStyleMaskFullScreen) && !proxy.dragging && (!proxy.geometry_pending || tile.geometry_ack >= proxy.geometry_pending)) {
                proxy.geometry_pending = 0; proxy.applying = true;
                if (!NSEqualRects(proxy.window.frame, rect)) [proxy.window setFrame:rect display:NO];
                proxy.applying = false;
                // AppKit can constrain a restored/moved window to the current
                // display's visible frame. Acknowledge that real placement:
                // otherwise global pointer coordinates target an invisible,
                // stale source title bar (especially after display rearrange).
                if (!NSEqualRects(proxy.window.frame, rect)) {
                    std::fprintf(stderr,"macos-window-placement constrained id=%llu requested=%.1f,%.1f actual=%.1f,%.1f\n",
                        static_cast<unsigned long long>(tile.id),rect.origin.x,rect.origin.y,
                        proxy.window.frame.origin.x,proxy.window.frame.origin.y);
                    geometry(proxy);
                }
            }
            update_backdrop(proxy, frame, alpha, revision);
            const auto crop = CGRectMake(tile.atlas_x, frame.height - tile.atlas_y - tile.height, tile.width, tile.height);
            // A submitted frame is still rendered. Count only an unsubmitted image replaced here.
            if (proxy.video_pending) ++coalesced_draws;
            proxy.image = [[composed imageByCroppingToRect:crop] imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x, -crop.origin.y)];
            proxy.needs_draw = true; proxy.video_pending = true;
            proxy.last_video=std::chrono::steady_clock::now();
            if (!proxy.window.isVisible) [proxy.window orderFront:nil]; // No activation or key-window change.
            const bool source_raised=(tile.flags&64)!=0;
            if(proxy.source_raise_known && source_raised && !proxy.source_raised && !proxy.fullscreen_transition)
                [proxy.window orderFront:nil]; // Raise this proxy only, never the application group.
            proxy.source_raise_known=true;proxy.source_raised=source_raised;
            if (!proxy.fullscreen_transition && (!proxy.fullscreen_pending ||
                (tile.geometry_ack>=proxy.fullscreen_pending && bool(tile.flags&32)==bool(proxy.window.styleMask & NSWindowStyleMaskFullScreen)))) {
                proxy.fullscreen_pending=0;
                const bool desired=(tile.flags&32)!=0;
                if(desired!=bool(proxy.window.styleMask & NSWindowStyleMaskFullScreen)) {
                    proxy.fullscreen_remote=true;proxy.fullscreen_transition=true;
                    // Resizable is required for AppKit's native fullscreen Space.
                    proxy.window.styleMask |= NSWindowStyleMaskResizable;
                    [proxy.window toggleFullScreen:nil];
                }
            }
        }
        for (auto it = windows.begin(); it != windows.end();) {
            if (!live.contains(it->first)) { send(it->first, vf::InputKind::release); it = windows.erase(it); }
            else ++it;
        }
        draw_pending();
    }
};
Proxy::~Proxy() { window.delegate = nil; if (view) view->proxy = nullptr; [window close]; }
}
@implementation VFProxyWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    if (self.isKeyWindow && [self.contentView isKindOfClass:VFProxyView.class]) {
        VFProxyView* view = (VFProxyView*)self.contentView;
        if (view->proxy && event.type == NSEventTypeKeyDown) {
            NSString* chars = event.charactersIgnoringModifiers.lowercaseString;
            const std::string key = chars.length ? std::string(chars.UTF8String) : std::string{};
            const auto flags = static_cast<unsigned long long>(event.modifierFlags);
            const unsigned modifiers =
                ((flags & NSEventModifierFlagControl) ? vm::shortcut_control : 0) |
                ((flags & NSEventModifierFlagOption) ? vm::shortcut_option : 0) |
                ((flags & NSEventModifierFlagShift) ? vm::shortcut_shift : 0) |
                ((flags & NSEventModifierFlagCommand) ? vm::shortcut_command : 0);
            if (view->proxy->owner->shortcut_policy.linux_first(modifiers, key)) {
                [view keyDown:event]; return YES;
            }
            // Give the menu/responder chain the first chance. Only an
            // unhandled shortcut falls through to the remote Linux app.
            if ([super performKeyEquivalent:event]) {
                view->proxy->owner->send(view->proxy->tile.id, vf::InputKind::release);
                view->proxy->modifiers.clear();
                view->proxy->keys.clear();
                return YES;
            }
            [view keyDown:event]; return YES;
        }
    }
    return [super performKeyEquivalent:event];
}
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
- (void)mouseDragged:(NSEvent*)event {
    if (proxy && proxy->dragging) {
        // Queued events contain coordinates relative to an earlier window
        // origin. Adding today's origin feeds our own move back into the drag.
        const auto point = NSEvent.mouseLocation;
        [self.window setFrameOrigin:NSMakePoint(point.x - proxy->drag_offset.x, point.y - proxy->drag_offset.y)];
        proxy->owner->geometry(*proxy);
        return;
    }
    [self mouseMoved:event];
}
- (void)rightMouseDragged:(NSEvent*)event { [self mouseMoved:event]; }
- (void)otherMouseDragged:(NSEvent*)event { [self mouseMoved:event]; }
- (void)button:(NSEvent*)event down:(BOOL)down {
    if (!proxy || event.buttonNumber > 4) return;
    if (down) {
        [self.window makeKeyAndOrderFront:nil];
        [self.window makeFirstResponder:self];
    }
    proxy->owner->pointer(*proxy, event);
    proxy->owner->send(proxy->tile.id, vf::InputKind::button, 272 + static_cast<int>(event.buttonNumber), down);
}
- (void)mouseDown:(NSEvent*)event {
    if (!proxy) return;
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self];
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        proxy->owner->send(proxy->tile.id, vf::InputKind::release);
        // Track AppKit events directly so posted cross-desktop input follows
        // the same drag path as a local device without a WindowServer drag loop.
        const auto point = NSEvent.mouseLocation;
        proxy->drag_offset = NSMakePoint(point.x-self.window.frame.origin.x,
                                        point.y-self.window.frame.origin.y);
        proxy->dragging = true;
        proxy->modifiers.clear();
        proxy->keys.clear();
        proxy->owner->geometry(*proxy); return;
    }
    [self button:event down:YES];
}
- (void)mouseUp:(NSEvent*)event {
    if (proxy && proxy->dragging) {
        proxy->dragging = false;
        proxy->owner->geometry(*proxy);
        return;
    }
    [self button:event down:NO];
}
- (void)rightMouseDown:(NSEvent*)event { [self button:event down:YES]; }
- (void)rightMouseUp:(NSEvent*)event { [self button:event down:NO]; }
- (void)otherMouseDown:(NSEvent*)event { [self button:event down:YES]; }
- (void)otherMouseUp:(NSEvent*)event { [self button:event down:NO]; }
- (void)scrollWheel:(NSEvent*)event {
    std::fprintf(stderr,"macos-scroll entry window=%llu dx=%.4f dy=%.4f precise=%d phase=%lu momentum=%lu\n",
        proxy?static_cast<unsigned long long>(proxy->tile.id):0,event.scrollingDeltaX,event.scrollingDeltaY,
        int(event.hasPreciseScrollingDeltas),static_cast<unsigned long>(event.phase),static_cast<unsigned long>(event.momentumPhase));
    if (!proxy) return; proxy->owner->pointer(*proxy, event);
    const bool precise = event.hasPreciseScrollingDeltas;
    // Precise deltas are points, carried as milli-points independently of
    // wheel detents. Both AppKit axes have the opposite Wayland sign.
    const double multiplier = precise ? 1000 : 120;
    const auto vertical = static_cast<int>(std::lround(event.scrollingDeltaY * multiplier));
    const auto horizontal = static_cast<int>(std::lround(event.scrollingDeltaX * multiplier));
    const bool ended = precise && ((event.phase | event.momentumPhase) & (NSEventPhaseEnded | NSEventPhaseCancelled));
    if (vertical || ended) {auto seq=proxy->owner->send(proxy->tile.id, vf::InputKind::wheel, 0, vertical, precise, ended);
        std::fprintf(stderr,"macos-scroll queued seq=%llu axis=0 amount=%d\n",static_cast<unsigned long long>(seq),vertical);}
    if (horizontal || ended) {auto seq=proxy->owner->send(proxy->tile.id, vf::InputKind::wheel, 1, horizontal, precise, ended);
        std::fprintf(stderr,"macos-scroll queued seq=%llu axis=1 amount=%d\n",static_cast<unsigned long long>(seq),horizontal);}
}
- (void)keyDown:(NSEvent*)event {
    if (!proxy || !self.window.isKeyWindow || !self.window.isVisible) return;
    if (const auto key = vm::evdev_key(event.keyCode)) {
        proxy->keys.insert(event.keyCode);
        proxy->owner->send(proxy->tile.id, vf::InputKind::key, static_cast<int>(*key), event.isARepeat ? 2 : 1);
    }
}
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    (void)event;
    return NO;
}
- (void)keyUp:(NSEvent*)event {
    if (!proxy) return;
    if (!proxy->keys.erase(event.keyCode)) return;
    if (const auto key = vm::evdev_key(event.keyCode)) proxy->owner->send(proxy->tile.id, vf::InputKind::key, static_cast<int>(*key), 0);
}
- (void)flagsChanged:(NSEvent*)event {
    if (!proxy || !self.window.isKeyWindow || !self.window.isVisible) return;
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
    if (proxy) {
        proxy->modifiers.clear();
        proxy->keys.clear();
        proxy->dragging = false;
        proxy->owner->send(proxy->tile.id, vf::InputKind::release);
    }
}
- (void)windowDidBecomeKey:(NSNotification*)notification {
    (void)notification; if (proxy) proxy->owner->send(proxy->tile.id, vf::InputKind::focus);
}
- (void)windowDidMove:(NSNotification*)notification {
    (void)notification; if (proxy) proxy->owner->geometry(*proxy);
}
- (void)windowWillEnterFullScreen:(NSNotification*)notification { (void)notification;if(proxy)proxy->fullscreen_transition=true; }
- (void)windowWillExitFullScreen:(NSNotification*)notification { (void)notification;if(proxy)proxy->fullscreen_transition=true; }
- (void)windowDidEnterFullScreen:(NSNotification*)notification {
    (void)notification;if(!proxy)return;
    proxy->fullscreen_transition=false;
    if(!proxy->fullscreen_remote)proxy->fullscreen_pending=proxy->owner->send(proxy->tile.id,static_cast<vf::InputKind>(15),1);
    proxy->fullscreen_remote=false;
}
- (void)windowDidExitFullScreen:(NSNotification*)notification {
    (void)notification;if(!proxy)return;
    proxy->fullscreen_transition=false;
    if(!proxy->fullscreen_remote)proxy->fullscreen_pending=proxy->owner->send(proxy->tile.id,static_cast<vf::InputKind>(15),0);
    proxy->fullscreen_remote=false;
}
- (void)windowDidFailToEnterFullScreen:(NSWindow*)window { (void)window;if(proxy){proxy->fullscreen_transition=false;proxy->fullscreen_remote=false;} }
- (void)windowDidFailToExitFullScreen:(NSWindow*)window { (void)window;if(proxy){proxy->fullscreen_transition=false;proxy->fullscreen_remote=false;} }
- (BOOL)windowShouldClose:(NSWindow*)sender {
    (void)sender; if (proxy) proxy->owner->send(proxy->tile.id, vf::InputKind::close); return NO;
}
@end
namespace viewflow::macos {
void presenter_self_test() {
    [NSApplication sharedApplication];
    Options options;
    Presenter presenter(options);
    Proxy proxy;
    proxy.tile.id = 1; proxy.tile.width = 2; proxy.tile.height = 2;
    proxy.tile.atlas_x = 1; proxy.tile.atlas_y = 1;
    vf::Frame frame; frame.width = 4; frame.height = 4;
    std::vector<uint8_t> alpha(16, 255);
    alpha[5] = 0; alpha[6] = 64; alpha[9] = 128;
    presenter.update_backdrop(proxy, frame, alpha);
    if (!proxy.translucent) throw std::runtime_error("translucent crop not detected");
    std::fill(alpha.begin(), alpha.end(), 255); presenter.update_backdrop(proxy, frame, alpha);
    if (proxy.translucent) throw std::runtime_error("opaque tile retained backdrop work");
    std::fill(alpha.begin(), alpha.end(), 0); presenter.update_backdrop(proxy, frame, alpha);
    if (proxy.translucent) throw std::runtime_error("transparent tile retained backdrop work");
    DecodedAlpha cache;
    alpha[0] = 96; frame.alpha = vf::encode_alpha(alpha); cache.update(frame);
    CIImage* cached_mask = cache.mask;
    const auto cached_pixels = cache.pixels.get();
    const auto revision = cache.revision;
    cache.update(frame);
    if (cache.mask != cached_mask || cache.pixels.get() != cached_pixels || cache.revision != revision)
        throw std::runtime_error("unchanged alpha was decoded or uploaded again");
    presenter.update_backdrop(proxy, frame, *cache.pixels, cache.revision);
    if (proxy.translucent) throw std::runtime_error("empty crop unexpectedly enabled blur");
    proxy.tile.atlas_x = proxy.tile.atlas_y = 0;
    presenter.update_backdrop(proxy, frame, *cache.pixels, cache.revision);
    if (!proxy.translucent) throw std::runtime_error("same-alpha crop change failed to enable blur");
    alpha[0] = 0; frame.alpha = vf::encode_alpha(alpha); cache.update(frame);
    if (cache.revision == revision || cache.mask == cached_mask)
        throw std::runtime_error("changed alpha retained stale GPU mask");
    presenter.update_backdrop(proxy, frame, *cache.pixels, cache.revision);
    if (proxy.translucent) throw std::runtime_error("changed alpha retained stale backdrop");
    frame.width = 8; frame.height = 2; cache.update(frame);
    if (cache.mask.extent.size.width != 8 || cache.mask.extent.size.height != 2)
        throw std::runtime_error("equal-area resize retained stale alpha geometry");
    VFPassiveSurface* surface = [[VFPassiveSurface alloc] initWithFrame:NSMakeRect(0, 0, 2, 2)];
    if ([surface hitTest:NSMakePoint(1, 1)] != nil)
        throw std::runtime_error("Metal surface intercepted proxy input");
    frame.width = proxy.tile.width = 2560;
    frame.height = proxy.tile.height = 1440;
    alpha.assign(static_cast<size_t>(frame.width) * frame.height, 128);
    const auto mask_start = std::chrono::steady_clock::now();
    for (unsigned pass = 0; pass < 4; ++pass) {
        alpha.back() = static_cast<uint8_t>(64 + pass);
        presenter.update_backdrop(proxy, frame, alpha);
        if (!proxy.translucent) throw std::runtime_error("large translucent crop skipped");
    }
    std::fprintf(stderr, "macos-backdrop-benchmark pixels=2560x1440 updates=4 mean-ms=%.3f\n",
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - mask_start).count() / 4);
    std::fprintf(stderr, "macos-presenter self-test passed: cropped alpha, decoded/GPU mask cache, crop/resize invalidation, opaque/empty skip, passive hit testing; no windows or input\n");
    background_self_test(presenter.device);
}
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
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    std::fprintf(stderr, "macos-window-presenter performance-mode=%s drawables=%u command-buffers=%u qos=user-interactive\n",
        options.performance_mode == PerformanceMode::latency ? "latency" : "frame-rate",
        options.performance_mode == PerformanceMode::latency ? 2u : 3u,
        options.performance_mode == PerformanceMode::latency ? 1u : 3u);
    Presenter presenter(options); Presenter* owner = &presenter;
    auto decoder = std::make_unique<Decoder>();
    DecodedAlpha alpha_cache;
    std::atomic<bool> input_ended{false};
    // These counters belong only to the serial input worker. GPU/scanout time
    // is deliberately separate from CPU decode, reconstruction and AppKit work.
    auto receive_stats_start = std::chrono::steady_clock::now();
    uint64_t receive_stats_count = 0;
    double decode_ms = 0, reconstruction_ms = 0, main_wait_ms = 0, presentation_ms = 0;
    Input input([&](std::vector<uint8_t> bytes) {
        @autoreleasepool {
            const auto frame = vf::unpack_frame(bytes);
            const auto blur_recipe = vf::blur_recipe_from_annex_b(frame.color, frame.codec);
            CVPixelBufferRef buffer = nullptr;
            const auto decode_start = std::chrono::steady_clock::now();
            try { buffer = decoder->decode(frame); }
            catch (const std::exception& error) {
                std::fprintf(stderr, "window decode recovering: %s\n", error.what());
                decoder = std::make_unique<Decoder>(); return;
            }
            if (!buffer) return;
            const auto decoded_at = std::chrono::steady_clock::now();
            try {
                alpha_cache.update(frame);
                CIImage* composed = vm::join_planes(buffer, alpha_cache.mask);
                const auto alpha_revision = alpha_cache.revision;
                // Synchronous handoff keeps these references alive without copying
                // the compressed frame and decoded alpha into an Objective-C block.
                const vf::Frame* frame_ptr = &frame;
                const std::span<const uint8_t> alpha_view(*alpha_cache.pixels);
                const auto prepared_at = std::chrono::steady_clock::now();
                auto main_started = prepared_at;
                auto* main_started_ptr = &main_started;
                const auto handoff = dispatch_semaphore_create(0);
                CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
                    *main_started_ptr = std::chrono::steady_clock::now();
                    if (!owner->quitting) {
                        try { owner->present(*frame_ptr, composed, alpha_view, alpha_revision, blur_recipe); }
                        catch (const std::exception& error) { std::fprintf(stderr, "window presentation recovering: %s\n", error.what()); }
                    }
                    dispatch_semaphore_signal(handoff);
                });
                // Wake the AppKit run loop directly, including native tracking
                // modes, instead of waiting for its next polling interval.
                CFRunLoopWakeUp(CFRunLoopGetMain());
                dispatch_semaphore_wait(handoff, DISPATCH_TIME_FOREVER);
                const auto finished_at = std::chrono::steady_clock::now();
                const auto ms = [](auto interval) { return std::chrono::duration<double, std::milli>(interval).count(); };
                decode_ms += ms(decoded_at - decode_start);
                reconstruction_ms += ms(prepared_at - decoded_at);
                main_wait_ms += ms(main_started - prepared_at);
                presentation_ms += ms(finished_at - main_started);
                ++receive_stats_count;
                if (finished_at - receive_stats_start >= std::chrono::seconds(5)) {
                    std::fprintf(stderr, "macos-window-receive-stats frames=%llu decode-mean-ms=%.3f alpha-mean-ms=%.3f main-wait-mean-ms=%.3f present-mean-ms=%.3f alpha-updates-total=%llu\n",
                        static_cast<unsigned long long>(receive_stats_count), decode_ms / receive_stats_count,
                        reconstruction_ms / receive_stats_count, main_wait_ms / receive_stats_count, presentation_ms / receive_stats_count,
                        static_cast<unsigned long long>(alpha_cache.revision));
                    receive_stats_start = finished_at; receive_stats_count = 0;
                    decode_ms = reconstruction_ms = main_wait_ms = presentation_ms = 0;
                }
            } catch (const std::exception& error) {
                std::fprintf(stderr, "window image reconstruction recovering: %s\n", error.what());
            }
            CVPixelBufferRelease(buffer);
        }
    }, [&] { input_ended = true; });
    while (transport_owner_alive() && !input_ended && presenter.output.alive()) {
        @autoreleasepool {
            NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                inMode:NSDefaultRunLoopMode dequeue:YES];
            if (event) [NSApp sendEvent:event];
            presenter.draw_pending();
        }
    }
    presenter.quitting = true; input.stop();
    while (!input.finished() || presenter.outstanding != 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return 0;
}
}

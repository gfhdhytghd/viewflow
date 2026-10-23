#include "../reverse-common/activity_hint.hpp"
#include "../reverse-common/activity_workers.hpp"
#include "../reverse-common/activity_presentation.hpp"
#include "window_native.hpp"
#include "window_codec.hpp"
#include "window_io.hpp"
#include "window_keys.hpp"
#include "window_pixels.hpp"
#include "window_parking.hpp"
#include "../reverse-common/window_residency.hpp"
#include "../reverse-common/geometry_sync.hpp"
#include "../reverse-common/shadow_corner.hpp"
#include "window_shortcut_policy.hpp"
#include "window_background.hpp"
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
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
// Tile x/y identify the body; padding belongs only to the displayed surface.
static NSRect body_in_surface(const vf::Tile& tile, NSSize size) {
    if(!(tile.flags&16))return NSMakeRect(0,0,size.width,size.height);
    return NSMakeRect(double(tile.body_x)*size.width/tile.width,
        double(tile.body_y)*size.height/tile.height,
        double(tile.body_width)*size.width/tile.width,
        double(tile.body_height)*size.height/tile.height);
}
static NSRect body_screen_rect(const vf::Tile& tile, NSRect outer) {
    const auto body=body_in_surface(tile,outer.size);
    return NSMakeRect(outer.origin.x+body.origin.x,NSMaxY(outer)-NSMaxY(body),body.size.width,body.size.height);
}
static NSRect surface_screen_rect(const vf::Tile& tile, NSRect body) {
    if(!(tile.flags&16))return body;
    const double sx=body.size.width/tile.body_width,sy=body.size.height/tile.body_height;
    return NSMakeRect(body.origin.x-tile.body_x*sx,
        body.origin.y-(tile.height-tile.body_y-tile.body_height)*sy,tile.width*sx,tile.height*sy);
}
static double body_width(const vf::Tile& t) {return (t.flags&16)?t.logical_width:t.width;}
static double body_height(const vf::Tile& t) {return (t.flags&16)?t.logical_height:t.height;}
struct NoImplicitAnimation {
    NoImplicitAnimation() {[CATransaction begin];[CATransaction setDisableActions:YES];}
    ~NoImplicitAnimation() {[CATransaction commit];}
};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static CIImage* linux_shadow_lobe(CGRect extent, CGRect body, double range,
    double inset_x,double inset_y,double offset,double radius,double opacity) {
    static CIColorKernel* kernel=[CIColorKernel kernelWithString:@"kernel vec4 vfLinuxShadow(vec4 body, vec4 shape, vec2 style) { "
        "vec2 p=destCoord(); vec2 hi=body.xy+body.zw; "
        "if(p.x>=body.x && p.y>=body.y && p.x<=hi.x && p.y<=hi.y)return vec4(0.0); "
        "vec2 halfSize=body.zw*0.5-shape.yz; "
        "vec2 center=body.xy+body.zw*0.5+vec2(0.0,-shape.w); "
        "float r=min(style.x,min(halfSize.x,halfSize.y)); "
        "vec2 q=max(abs(p-center)-(halfSize-vec2(r)),vec2(0.0)); "
        "float d=length(q)-r; float a=pow(clamp(1.0-max(d,0.0)/shape.x,0.0,1.0),4.0)*style.y; "
        "return vec4(0.0,0.0,0.0,a); }"];
    if(!kernel)throw std::runtime_error("Linux shadow kernel unavailable");
    return [kernel applyWithExtent:extent arguments:@[
        [CIVector vectorWithX:body.origin.x Y:body.origin.y Z:body.size.width W:body.size.height],
        [CIVector vectorWithX:range Y:std::min(inset_x,body.size.width*.25) Z:std::min(inset_y,body.size.height*.25) W:offset],
        [CIVector vectorWithX:radius Y:opacity]]];
}
static CIImage* clean_windows_corners(CIImage* image,CGRect body,double radius) {
    static CIColorKernel* kernel=[CIColorKernel kernelWithString:@"kernel vec4 vfWindowsCorners(__sample pixel, vec4 body, float radius) { "
        "vec2 halfSize=body.zw*0.5; float r=min(radius,min(halfSize.x,halfSize.y)); "
        "vec2 q=max(abs(destCoord()-(body.xy+halfSize))-(halfSize-vec2(r)),vec2(0.0)); "
        "float coverage=clamp(0.5-(length(q)-r),0.0,1.0); "
        "float a=min(pixel.a,coverage); return pixel.a>0.0?pixel*(a/pixel.a):vec4(0.0); }"];
    if(!kernel)throw std::runtime_error("Windows corner cleanup kernel unavailable");
    return [kernel applyWithExtent:image.extent arguments:@[image,
        [CIVector vectorWithX:body.origin.x Y:body.origin.y Z:body.size.width W:body.size.height],@(radius)]];
}
#pragma clang diagnostic pop
struct LocalShadow {
    std::optional<unsigned> corner;
    uint64_t revision{};
    vf::PixelRect resident{};
    unsigned width{},height{};
    CIImage* __strong mask = nil;
    CIImage* __strong image = nil;
    id<MTLTexture> __strong texture = nil;
    bool encoded{}; // accessed only by the serial render queue
};
static bool same_backing_frame(NSRect a,NSRect b,double scale) {
    const double tolerance=1./std::max(1.,scale)+1e-6;
    return std::abs(a.origin.x-b.origin.x)<=tolerance && std::abs(a.origin.y-b.origin.y)<=tolerance &&
        std::abs(a.size.width-b.size.width)<=tolerance && std::abs(a.size.height-b.size.height)<=tolerance;
}
static bool popup_can_submit(unsigned streak,bool body_waiting) {return streak<2 || !body_waiting;}
static bool windows_local_shadow(const vf::Tile& tile) {
    return (tile.flags&16) && tile.pixel_scale==1 && tile.body_x==0 && tile.body_y==0 &&
        tile.body_width==tile.width && tile.body_height==tile.height && !(tile.flags&(32u|2u));
}
struct Proxy {
    Presenter* owner{};
    vf::Tile tile;
    unsigned local_padding{},source_width{},source_height{};
    std::shared_ptr<LocalShadow> local_shadow;
    NSImage* __strong application_icon = nil;
    NSWindow* __strong shadow_window = nil;
    VFProxyWindow* __strong window = nil;
    VFProxyView* __strong view = nil;
    CAMetalLayer* __strong layer = nil;
    std::unique_ptr<vm::WindowBackground> background;
    bool translucent{};
    std::chrono::steady_clock::time_point popup_arrival{};
    std::shared_ptr<std::atomic<bool>> popup_presented=std::make_shared<std::atomic<bool>>(false);
    uint64_t background_revision{};
    bool evidence_written{};
    std::chrono::steady_clock::time_point last_video{};
    uint64_t alpha_revision{};
    unsigned alpha_x{}, alpha_y{}, alpha_width{}, alpha_height{};
    vf::PixelRect alpha_resident{}, reported_resident{};
    bool resident_reported{};unsigned reported_width{},reported_height{};
    CIImage* __strong image = nil;
    bool applying{}, drawing{}, dragging{}, needs_draw{}, video_pending{}, shown{};
    bool fullscreen_transition{}, fullscreen_remote{};
    bool source_raise_known{}, source_raised{};
    uint64_t fullscreen_pending{};
    NSPoint drag_offset{}, drag_start{};
    NSEvent* __strong drag_event = nil;
    NSRect drag_last_frame{};
    NSPoint drag_last_pointer{};
    bool drag_fallback_logged{}, drag_native_moved{};
    vf::NativeMoveConfirmation move_confirmation;
    bool geometry_queued{};
    uint64_t geometry_pending{}, generation{};
    std::set<unsigned> modifiers;
    std::set<unsigned> keys;
    ~Proxy();
};
struct Presenter {
    vm::Options options;
    viewflow::activity::Presentation activity_presentation;
    viewflow::activity::Priority<std::uint64_t> activity_priority;
    viewflow::activity::FairQueue<std::uint64_t> activity_draws;
    vm::Output output{4096};
    id<MTLDevice> __strong device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> __strong commands;
    dispatch_queue_t render_queue = dispatch_queue_create("org.viewflow.window-render", DISPATCH_QUEUE_SERIAL);
    CIContext* __strong context;
    CGColorSpaceRef color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    std::map<uint64_t, std::unique_ptr<Proxy>> windows;
    uint64_t sequence{}, presented{}, coalesced_draws{}, last_drawn{}, next_generation{};
    unsigned outstanding{}, popup_streak{};
    uint64_t last_popup_drawn{},last_body_drawn{};
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
    void interaction(std::uint64_t window,bool active){
        activity_priority.hold(window,4,0,active,viewflow::activity::now_us());
        if(viewflow::activity::negotiated())output.push(viewflow::activity::pack_hint({window,1,active}));
    }
    ~Presenter() { windows.clear(); CGColorSpaceRelease(color_space); }
    uint64_t send(uint64_t id, vf::InputKind kind, int a = 0, int b = 0, int c = 0, int d = 0) {
        if (quitting) return 0;
        if (recovery_release) {
            if (!output.push(vf::pack_input({0, ++sequence, vf::InputKind::release, 0, 0, 0, 0}))) return 0;
            recovery_release = false;
        }
        const auto current = ++sequence;
        viewflow::activity::observe(activity_priority,vf::Input{id,current,kind,a,b,c,d},viewflow::activity::now_us());
        if(kind==vf::InputKind::button || kind==vf::InputKind::key)
            std::fprintf(stderr,"macos-input-send id=%llu seq=%llu kind=%u down=%d\n",(unsigned long long)id,(unsigned long long)current,unsigned(kind),b);
        if (!output.push(vf::pack_input({id, current, kind, a, b, c, d}))) {
            recovery_release = true;
            std::fprintf(stderr, "proxy input backpressure: queue retained, releasing held input when pipe resumes\n");
            return 0;
        }
        return current;
    }
    void visibility(Proxy& proxy) {
        if(!(proxy.tile.flags & vf::residency_capability))return;
        vf::PixelRect visible{};
        const NSRect bounds = [proxy.view convertRect:proxy.view.bounds toView:nil];
        const NSRect rect = [proxy.window convertRectToScreen:bounds];
        const bool fullscreen_body=(proxy.tile.flags&16) && (proxy.window.styleMask & NSWindowStyleMaskFullScreen);
        const double source_x=fullscreen_body?proxy.tile.body_x:0,source_y=fullscreen_body?proxy.tile.body_y:0;
        const double source_width=fullscreen_body?proxy.tile.body_width:proxy.tile.width;
        const double source_height=fullscreen_body?proxy.tile.body_height:proxy.tile.height;
        NSRect intersection = NSZeroRect;
        if (proxy.window.isVisible && proxy.window.isOnActiveSpace && !proxy.window.isMiniaturized && rect.size.width > 0 && rect.size.height > 0) {
            for (NSScreen* screen in NSScreen.screens) {
                NSNumber* display=screen.deviceDescription[@"NSScreenNumber"];
                if(display && vm::is_parking_display(display.unsignedIntValue))continue;
                const auto part = NSIntersectionRect(rect, screen.frame);
                if (!NSIsEmptyRect(part)) intersection = NSIsEmptyRect(intersection) ? part : NSUnionRect(intersection, part);
            }
            if (!NSIsEmptyRect(intersection)) {
                const int x = std::max(0, int(std::floor(source_x+(NSMinX(intersection)-NSMinX(rect))*source_width/rect.size.width))-256);
                const int y = std::max(0, int(std::floor(source_y+(NSMaxY(rect)-NSMaxY(intersection))*source_height/rect.size.height))-256);
                const int right = std::min(int(proxy.tile.width), int(std::ceil(source_x+(NSMaxX(intersection)-NSMinX(rect))*source_width/rect.size.width))+256);
                const int bottom = std::min(int(proxy.tile.height), int(std::ceil(source_y+(NSMaxY(rect)-NSMinY(intersection))*source_height/rect.size.height))+256);
                visible = {unsigned(x), unsigned(y), unsigned(right-x), unsigned(bottom-y)};
            }
        }
        if(proxy.local_padding)visible=vf::clip_resident(proxy.source_width,proxy.source_height,
            int(visible.x)-int(proxy.local_padding),int(visible.y)-int(proxy.local_padding),visible.width,visible.height);
        visible=vf::align_resident(visible,proxy.source_width?proxy.source_width:proxy.tile.width,proxy.source_height?proxy.source_height:proxy.tile.height);
        if (!proxy.resident_reported || !(visible == proxy.reported_resident) || proxy.reported_width!=proxy.tile.width || proxy.reported_height!=proxy.tile.height) {
            if (send(proxy.tile.id, vf::InputKind::visibility, visible.x, visible.y, visible.width, visible.height)) {
                proxy.reported_resident=visible; proxy.resident_reported=true;proxy.reported_width=proxy.tile.width;proxy.reported_height=proxy.tile.height;
            }
        }
    }
    void pointer(Proxy& proxy, NSEvent* event) {
        (void)event;
        if(proxy.window.styleMask & NSWindowStyleMaskFullScreen) {
            const auto point=[proxy.view convertPoint:event.locationInWindow fromView:nil];
            const auto size=proxy.view.bounds.size;
            if(size.width<=0 || size.height<=0)return;
            send(proxy.tile.id,vf::InputKind::pointer,
                int(std::lround(proxy.tile.x+point.x*body_width(proxy.tile)/size.width)),
                int(std::lround(proxy.tile.y+point.y*body_height(proxy.tile)/size.height)),1);
            return;
        }
        // Route to the pixels actually displayed. AppKit may constrain a proxy
        // independently of the source (for example at the top screen edge).
        // A desktop-global coordinate would then hit a different source window.
        const auto point = NSEvent.mouseLocation;
        const auto body = body_screen_rect(proxy.tile,proxy.window.frame);
        if(body.size.width<=0 || body.size.height<=0)return;
        send(proxy.tile.id, vf::InputKind::pointer,
            static_cast<int>(std::lround(proxy.tile.x+(point.x-NSMinX(body))*body_width(proxy.tile)/body.size.width)),
            static_cast<int>(std::lround(proxy.tile.y+(NSMaxY(body)-point.y)*body_height(proxy.tile)/body.size.height)),1);
    }

    void geometry(Proxy& proxy) {
        sync_shadow(proxy);
        proxy.needs_draw = true;
        if (proxy.applying || quitting || proxy.fullscreen_transition || (proxy.window.styleMask & NSWindowStyleMaskFullScreen)) return;
        // One latest geometry per AppKit event-loop turn. WindowDidMove and
        // explicit drag updates can both report the same physical movement.
        proxy.geometry_queued = true;
    }
    void flush_geometry(Proxy& proxy) {
        if (proxy.applying || quitting || proxy.fullscreen_transition || (proxy.window.styleMask & NSWindowStyleMaskFullScreen)) return;
        const auto rect = body_screen_rect(proxy.tile,proxy.window.frame);
        const double desktop_top = NSScreen.screens.firstObject.frame.size.height;
        const auto sent = send(proxy.tile.id, vf::InputKind::geometry,
            static_cast<int>(std::lround((rect.origin.x - options.origin_x) * options.scale)),
            static_cast<int>(std::lround((desktop_top - NSMaxY(rect) - options.origin_y) * options.scale)),
            static_cast<int>(std::lround(rect.size.width * options.scale)),
            static_cast<int>(std::lround(rect.size.height * options.scale)));
        if (sent) proxy.geometry_pending = sent;
        else proxy.geometry_queued = true; // Keep local ownership and retry after output backpressure.
    }
    void draw(Proxy& proxy) {
        NoImplicitAnimation no_animation;
        visibility(proxy);
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
        // At most two popup submissions while a body has a pending new draw.
        // Already submitted GPU work completes; no frame-age/session cutoff.
        if((proxy.tile.flags&2) && !popup_can_submit(popup_streak,std::any_of(windows.begin(),windows.end(),[](const auto& entry){
            const auto& p=*entry.second;return !(p.tile.flags&2) && p.image && p.needs_draw && !p.drawing;
        })))return;
        const auto scale = proxy.window.backingScaleFactor;
        const auto bounds = proxy.view.bounds;
        if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
        proxy.layer.contentsScale = scale;
        proxy.layer.drawableSize = CGSizeMake(std::ceil(bounds.size.width * scale), std::ceil(bounds.size.height * scale));
        // Drawable acquisition may wait for WindowServer even after GPU work
        // completed. Keep that wait and Core Image encoding off the input loop.
        CAMetalLayer* layer = proxy.layer;
        CIImage* source_image = proxy.image;
        if((proxy.tile.flags&16) && (proxy.window.styleMask & NSWindowStyleMaskFullScreen)) {
            const auto& tile=proxy.tile;
            const auto body=CGRectMake(tile.body_x,tile.height-tile.body_y-tile.body_height,tile.body_width,tile.body_height);
            source_image=[[source_image imageByCroppingToRect:body] imageByApplyingTransform:CGAffineTransformMakeTranslation(-body.origin.x,-body.origin.y)];
        }
        const auto drawable_size = proxy.layer.drawableSize;
        const auto window_id = proxy.tile.id;
        const auto generation = proxy.generation;
        const bool popup=(proxy.tile.flags&2)!=0;
        const auto popup_arrival=proxy.popup_arrival;
        const auto popup_presented=proxy.popup_presented;
        const auto local_shadow=proxy.local_shadow;
        NSString* evidence_directory=nil;
        if(background_image&&!proxy.evidence_written&&!options.evidence_dir.empty()) {
            proxy.evidence_written=true;
            evidence_directory=@(options.evidence_dir.c_str());
        }
        Presenter* owner = this;
        proxy.drawing = true; proxy.needs_draw = false; proxy.video_pending = false; ++outstanding;
        proxy.background_revision=background_revision;
        popup_streak=popup?std::min(popup_streak+1,2u):0;
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
        if(local_shadow && !local_shadow->encoded) {
            [owner->context render:local_shadow->mask toMTLTexture:local_shadow->texture commandBuffer:command
                bounds:CGRectMake(0,0,local_shadow->width,local_shadow->height) colorSpace:owner->color_space];
            local_shadow->encoded=true;
        }
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
        if(popup) {
            [drawable addPresentedHandler:^(id<MTLDrawable> presented_drawable) {
                if(!popup_presented->exchange(true)) {
                    const double elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-popup_arrival).count();
                    std::fprintf(stderr,"macos-popup-first-presented window=%llu arrival-to-callback-ms=%.3f presented-time=%.6f animations=none\n",
                        (unsigned long long)window_id,elapsed,presented_drawable.presentedTime);
                }
            }];
        }
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
        if(popup)last_popup_drawn=window_id;else last_body_drawn=window_id;
    }
    void update_pointer_regions() {
        // Keep WindowServer input delivery stable. Toggling this flag on the
        // interactive window can lose remote posted mouse/key event routing.
        // Shadow-only hit testing must use a separate noninteractive surface.
        for(auto& [_,entry]:windows){entry->window.ignoresMouseEvents=NO;sync_shadow(*entry);}
    }
    void draw_pending() {
        update_pointer_regions();
        if (windows.empty()) return;
        auto it = windows.upper_bound(last_drawn);
        for (size_t remaining = windows.size(); remaining; --remaining) {
            if (it == windows.end()) it = windows.begin();
            // WindowServer-owned dragging may consume mouseUp. Physical state
            // completes ownership without depending on a proxy-delivered event.
            if (it->second->dragging && !(NSEvent.pressedMouseButtons & 1)) {
                it->second->dragging = false;interaction(it->second->tile.id,false);
                it->second->drag_event = nil;
                geometry(*it->second);
            }
            if (it->second->geometry_queued) {
                it->second->geometry_queued = false;
                flush_geometry(*it->second);
            }
            ++it;
        }
        if(viewflow::activity::negotiated()){
            std::vector<std::uint64_t> ready;
            for(const auto& [id,proxy]:windows)if(!proxy->drawing)ready.push_back(id);
            while(const auto selected=activity_draws.next(ready,activity_priority,viewflow::activity::now_us())){
                auto& proxy=*windows.at(*selected);draw(proxy);
                if(proxy.drawing)activity_draws.submitted(*selected,viewflow::activity::now_us());
                std::erase(ready,*selected);
            }
            return;
        }
        // Round-robin within each class; popup first, with the bounded streak
        // in draw() reserving service for pending body updates.
        for(bool popup:{true,false}) {
            auto next=windows.upper_bound(popup?last_popup_drawn:last_body_drawn);
            for(size_t remaining=windows.size();remaining;--remaining) {
                if(next==windows.end())next=windows.begin();
                auto& proxy=*next->second;++next;
                if(bool(proxy.tile.flags&2)==popup)draw(proxy);
            }
        }
    }
    void update_backdrop(Proxy& proxy, const vf::Frame& frame, std::span<const uint8_t> alpha, uint64_t revision = 0) {
        const auto& tile = proxy.tile;
        if (revision && revision == proxy.alpha_revision && proxy.alpha_x == tile.atlas_x &&
            proxy.alpha_y == tile.atlas_y && proxy.alpha_width == tile.width && proxy.alpha_height == tile.height &&
            proxy.alpha_resident == vf::resident_rect(tile)) return;
        const auto remember = [&] {
            proxy.alpha_revision = revision; proxy.alpha_x = tile.atlas_x; proxy.alpha_y = tile.atlas_y;
            proxy.alpha_width = tile.width; proxy.alpha_height = tile.height; proxy.alpha_resident = vf::resident_rect(tile);
        };
        bool translucent = false;
        const auto resident = vf::resident_rect(tile);
        for (unsigned y = 0; y < resident.height; ++y) {
            const auto row = alpha.subspan(static_cast<size_t>(tile.atlas_y + y) * frame.width + tile.atlas_x, resident.width);
            if (!translucent)
                translucent = std::any_of(row.begin(), row.end(), [](uint8_t a) { return a > 0 && a < 255; });
        }
        proxy.translucent = translucent; remember();
    }
    void sync_shadow(Proxy& proxy) {
        if(!proxy.shadow_window)return;
        if(proxy.fullscreen_transition || (proxy.window.styleMask&NSWindowStyleMaskFullScreen)) {
            [proxy.shadow_window orderOut:nil];return;
        }
        const auto rect=NSInsetRect(proxy.window.frame,-110,-110);
        if(!NSEqualRects(proxy.shadow_window.frame,rect))[proxy.shadow_window setFrame:rect display:NO animate:NO];
        if(proxy.shown && !proxy.shadow_window.visible)[proxy.shadow_window orderWindow:NSWindowBelow relativeTo:proxy.window.windowNumber];
    }
    void local_shadow(Proxy& proxy,uint64_t revision,unsigned atlas_width,const vf::Tile& original,std::span<const uint8_t> alpha) {
        if(!windows_local_shadow(original)) {
            if(proxy.shadow_window){[proxy.window removeChildWindow:proxy.shadow_window];[proxy.shadow_window close];proxy.shadow_window=nil;}
            proxy.local_shadow.reset();return;
        }
        const auto resident=vf::resident_rect(original);
        if(!resident.width || !resident.height)return;
        const unsigned padding=unsigned(std::ceil(110*options.scale));
        const unsigned width=original.width+2*padding,height=original.height+2*padding;
        auto cache=proxy.local_shadow;
        if(!cache || cache->revision!=revision || cache->width!=width || cache->height!=height || cache->resident!=resident) {
            auto corner=vf::shadow_corner(atlas_width,original,alpha,original.body_width,original.body_height);
            const bool full_body=resident.x==0 && resident.y==0 && resident.width==original.width && resident.height==original.height;
            if(!corner && !full_body && cache && cache->width==width && cache->height==height)corner=cache->corner;
            const bool rebuild=!cache || cache->width!=width || cache->height!=height || cache->corner!=corner;
            if(rebuild) {
                cache=std::make_shared<LocalShadow>();cache->width=width;cache->height=height;cache->corner=corner;
                CIImage* result=[[CIImage imageWithColor:CIColor.clearColor] imageByCroppingToRect:CGRectMake(0,0,width,height)];
                const double density=options.scale;
                const CGRect body=CGRectMake(padding,padding,original.width,original.height);
                const auto lobe=[&](double range,double ix,double iy,double offset,double radius,double opacity) {
                    result=[linux_shadow_lobe(CGRectMake(0,0,width,height),body,range*density,ix*density,iy*density,offset*density,radius*density,opacity) imageByCompositingOverImage:result];
                };
                lobe(88,13,14,17.5,35.5,.233);lobe(74,0,0,19,27,.107);
                if(corner)lobe(2,0,0,0,*corner/10./density,.32);
                if(!proxy.shadow_window) {
                    proxy.shadow_window=[[NSWindow alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
                    proxy.shadow_window.releasedWhenClosed=NO;proxy.shadow_window.opaque=NO;
                    proxy.shadow_window.backgroundColor=NSColor.clearColor;proxy.shadow_window.hasShadow=NO;
                    proxy.shadow_window.ignoresMouseEvents=YES;proxy.shadow_window.animationBehavior=NSWindowAnimationBehaviorNone;
                    proxy.shadow_window.contentView.wantsLayer=YES;
                    [proxy.window addChildWindow:proxy.shadow_window ordered:NSWindowBelow];
                }
                CGImageRef image=[context createCGImage:result fromRect:CGRectMake(0,0,width,height)];
                proxy.shadow_window.contentView.layer.contents=(__bridge id)image;
                if(image)CGImageRelease(image);
                cache->encoded=true;
                std::fprintf(stderr,"macos-windows-shadow window=%llu separate=1 body=%ux%u padding=%u\n",(unsigned long long)original.id,original.width,original.height,padding);
            }
            cache->revision=revision;cache->resident=resident;proxy.local_shadow=cache;
        }
        if(cache && cache->corner)proxy.image=clean_windows_corners(proxy.image,CGRectMake(0,0,original.width,original.height),*cache->corner/10.);
        sync_shadow(proxy);
    }
    void present(const vf::Frame& frame, CIImage* composed, std::span<const uint8_t> alpha, uint64_t revision,
        const std::optional<vf::BlurRecipe>& blur_recipe,
        const std::map<uint64_t,std::chrono::steady_clock::time_point>& popup_arrivals) {
        if(!activity_presentation.admit(frame))return;
        NoImplicitAnimation no_animation;
        auto live=activity_presentation.members(frame);
        std::vector<const vf::Tile*> ordered;
        for(const auto& tile:frame.tiles)if(tile.flags&2)ordered.push_back(&tile);
        for(const auto& tile:frame.tiles)if(!(tile.flags&2))ordered.push_back(&tile);
        for (const auto* selected : ordered) {
            const auto& original=*selected;
            if(!activity_presentation.accepts(frame,original))continue;
            auto tile=original;
            const unsigned padding=0; // Shadows are separate noninteractive child windows.
            live.insert(tile.id);
            auto& entry = windows[tile.id];
            if (!entry) {
                entry = std::make_unique<Proxy>(); auto& proxy = *entry;
                proxy.owner = this; proxy.tile = tile; proxy.generation = ++next_generation;
                proxy.window = [[VFProxyWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1, 1)
                    styleMask:(tile.flags & 2 ? NSWindowStyleMaskBorderless : NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];
                proxy.window.releasedWhenClosed = NO;
                proxy.window.animationBehavior = NSWindowAnimationBehaviorNone;
                if(tile.flags&2) {
                    const auto arrival=popup_arrivals.find(tile.id);
                    proxy.popup_arrival=arrival==popup_arrivals.end()?std::chrono::steady_clock::now():arrival->second;
                    std::fprintf(stderr,"macos-popup-first-arrival window=%llu receive-to-main-ms=%.3f\n",(unsigned long long)tile.id,
                        std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-proxy.popup_arrival).count());
                }
                proxy.window.opaque = NO; proxy.window.backgroundColor = NSColor.clearColor;
                proxy.window.hasShadow = NO; proxy.window.acceptsMouseMovedEvents = YES;
                proxy.window.collectionBehavior = tile.flags & 2 ? NSWindowCollectionBehaviorTransient :
                    NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorFullScreenPrimary | NSWindowCollectionBehaviorFullScreenAllowsTiling;
                proxy.window.title = [[NSString alloc] initWithBytes:tile.title.data() length:tile.title.size() encoding:NSUTF8StringEncoding] ?: @"Shared window";
                proxy.view = [[VFProxyView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)]; proxy.view->proxy = &proxy;
                proxy.layer = [CAMetalLayer layer]; proxy.layer.device = device;
                proxy.layer.actions=@{@"bounds":[NSNull null],@"position":[NSNull null],@"contents":[NSNull null],@"opacity":[NSNull null],@"transform":[NSNull null],@"sublayers":[NSNull null]};
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
            proxy.local_padding=padding;proxy.source_width=original.width;proxy.source_height=original.height;
            const auto point = NSEvent.mouseLocation;
            if (proxy.move_confirmation.armed && proxy.drag_event && !proxy.dragging &&
                (NSEvent.pressedMouseButtons & 1) &&
                !NSEqualPoints(point, proxy.drag_start) &&
                proxy.move_confirmation.observe({tile.x, tile.y, int(body_width(tile)), int(body_height(tile))}, tile.geometry_ack)) {
                // The source moved a same-size window during this held click.
                // Release its native drag before locally owned geometry follows.
                send(tile.id, vf::InputKind::button, 272, 0);
                proxy.dragging = true;interaction(proxy.tile.id,true);
                [proxy.window setFrameOrigin:NSMakePoint(point.x-proxy.drag_offset.x, point.y-proxy.drag_offset.y)];
                geometry(proxy);
                proxy.drag_last_frame = proxy.window.frame; proxy.drag_last_pointer = point;
                proxy.drag_fallback_logged = false; proxy.drag_native_moved=false;
                proxy.geometry_queued = false; flush_geometry(proxy);
                [proxy.window performWindowDragWithEvent:proxy.drag_event];
                std::fprintf(stderr, "macos-local-native-drag window=%llu source-confirmed=1\n", static_cast<unsigned long long>(tile.id));
            }
            proxy.background->configure(blur_recipe);
            const double desktop_top = NSScreen.screens.firstObject.frame.size.height;
            const auto rect = surface_screen_rect(tile,NSMakeRect(options.origin_x + tile.x / options.scale,
                desktop_top - options.origin_y - (tile.y + body_height(tile)) / options.scale,
                body_width(tile) / options.scale, body_height(tile) / options.scale));
            if (!proxy.fullscreen_transition && !proxy.fullscreen_pending && !(proxy.window.styleMask & NSWindowStyleMaskFullScreen) && !proxy.dragging && !proxy.geometry_queued && (!proxy.geometry_pending || tile.geometry_ack >= proxy.geometry_pending)) {
                proxy.geometry_pending = 0; proxy.applying = true;
                if (!same_backing_frame(proxy.window.frame,rect,options.scale)) [proxy.window setFrame:rect display:NO animate:NO];
                proxy.applying = false;
                // AppKit can constrain a restored/moved window to the current
                // display's visible frame. Acknowledge that real placement:
                // otherwise global pointer coordinates target an invisible,
                // stale source title bar (especially after display rearrange).
                if (!same_backing_frame(proxy.window.frame,rect,options.scale)) {
                    std::fprintf(stderr,"macos-window-placement constrained id=%llu requested=%.1f,%.1f actual=%.1f,%.1f\n",
                        static_cast<unsigned long long>(tile.id),rect.origin.x,rect.origin.y,
                        proxy.window.frame.origin.x,proxy.window.frame.origin.y);
                    // Source placement is authoritative here. Only a local user
                    // move/resize sends geometry, never this rendering correction.
                }
            }
            if(original.flags&vf::application_icon_flag) {
                NSData* data=[NSData dataWithBytes:original.icon_png.data() length:original.icon_png.size()];
                NSImage* icon=[[NSImage alloc] initWithData:data];
                if(icon) {
                    proxy.application_icon=icon;proxy.window.miniwindowImage=icon;
                    if(proxy.window.keyWindow || !NSApp.keyWindow)NSApp.applicationIconImage=icon;
                    std::fprintf(stderr,"macos-application-icon-applied window=%llu app=%s bytes=%zu\n",
                        static_cast<unsigned long long>(original.id),original.app_id.c_str(),original.icon_png.size());
                }
            }
            update_backdrop(proxy, frame, alpha, revision);
            const auto resident = vf::resident_rect(tile);
            const auto crop = CGRectMake(tile.atlas_x, frame.height - tile.atlas_y - resident.height, resident.width, resident.height);
            // A submitted frame is still rendered. Count only an unsubmitted image replaced here.
            if (proxy.video_pending) ++coalesced_draws;
            CIImage* clear = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:0]]
                imageByCroppingToRect:CGRectMake(0, 0, tile.width, tile.height)];
            proxy.image = clear;
            if (resident.width > 0 && resident.height > 0) {
                CIImage* patch = [[composed imageByCroppingToRect:crop] imageByApplyingTransform:
                    CGAffineTransformMakeTranslation(resident.x-crop.origin.x, tile.height-resident.y-resident.height-crop.origin.y)];
                proxy.image = [patch imageByCompositingOverImage:clear];
            }
            local_shadow(proxy,revision,frame.width,original,alpha);
            proxy.needs_draw = true; proxy.video_pending = true;
            proxy.last_video=std::chrono::steady_clock::now();
            if (!proxy.shown) { [proxy.window orderFront:nil]; proxy.shown=true; } // No activation or key-window change.
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
            if((tile.flags&2) && !frame.activity_epoch)draw(proxy);
        }
        for (auto it = windows.begin(); it != windows.end();) {
            if (!live.contains(it->first)) { send(it->first, vf::InputKind::release); it = windows.erase(it); }
            else ++it;
        }
        std::vector<std::pair<std::uint64_t,std::uint64_t>> visible;
        for(const auto& [id,proxy]:windows)visible.emplace_back(id,proxy->tile.owner);
        activity_priority.membership(visible);
        if(!activity_priority.last_focus() && frame.activity_focus)activity_priority.focus(frame.activity_focus);
        draw_pending();
    }
};
Proxy::~Proxy() { if(shadow_window){[window removeChildWindow:shadow_window];[shadow_window close];} window.delegate = nil; if (view) view->proxy = nullptr; [window close]; }
}
@implementation VFProxyWindow
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen*)screen {
    if([self.contentView isKindOfClass:VFProxyView.class]) {
        auto* state=((VFProxyView*)self.contentView)->proxy;
        // Remote geometry can belong to an adjacent device. AppKit must not
        // constrain it back onto this screen and feed that correction upstream.
        if(state && state->applying)return frame;
        if(state && state->local_padding && !(self.styleMask&NSWindowStyleMaskFullScreen)) {
            const auto body=body_screen_rect(state->tile,frame);
            return surface_screen_rect(state->tile,[super constrainFrameRect:body toScreen:screen]);
        }
    }
    return [super constrainFrameRect:frame toScreen:screen];
}
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
        // Normally WindowServer consumes the drag. Some posted cross-desktop
        // events still reach this view without moving the native window. Keep
        // that input usable locally, while leaving native tiling enabled.
        const auto point = NSEvent.mouseLocation;
        if(!proxy->drag_fallback_logged && !NSEqualRects(self.window.frame,proxy->drag_last_frame))proxy->drag_native_moved=true;
        if (!proxy->drag_native_moved && !NSEqualPoints(point, proxy->drag_last_pointer)) {
            [self.window setFrameOrigin:NSMakePoint(point.x-proxy->drag_offset.x, point.y-proxy->drag_offset.y)];
            proxy->owner->geometry(*proxy);
            if (!proxy->drag_fallback_logged) {
                std::fprintf(stderr, "macos-local-native-drag fallback=posted-events window=%llu\n", static_cast<unsigned long long>(proxy->tile.id));
                proxy->drag_fallback_logged = true;
            }
        }
        proxy->drag_last_frame = self.window.frame; proxy->drag_last_pointer = point;
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
    proxy->drag_event = event;
    self.window.ignoresMouseEvents=NO;
    std::fprintf(stderr,"macos-drag-press window=%llu pointer=%.1f,%.1f body=%.1f,%.1f queued=%d pending=%llu ack=%llu\n",
        (unsigned long long)proxy->tile.id,NSEvent.mouseLocation.x,NSEvent.mouseLocation.y,
        self.window.frame.origin.x,self.window.frame.origin.y,int(proxy->geometry_queued),
        (unsigned long long)proxy->geometry_pending,(unsigned long long)proxy->tile.geometry_ack);
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        proxy->owner->send(proxy->tile.id, vf::InputKind::release);
        // Let the receiving desktop own dragging, edge tiling, and Spaces.
        const auto point = NSEvent.mouseLocation;
        proxy->drag_offset = NSMakePoint(point.x-self.window.frame.origin.x,
                                        point.y-self.window.frame.origin.y);
        proxy->dragging = true;proxy->owner->interaction(proxy->tile.id,true);
        proxy->modifiers.clear();
        proxy->keys.clear();
        proxy->owner->geometry(*proxy);
        proxy->drag_last_frame = self.window.frame; proxy->drag_last_pointer = point;
        proxy->drag_fallback_logged = false; proxy->drag_native_moved=false;
        proxy->geometry_queued = false; proxy->owner->flush_geometry(*proxy);
        [self.window performWindowDragWithEvent:event]; return;
    }
    [self button:event down:YES];
    if (!(proxy->tile.flags & 2) && !proxy->geometry_queued &&
        (!proxy->geometry_pending || proxy->tile.geometry_ack >= proxy->geometry_pending) &&
        !proxy->fullscreen_transition && !(proxy->window.styleMask & NSWindowStyleMaskFullScreen)) {
        proxy->drag_start = NSEvent.mouseLocation;
        proxy->drag_offset = NSMakePoint(proxy->drag_start.x-self.window.frame.origin.x,
                                        proxy->drag_start.y-self.window.frame.origin.y);
        proxy->move_confirmation.begin({proxy->tile.x, proxy->tile.y, int(body_width(proxy->tile)), int(body_height(proxy->tile))}, proxy->tile.geometry_ack);
    }
}
- (void)mouseUp:(NSEvent*)event {
    if (proxy) { proxy->move_confirmation.cancel(); proxy->drag_event = nil; }
    if (proxy && proxy->dragging) {
        proxy->dragging = false;proxy->owner->interaction(proxy->tile.id,false);
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
        proxy->dragging = false;proxy->owner->interaction(proxy->tile.id,false);
        proxy->move_confirmation.cancel();
        proxy->drag_event = nil;
        proxy->owner->send(proxy->tile.id, vf::InputKind::release);
    }
}
- (void)windowDidBecomeKey:(NSNotification*)notification {
    if(proxy && proxy->application_icon)NSApp.applicationIconImage=proxy->application_icon;
    (void)notification; if (proxy) proxy->owner->send(proxy->tile.id, vf::InputKind::focus);
}
- (void)windowDidMove:(NSNotification*)notification {
    (void)notification; if (proxy) proxy->owner->geometry(*proxy);
}
- (void)windowDidResize:(NSNotification*)notification {
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
    vf::Tile shadow_tile;shadow_tile.flags=16;shadow_tile.pixel_scale=1;
    shadow_tile.width=shadow_tile.body_width=200;shadow_tile.height=shadow_tile.body_height=100;
    if(!windows_local_shadow(shadow_tile))throw std::runtime_error("Windows body shadow eligibility");
    shadow_tile.flags|=2;
    if(windows_local_shadow(shadow_tile))throw std::runtime_error("IME popup must have no local shadow or padding");
    if(!popup_can_submit(0,true) || !popup_can_submit(1,true) || popup_can_submit(2,true) || !popup_can_submit(2,false))
        throw std::runtime_error("popup fairness budget");
    vf::Tile padded;padded.flags=16;padded.width=240;padded.height=180;padded.body_x=12;padded.body_y=8;
    padded.body_width=200;padded.body_height=140;padded.logical_width=400;padded.logical_height=280;
    const auto body=NSMakeRect(-50,70,200,140);
    const auto outer=surface_screen_rect(padded,body);
    if(!NSEqualRects(body_screen_rect(padded,outer),body) || outer.origin.x!=-62 || outer.origin.y!=38 || outer.size.width!=240 || outer.size.height!=180)
        throw std::runtime_error("padded body geometry roundtrip");

    [NSApplication sharedApplication];
    Options options;
    Presenter presenter(options);
    CIImage* lobe=linux_shadow_lobe(CGRectMake(0,0,100,100),CGRectMake(30,30,40,40),10,0,0,0,8,1);
    CIImage* cleaned=clean_windows_corners([[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:.2]] imageByCroppingToRect:CGRectMake(0,0,100,100)],CGRectMake(30,30,40,40),8);
    const auto alpha_at=[&](CIImage* image,int x,int y) {
        unsigned char pixel[4]{};
        [presenter.context render:image toBitmap:pixel rowBytes:4 bounds:CGRectMake(x,y,1,1) format:kCIFormatRGBA8 colorSpace:presenter.color_space];
        return int(pixel[3]);
    };
    if(alpha_at(lobe,50,50)!=0 || alpha_at(lobe,50,10)!=0 || std::abs(alpha_at(lobe,50,25)-23)>2)
        throw std::runtime_error("Linux shadow body exclusion or power-four falloff");
    if(alpha_at(cleaned,30,30)!=0 || std::abs(alpha_at(cleaned,50,50)-51)>1)
        throw std::runtime_error("Windows native corner residue cleanup");
    std::fprintf(stderr,"macos-linux-shadow self-test passed: power-four falloff, body exclusion, native corner cleanup\n");
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
    vf::set_resident_rect(proxy.tile, {1, 1, 1, 1});
    presenter.update_backdrop(proxy, frame, *cache.pixels, cache.revision);
    if (!proxy.translucent) throw std::runtime_error("resident crop lost its atlas alpha");
    vf::set_resident_rect(proxy.tile, {});
    presenter.update_backdrop(proxy, frame, *cache.pixels, cache.revision);
    if (proxy.translucent) throw std::runtime_error("empty resident crop retained backdrop work");
    vf::set_resident_rect(proxy.tile, {0, 0, 2, 2});
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
        Decoder decoders[2]; unsigned count = 0; std::vector<uint8_t> bytes;
        while (vf::read_record(STDIN_FILENO, bytes)) {
            const auto frame = vf::unpack_frame(bytes);
            const auto alpha = vf::decode_alpha(frame.alpha, static_cast<size_t>(frame.width) * frame.height);
            CVPixelBufferRef buffer = decoders[frame.activity_epoch?frame.activity_lane:0].decode(frame);
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
    struct DecodeLane {
        std::unique_ptr<Decoder> decoder=std::make_unique<Decoder>();
        DecodedAlpha alpha_cache;
        std::chrono::steady_clock::time_point receive_stats_start=std::chrono::steady_clock::now();
        uint64_t receive_stats_count{};
        double decode_ms{},reconstruction_ms{},main_wait_ms{},presentation_ms{};
        std::map<uint64_t,std::chrono::steady_clock::time_point> popup_arrivals;
    };
    DecodeLane lanes[2];
    std::atomic<bool> input_ended{false};
    auto process_frame=[&](vf::Frame frame) {
        @autoreleasepool {
            const auto lane_index=frame.activity_epoch?frame.activity_lane:0;
            auto& lane=lanes[lane_index];auto& decoder=lane.decoder;auto& alpha_cache=lane.alpha_cache;
            auto& receive_stats_start=lane.receive_stats_start;auto& receive_stats_count=lane.receive_stats_count;
            auto& decode_ms=lane.decode_ms;auto& reconstruction_ms=lane.reconstruction_ms;
            auto& main_wait_ms=lane.main_wait_ms;auto& presentation_ms=lane.presentation_ms;
            auto& popup_arrivals=lane.popup_arrivals;
            const auto arrived=std::chrono::steady_clock::now();
            std::set<uint64_t> popup_ids;
            for(const auto& tile:frame.tiles)if(tile.flags&2){popup_ids.insert(tile.id);popup_arrivals.try_emplace(tile.id,arrived);}
            std::erase_if(popup_arrivals,[&](const auto& entry){return !popup_ids.contains(entry.first);});
            const auto blur_recipe = vf::blur_recipe_from_annex_b(frame.color, frame.codec);
            CVPixelBufferRef buffer = nullptr;
            const auto decode_start = std::chrono::steady_clock::now();
            try { buffer = decoder->decode(frame); }
            catch (const std::exception& error) {
                std::fprintf(stderr, "window decode recovering: %s\n", error.what());
                decoder = std::make_unique<Decoder>();
                if(frame.activity_epoch)presenter.output.push(viewflow::activity::pack_feedback({lane_index,true,false,lane_index==1,0,1}));
                return;
            }
            if (!buffer) return;
            const auto decoded_at = std::chrono::steady_clock::now();
            try {
                alpha_cache.update(frame);
                CIImage* composed = vm::join_planes(buffer, alpha_cache.mask);
                const auto alpha_revision = alpha_cache.revision*2+lane_index;
                // Synchronous handoff keeps these references alive without copying
                // the compressed frame and decoded alpha into an Objective-C block.
                const vf::Frame* frame_ptr = &frame;
                const std::span<const uint8_t> alpha_view(*alpha_cache.pixels);
                const auto prepared_at = std::chrono::steady_clock::now();
                auto main_started = prepared_at;
                auto* main_started_ptr = &main_started;
                const auto handoff = dispatch_semaphore_create(0);
                const auto* popup_arrivals_ptr=&popup_arrivals;
                CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
                    *main_started_ptr = std::chrono::steady_clock::now();
                    if (!owner->quitting) {
                        try { owner->present(*frame_ptr, composed, alpha_view, alpha_revision, blur_recipe, *popup_arrivals_ptr); }
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
    };
    std::unique_ptr<viewflow::activity::Workers> workers;
    if(viewflow::activity::negotiated())workers=std::make_unique<viewflow::activity::Workers>(process_frame,[&](auto hint){
        presenter.output.push(viewflow::activity::pack_feedback(hint));
    });
    Input input([&](std::vector<uint8_t> bytes){
        auto frame=vf::unpack_frame(bytes);
        if(workers)workers->push(std::move(frame));else process_frame(std::move(frame));
    }, [&] { input_ended = true; });
    while (transport_owner_alive() && !input_ended && presenter.output.alive()) {
        @autoreleasepool {
            NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                inMode:NSDefaultRunLoopMode dequeue:YES];
            presenter.update_pointer_regions();
            if (event) [NSApp sendEvent:event];
            presenter.draw_pending();
        }
    }
    presenter.quitting = true; input.stop();if(workers)workers->stop();
    while (!input.finished() || (workers && !workers->finished()) || presenter.outstanding != 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return 0;
}
}

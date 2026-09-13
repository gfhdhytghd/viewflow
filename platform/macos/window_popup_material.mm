#include "window_popup_material.hpp"
#include "window_parking.hpp"
#include <map>
#include <array>
#include <deque>
#include <cstdio>
#include <cmath>

@interface VFPopupBackdropWindow : NSWindow
@end
@implementation VFPopupBackdropWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface VFPopupMaterialOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property(copy) void (^frame)(CVPixelBufferRef, double);
@property(copy) void (^failure)(NSError*);
@end
@implementation VFPopupMaterialOutput
- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray* attachments = (__bridge NSArray*)CMSampleBufferGetSampleAttachmentsArray(sample, false);
    NSNumber* status = attachments.firstObject[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
    if (!pixels) return;
    const double timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
    CVPixelBufferRetain(pixels);
    VFPopupMaterialOutput* output = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (output.frame) output.frame(pixels, timestamp);
        CVPixelBufferRelease(pixels);
    });
}
- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    (void)stream;
    VFPopupMaterialOutput* output = self;
    dispatch_async(dispatch_get_main_queue(), ^{ if (output.failure) output.failure(error); });
}
@end

namespace viewflow::macos {
struct PopupPreview::State : std::enable_shared_from_this<PopupPreview::State> {
    SCDisplay* __strong display;
    SCStream* __strong stream = nil;
    VFPopupMaterialOutput* __strong output = nil;
    dispatch_queue_t queue = dispatch_queue_create("org.viewflow.popup-preview", DISPATCH_QUEUE_SERIAL);
    unsigned scale, fps;
    std::function<void(CIImage*, CGRect, double)> frame;
    bool stopped{}, failed{};
    double retry_after{};
    uint64_t generation{};
    State(SCDisplay* d, unsigned s, unsigned hz, std::function<void(CIImage*, CGRect, double)> f):display(d),scale(s),fps(hz),frame(std::move(f)) {}
    void stop_stream() {
        ++generation; output.frame=nil; output.failure=nil;
        if(stream)[stream stopCaptureWithCompletionHandler:^(NSError*){}];
        stream=nil;output=nil;
    }
    void start() {
        stop_stream(); failed=false;
        const auto epoch=generation;
        std::weak_ptr<State> weak=shared_from_this();
        auto filter=[[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        auto config=[SCStreamConfiguration new];
        config.width=static_cast<size_t>(display.frame.size.width*scale);
        config.height=static_cast<size_t>(display.frame.size.height*scale);
        std::fprintf(stderr,"popup-preview display=%u pixels=%zux%zu virtual-only=1\n",display.displayID,config.width,config.height);
        config.minimumFrameInterval=CMTimeMake(1,fps);config.pixelFormat=kCVPixelFormatType_32BGRA;
        config.colorSpaceName=kCGColorSpaceSRGB;config.showsCursor=NO;config.capturesAudio=NO;config.queueDepth=6;
        if(@available(macOS 14.0,*))config.ignoreShadowsDisplay=YES;
        output=[VFPopupMaterialOutput new];
        output.frame=^(CVPixelBufferRef pixels,double time){
            if(auto s=weak.lock();s&&!s->stopped&&s->generation==epoch&&s->frame)s->frame([CIImage imageWithCVPixelBuffer:pixels],s->display.frame,time);
        };
        output.failure=^(NSError* error){
            if(auto s=weak.lock();s&&!s->stopped&&s->generation==epoch){s->failed=true;s->retry_after=NSProcessInfo.processInfo.systemUptime+1;std::fprintf(stderr,"popup preview retry: %s\n",error.localizedDescription.UTF8String);}
        };
        stream=[[SCStream alloc] initWithFilter:filter configuration:config delegate:output];
        NSError* error=nil;
        if(![stream addStreamOutput:output type:SCStreamOutputTypeScreen sampleHandlerQueue:queue error:&error]){failed=true;retry_after=NSProcessInfo.processInfo.systemUptime+1;return;}
        [stream startCaptureWithCompletionHandler:^(NSError* error){
            if(error)dispatch_async(dispatch_get_main_queue(),^{if(auto s=weak.lock();s&&!s->stopped&&s->generation==epoch){s->failed=true;s->retry_after=NSProcessInfo.processInfo.systemUptime+1;}});
        }];
    }
};
PopupPreview::PopupPreview(SCDisplay* display,unsigned scale,unsigned fps,std::function<void(CIImage*,CGRect,double)> frame)
    :state_(std::make_shared<State>(display,scale,fps,std::move(frame))){state_->start();}
PopupPreview::~PopupPreview(){state_->stopped=true;state_->frame={};state_->stop_stream();}
void PopupPreview::recover(double now){if(state_->failed&&now>=state_->retry_after)state_->start();}

struct PopupMaterial::State : std::enable_shared_from_this<PopupMaterial::State> {
    struct Sample {
        CIImage* __strong image = nil;
        double time{};
        uint64_t sequence{};
    };
    SCDisplay* __strong display;
    SCWindow* __strong window;
    CGRect rect;
    unsigned width, height, fps;
    std::function<void()> changed;
    dispatch_queue_t queue = dispatch_queue_create("org.viewflow.popup-material", DISPATCH_QUEUE_SERIAL);
    std::array<SCStream* __strong, 2> streams{};
    std::array<VFPopupMaterialOutput* __strong, 2> outputs{};
    std::array<std::deque<Sample>, 2> samples;
    Sample mask;
    CGRect mask_body = CGRectNull;
    CIImage* __strong published = nil;
    CIColorKernel* __strong kernel = nil;
    uint64_t sequence{}, published_sequence{}, generation{}, paired{}, waiting{};
    double retry_after{}, report_at{};
    bool stopped{}, failed{};
    State(SCDisplay* d, SCWindow* w, CGRect bounds, unsigned x, unsigned y, unsigned hz, std::function<void()> notify)
        : display(d), window(w), rect(bounds), width(x), height(y), fps(hz), changed(std::move(notify)) {
        // Core Image executes this small point-wise operation on its Metal
        // context. No screen RGB is read back to the CPU.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        kernel = [CIColorKernel kernelWithString:@"kernel vec4 popupMaterial(__sample scene, __sample behind, __sample shape) { float a = shape.a; return vec4(clamp(scene.rgb - behind.rgb * (1.0-a), vec3(0.0), vec3(a)), a); }"];
#pragma clang diagnostic pop
    }
    void clear_streams() {
        ++generation;
        for (unsigned i = 0; i < 2; ++i) {
            outputs[i].frame = nil; outputs[i].failure = nil;
            if (streams[i]) [streams[i] stopCaptureWithCompletionHandler:^(NSError*) {}];
            streams[i] = nil; outputs[i] = nil; samples[i].clear();
        }
    }
    void start() {
        if (stopped || !kernel) return;
        clear_streams(); failed = false;
        const auto epoch = generation;
        std::weak_ptr<State> weak = shared_from_this();
        for (unsigned i = 1; i < 2; ++i) {
            SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:i == 0 ? @[] : @[window]];
            SCStreamConfiguration* config = [SCStreamConfiguration new];
            const double density=width/rect.size.width;
            config.width=static_cast<size_t>(std::lround(display.frame.size.width*density));
            config.height=static_cast<size_t>(std::lround(display.frame.size.height*density));
            config.minimumFrameInterval = CMTimeMake(1, fps);
            config.pixelFormat = kCVPixelFormatType_32BGRA;
            config.colorSpaceName = kCGColorSpaceSRGB;
            config.backgroundColor = CGColorGetConstantColor(kCGColorClear);
            config.showsCursor = NO; config.capturesAudio = NO;
            config.scalesToFit = YES;
            // Two history samples plus the published CI graph may retain
            // surfaces while the encoder finishes. Do not starve SCK's pool.
            config.queueDepth = 8;
            if (@available(macOS 14.0, *)) { config.shouldBeOpaque = NO; config.ignoreShadowsDisplay = YES; }
            outputs[i] = [VFPopupMaterialOutput new];
            outputs[i].frame = ^(CVPixelBufferRef pixels, double timestamp) {
                auto state = weak.lock();
                if (!state || state->stopped || state->generation != epoch || !std::isfinite(timestamp)) return;
                CIImage* image=[CIImage imageWithCVPixelBuffer:pixels];
                const CGRect display_bounds=state->display.frame;
                const double sx=image.extent.size.width/display_bounds.size.width;
                const double sy=image.extent.size.height/display_bounds.size.height;
                const CGRect crop=CGRectMake((state->rect.origin.x-display_bounds.origin.x)*sx,
                    image.extent.size.height-(CGRectGetMaxY(state->rect)-display_bounds.origin.y)*sy,
                    state->rect.size.width*sx,state->rect.size.height*sy);
                image=[[image imageByCroppingToRect:crop] imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x,-crop.origin.y)];
                auto& history = state->samples[i];
                history.push_back({image, timestamp, ++state->sequence});
                while (history.size() > 2) history.pop_front();
                state->pair();
            };
            outputs[i].failure = ^(NSError* error) {
                auto state = weak.lock();
                if (!state || state->stopped || state->generation != epoch) return;
                state->failed = true; state->retry_after = NSProcessInfo.processInfo.systemUptime + 1;
                std::fprintf(stderr, "popup-material window=%u auxiliary=%u recovering: %s\n", state->window.windowID, i, error.localizedDescription.UTF8String);
            };
            streams[i] = [[SCStream alloc] initWithFilter:filter configuration:config delegate:outputs[i]];
            NSError* error = nil;
            if (![streams[i] addStreamOutput:outputs[i] type:SCStreamOutputTypeScreen sampleHandlerQueue:queue error:&error]) {
                failed = true; retry_after = NSProcessInfo.processInfo.systemUptime + 1; continue;
            }
            [streams[i] startCaptureWithCompletionHandler:^(NSError* error) {
                if (!error) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (auto state = weak.lock(); state && !state->stopped && state->generation == epoch) {
                        state->failed = true; state->retry_after = NSProcessInfo.processInfo.systemUptime + 1;
                        std::fprintf(stderr, "popup-material window=%u start retry: %s\n", state->window.windowID, error.localizedDescription.UTF8String);
                    }
                });
            }];
        }
    }
    void pair() {
        if (stopped || samples[0].empty() || samples[1].empty() || !mask.image || CGRectIsNull(mask_body)) return;
        // A mask from the opening animation is not the expanded menu's
        // geometry. Keep the full-resolution preview until capture catches up.
        if (std::abs(mask_body.size.width - width) > 2 || std::abs(mask_body.size.height - height) > 2) return;
        const auto& scene = samples[0].back();
        if (scene.sequence == published_sequence) return;
        const double target_slack = 2.0 / fps;
        // Retain the last result until the display catches up to a changed
        // shape. This is a pairing target, never a connection timeout.
        if (mask.time > scene.time + target_slack) { ++waiting; return; }
        const Sample* behind = nullptr;
        for (const auto& candidate : samples[1])
            if (candidate.time <= scene.time + target_slack) behind = &candidate;
        if (!behind) { ++waiting; return; }
        CIImage* shape = [mask.image imageByCroppingToRect:mask_body];
        shape = [shape imageByApplyingTransform:CGAffineTransformMakeTranslation(-mask_body.origin.x, -mask_body.origin.y)];
        shape = [shape imageByApplyingTransform:CGAffineTransformMakeScale(width / mask_body.size.width, height / mask_body.size.height)];
        CIImage* body = [kernel applyWithExtent:CGRectMake(0, 0, width, height) arguments:@[scene.image, behind->image, shape]];
        if (!body) return;
        body = [body imageByApplyingTransform:CGAffineTransformMakeScale(mask_body.size.width / width, mask_body.size.height / height)];
        body = [body imageByApplyingTransform:CGAffineTransformMakeTranslation(mask_body.origin.x, mask_body.origin.y)];
        // Shadow-free window capture normally has no padding. Keep the source
        // extent exact for the existing atlas geometry and alpha pipeline.
        published = [body imageByCroppingToRect:mask.image.extent];
        published_sequence = scene.sequence; ++paired;
        if (paired == 10 && [[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/viewflow-popup-diagnostic"]) {
            CIContext* diagnostic = [CIContext context];
            CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            NSArray* images = @[scene.image, behind->image, mask.image, published];
            NSArray* labels = @[@"scene", @"behind", @"mask", @"material"];
            for (NSUInteger i=0;i<images.count;++i) {
                NSString* path=[NSString stringWithFormat:@"/tmp/viewflow-popup-%u-%@.png",window.windowID,labels[i]];
                [diagnostic writePNGRepresentationOfImage:images[i] toURL:[NSURL fileURLWithPath:path] format:kCIFormatRGBA8 colorSpace:color options:@{} error:nil];
            }
            CGColorSpaceRelease(color);
            std::fprintf(stderr,"popup diagnostic window=%u rect=%.1f,%.1f %.1fx%.1f output=%ux%u mask=%s\n",window.windowID,rect.origin.x,rect.origin.y,rect.size.width,rect.size.height,width,height,NSStringFromRect(mask_body).UTF8String);
        }
        if (changed) changed();
        const double now = NSProcessInfo.processInfo.systemUptime;
        if (!report_at || now - report_at >= 2) {
            std::fprintf(stderr, "popup-material window=%u paired=%llu waits=%llu delta-ms=%.2f extent=%ux%u\n", window.windowID,
                (unsigned long long)paired, (unsigned long long)waiting, (scene.time - behind->time) * 1000, width, height);
            report_at = now;
        }
    }
};
PopupMaterial::PopupMaterial(SCDisplay* display, SCWindow* window, CGRect bounds, unsigned width, unsigned height, unsigned fps, std::function<void()> changed)
    : state_(std::make_shared<State>(display, window, bounds, width, height, fps, std::move(changed))) { state_->start(); }
PopupMaterial::~PopupMaterial() { stop(); }
void PopupMaterial::stop() { if (state_ && !state_->stopped) { state_->stopped = true; state_->changed = {}; state_->clear_streams(); } }
void PopupMaterial::shape(CVPixelBufferRef pixels, CGRect body, double timestamp) {
    if (state_->stopped || !pixels || !std::isfinite(timestamp)) return;
    state_->mask = {[CIImage imageWithCVPixelBuffer:pixels], timestamp, 0};
    const double h = CVPixelBufferGetHeight(pixels);
    state_->mask_body = CGRectMake(body.origin.x, h - CGRectGetMaxY(body), body.size.width, body.size.height);
    state_->pair();
}
void PopupMaterial::scene(CIImage* image, CGRect display_bounds, double timestamp) {
    if(state_->stopped || !CGRectContainsRect(display_bounds,state_->rect))return;
    const double sx=image.extent.size.width/display_bounds.size.width, sy=image.extent.size.height/display_bounds.size.height;
    CGRect crop=CGRectMake((state_->rect.origin.x-display_bounds.origin.x)*sx,
        image.extent.size.height-(CGRectGetMaxY(state_->rect)-display_bounds.origin.y)*sy,state_->rect.size.width*sx,state_->rect.size.height*sy);
    image=[[image imageByCroppingToRect:crop] imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x,-crop.origin.y)];
    auto& history=state_->samples[0];history.push_back({image,timestamp,++state_->sequence});
    while(history.size()>2)history.pop_front();state_->pair();
}
CIImage* PopupMaterial::image() const { return state_->published; }
CGRect PopupMaterial::bounds() const { return state_->rect; }
void PopupMaterial::recover(double now) { if (state_->failed && now >= state_->retry_after) state_->start(); }
struct DesktopBackdrop::State {
    struct Screen {
        VFPopupBackdropWindow* __strong window = nil;
        NSImageView* __strong image = nil;
    };
    std::map<CGDirectDisplayID, Screen> screens;
};
DesktopBackdrop::DesktopBackdrop():state_(std::make_unique<State>()) {}
DesktopBackdrop::~DesktopBackdrop(){clear();}
void DesktopBackdrop::clear(){
    for(auto& [_, screen]:state_->screens){[screen.window orderOut:nil];[screen.window close];}
    state_->screens.clear();
}
void DesktopBackdrop::update(NSImage* image, CGRect bounds){
    if(!image || CGRectIsEmpty(bounds))return;
    CGDirectDisplayID displays[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess)return;
    const double main_height=CGDisplayBounds(CGMainDisplayID()).size.height;
    for(uint32_t i=0;i<count;++i){
        if(!is_parking_display(displays[i]))continue;
        const CGRect screen_bounds=CGDisplayBounds(displays[i]);
        if(!CGRectIntersectsRect(screen_bounds,bounds))continue;
        auto& screen=state_->screens[displays[i]];
        const NSRect frame=NSMakeRect(screen_bounds.origin.x,main_height-CGRectGetMaxY(screen_bounds),screen_bounds.size.width,screen_bounds.size.height);
        if(!screen.window){
            screen.window=[[VFPopupBackdropWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            screen.window.releasedWhenClosed=NO;screen.window.ignoresMouseEvents=YES;screen.window.hasShadow=NO;
            // A fixed level below ordinary application windows, above desktop content.
            screen.window.level=NSNormalWindowLevel-1;
            screen.window.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle;
            screen.window.backgroundColor=NSColor.blackColor;
            screen.window.contentView.wantsLayer=YES;screen.window.contentView.layer.masksToBounds=YES;
            screen.image=[NSImageView new];screen.image.imageScaling=NSImageScaleAxesIndependently;
            [screen.window.contentView addSubview:screen.image];
            std::fprintf(stderr,"desktop-backdrop level=-1 display=%u bounds=%.0f,%.0f %.0fx%.0f\n",displays[i],screen_bounds.origin.x,screen_bounds.origin.y,screen_bounds.size.width,screen_bounds.size.height);
        }
        [screen.window setFrame:frame display:NO];
        screen.image.frame=NSMakeRect(bounds.origin.x-screen_bounds.origin.x,CGRectGetMaxY(screen_bounds)-CGRectGetMaxY(bounds),bounds.size.width,bounds.size.height);
        screen.image.image=image;
        [screen.window orderBack:nil];
    }
}

}

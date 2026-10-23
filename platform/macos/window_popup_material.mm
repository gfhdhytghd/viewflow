#include "window_popup_material.hpp"
#include "window_parking.hpp"
#include "../reverse-common/popup_capture_budget.hpp"
#include <map>
#include <array>
#include <deque>
#include <cstdio>
#include <cmath>
#include <dlfcn.h>
#include <set>
#include <vector>
#include <algorithm>

@interface VFPopupBackdropWindow : NSWindow
@end
@implementation VFPopupBackdropWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface VFPopupMaterialOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property(copy) void (^frame)(CVPixelBufferRef, double);
@property(copy) void (^failure)(NSError*);
@property CGRect expectedBounds;
@property BOOL reportedMapping;
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
    CGRect actual = CGRectNull;
    NSDictionary* screen = nil;
    if (@available(macOS 13.1, *)) screen = attachments.firstObject[SCStreamFrameInfoScreenRect];
    const bool mapped = screen && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)screen, &actual) &&
        std::abs(actual.origin.x-self.expectedBounds.origin.x)<1 && std::abs(actual.origin.y-self.expectedBounds.origin.y)<1 &&
        std::abs(actual.size.width-self.expectedBounds.size.width)<1 && std::abs(actual.size.height-self.expectedBounds.size.height)<1;
    if (!self.reportedMapping) {
        self.reportedMapping = YES;
        std::fprintf(stderr,"popup-display-map expected=%s actual=%s matched=%d\n",NSStringFromRect(self.expectedBounds).UTF8String,NSStringFromRect(actual).UTF8String,mapped);
    }
    const double timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
    CVPixelBufferRetain(pixels);
    VFPopupMaterialOutput* output = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        // A virtual display can be substituted by SCK. Keep the popup's own
        // window capture usable instead of compositing unrelated screen RGB.
        if (output.frame) output.frame(mapped ? pixels : nullptr, timestamp);
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
// Main-run-loop owned. Do not keep capturing an unrelated full display after
// its mapping has been disproved; menus on it use bounded region capture.
static std::set<CGDirectDisplayID> region_displays;
static reverse::PopupCaptureBudget region_budget;
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
        output.expectedBounds=display.frame;
        output.frame=^(CVPixelBufferRef pixels,double time){
            if(auto s=weak.lock();s&&!s->stopped&&s->generation==epoch){
                if(s->frame)s->frame(pixels ? [CIImage imageWithCVPixelBuffer:pixels] : nil,s->display.frame,time);
                if(!pixels){region_displays.insert(s->display.displayID);s->stop_stream();}
            }
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
    dispatch_queue_t queue = dispatch_queue_create("org.viewflow.popup-material", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
    std::array<SCStream* __strong, 2> streams{};
    std::array<VFPopupMaterialOutput* __strong, 2> outputs{};
    std::array<std::deque<Sample>, 2> samples;
    Sample mask;
    CGRect mask_body = CGRectNull;
    CIImage* __strong published = nil;
    CIColorKernel* __strong kernel = nil;
    uint64_t sequence{}, published_sequence{}, generation{}, paired{}, waiting{};
    double retry_after{}, report_at{}, next_region{};
    bool stopped{}, failed{}, region_requested{}, region_mode{}, region_busy{};
    using RegionCapture=CGImageRef(*)(CGRect,CGWindowListOption,CGWindowID,CGWindowImageOption);
    RegionCapture region_capture=reinterpret_cast<RegionCapture>(dlsym(RTLD_DEFAULT,"CGWindowListCreateImage"));
    double region_report_at{};
    unsigned region_completed{}, region_skipped{};
    std::vector<double> region_costs, region_delivery_costs;
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
        if(region_capture && region_displays.contains(display.displayID)){
            region_mode=true;
            region_budget.add(window.windowID);
            std::fprintf(stderr,"popup-material window=%u native-region capture enabled\n",window.windowID);
            return;
        }
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
            outputs[i].expectedBounds=display.frame;
            outputs[i].frame = ^(CVPixelBufferRef pixels, double timestamp) {
                auto state = weak.lock();
                if (!state || state->stopped || state->generation != epoch || !std::isfinite(timestamp)) return;
                if (!pixels) {
                    // Some macOS virtual-display streams silently return the
                    // main display. Capture this menu's global rectangle and
                    // the windows below it instead; both keep native material.
                    state->region_requested=true;
                    const bool had_material = state->published != nil;
                    state->samples[i].clear();state->published=nil;
                    if(had_material && state->changed)state->changed();
                    return;
                }
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
    void capture_region(double now) {
        if(stopped || now<next_region || !region_capture)return;
        if(region_busy){++region_skipped;return;}
        if(!region_budget.begin(window.windowID,now)){++region_skipped;return;}
        if(!region_report_at)region_report_at=now;
        region_busy=true;next_region=now+1.0/std::min(reverse::PopupCaptureBudget::frames_per_second,fps);
        const auto epoch=generation;
        const auto capture=region_capture;
        const auto bounds=rect;
        const auto native=window.windowID;
        std::weak_ptr<State> weak=shared_from_this();
        dispatch_async(queue,^{
            @autoreleasepool {
                const double started=NSProcessInfo.processInfo.systemUptime;
                // IncludingWindow anchors the composition to the requested
                // menu, excluding unrelated windows above it. No window is
                // hidden, moved or activated to obtain either image.
                __block CGImageRef scene=nullptr,behind=nullptr;
                auto group=dispatch_group_create();
                const auto capture_queue=dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0);
                dispatch_group_async(group,capture_queue,^{scene=capture(bounds,kCGWindowListOptionOnScreenBelowWindow|kCGWindowListOptionIncludingWindow,native,kCGWindowImageBoundsIgnoreFraming|kCGWindowImageBestResolution);});
                dispatch_group_async(group,capture_queue,^{behind=capture(bounds,kCGWindowListOptionOnScreenBelowWindow,native,kCGWindowImageBoundsIgnoreFraming|kCGWindowImageBestResolution);});
                dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
                const double completed=NSProcessInfo.processInfo.systemUptime;
                dispatch_async(dispatch_get_main_queue(),^{
                    region_budget.complete();
                    auto state=weak.lock();
                    if(state && !state->stopped && state->generation==epoch){
                        state->region_busy=false;
                        if(scene && behind){
                            for(unsigned i=0;i<2;++i){
                                CIImage* image=[CIImage imageWithCGImage:i==0?scene:behind];
                                image=[image imageByApplyingTransform:CGAffineTransformMakeScale(state->width/image.extent.size.width,state->height/image.extent.size.height)];
                                auto& history=state->samples[i];
                                history.push_back({image,completed,++state->sequence});
                                while(history.size()>2)history.pop_front();
                            }
                            state->pair();
                            ++state->region_completed;
                            state->region_costs.push_back((completed-started)*1000);
                            state->region_delivery_costs.push_back((NSProcessInfo.processInfo.systemUptime-started)*1000);
                            if(state->region_costs.size()>120){state->region_costs.erase(state->region_costs.begin());state->region_delivery_costs.erase(state->region_delivery_costs.begin());}
                            if(completed-state->region_report_at>=2){
                                auto costs=state->region_costs;std::sort(costs.begin(),costs.end());
                                auto delivery=state->region_delivery_costs;std::sort(delivery.begin(),delivery.end());
                                const auto p95=std::min(costs.size()-1,costs.size()*95/100);
                                std::fprintf(stderr,"popup-region window=%u fps=%.2f capture-p50-ms=%.2f capture-p95-ms=%.2f delivery-p95-ms=%.2f budget-skips=%u queue=1 total-fps-limit=30 bounds=%.0f,%.0f %.0fx%.0f\n",native,state->region_completed/(completed-state->region_report_at),costs[costs.size()/2],costs[p95],delivery[p95],state->region_skipped,bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height);
                                state->region_report_at=completed;state->region_completed=0;state->region_skipped=0;state->region_costs.clear();state->region_delivery_costs.clear();
                            }
                        }
                    }
                    if(scene)CGImageRelease(scene);
                    if(behind)CGImageRelease(behind);
                    if(state && !state->stopped && state->generation==epoch)state->capture_region(NSProcessInfo.processInfo.systemUptime);
                });
            }
        });
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
            NSArray* images = @[scene.image, behind->image, mask.image, published];
            NSArray* labels = @[@"scene", @"behind", @"mask", @"material"];
            const auto native=window.windowID;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
                CIContext* diagnostic = [CIContext context];
                CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                for (NSUInteger i=0;i<images.count;++i) {
                    NSString* path=[NSString stringWithFormat:@"/tmp/viewflow-popup-%u-%@.png",native,labels[i]];
                    [diagnostic writePNGRepresentationOfImage:images[i] toURL:[NSURL fileURLWithPath:path] format:kCIFormatRGBA8 colorSpace:color options:@{} error:nil];
                }
                CGColorSpaceRelease(color);
            });
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
void PopupMaterial::stop() { if (state_ && !state_->stopped) { state_->stopped = true; if(state_->region_mode)region_budget.remove(state_->window.windowID);state_->changed = {}; state_->clear_streams(); } }
void PopupMaterial::shape(CVPixelBufferRef pixels, CGRect body, double timestamp) {
    if (state_->stopped || !pixels || !std::isfinite(timestamp)) return;
    state_->mask = {[CIImage imageWithCVPixelBuffer:pixels], timestamp, 0};
    const double h = CVPixelBufferGetHeight(pixels);
    state_->mask_body = CGRectMake(body.origin.x, h - CGRectGetMaxY(body), body.size.width, body.size.height);
    state_->pair();
}
void PopupMaterial::scene(CIImage* image, CGRect display_bounds, double timestamp) {
    if(state_->region_requested || state_->region_mode)return;
    if (!image) { state_->samples[0].clear();state_->published=nil;return; }
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
void PopupMaterial::recover(double now) {
    if(state_->region_requested && !state_->region_mode && state_->region_capture){
        state_->clear_streams();state_->region_mode=true;state_->failed=false;
        region_budget.add(state_->window.windowID);
        std::fprintf(stderr,"popup-material window=%u native-region capture enabled\n",state_->window.windowID);
    }
    if(state_->region_mode)state_->capture_region(now);
    else if(state_->failed && now>=state_->retry_after)state_->start();
}
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

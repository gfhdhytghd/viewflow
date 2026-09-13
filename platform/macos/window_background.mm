#include "window_background.hpp"
#include "window_blur_shader.hpp"
#include "window_blur_reference.hpp"
#include "../windows-composition-preview/background_region.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <simd/simd.h>
#include <map>
#include <mutex>
#include <set>
#include <atomic>

@interface VFBackdropOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property(copy) void (^sample)(CMSampleBufferRef);
@property(copy) void (^failure)(NSError*);
@end
@implementation VFBackdropOutput
- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type == SCStreamOutputTypeScreen && CMSampleBufferIsValid(sample) && self.sample) self.sample(sample);
}
- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    (void)stream; if (self.failure) self.failure(error);
}
@end

namespace viewflow::macos {
namespace bg = viewflow::background;
namespace {
struct Params {
    simd_float2 texel{};
    float radius{5}, passes{4}, contrast{.8916f}, brightness{1}, noise{.0117f}, vibrancy{.1696f};
    float vibrancy_darkness{}, unused{};
    simd_float2 noise_origin{}, noise_scale{1,1}, reserved{};
};
static_assert(sizeof(Params) == 64);
struct Blur {
    struct Pool {
        std::mutex mutex;
        std::vector<id<MTLTexture>> textures;
        size_t bytes{};
    };
    std::shared_ptr<Pool> pool=std::make_shared<Pool>();
    id<MTLDevice> device;
    id<MTLCommandQueue> commands;
    CIContext* context;
    MPSImageGaussianBlur* gaussian;
    CGColorSpaceRef colors = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    id<MTLRenderPipelineState> pipelines[4];
    explicit Blur(id<MTLDevice> d,float sigma=12) : device(d) {
        commands=[d newCommandQueue];
        context=[CIContext contextWithMTLDevice:d options:@{kCIContextWorkingColorSpace:(__bridge id)colors}];
        gaussian=[[MPSImageGaussianBlur alloc] initWithDevice:d sigma:sigma];
        gaussian.edgeMode=MPSImageEdgeModeClamp;
        NSError* error=nil;
        id<MTLLibrary> library=[d newLibraryWithSource:@(kWindowBlurMetal) options:nil error:&error];
        if (!library) throw std::runtime_error(error.localizedDescription.UTF8String);
        NSArray<NSString*>* names=@[@"prepare",@"down",@"up",@"finish"];
        for (unsigned i=0;i<4;++i) {
            MTLRenderPipelineDescriptor* desc=[MTLRenderPipelineDescriptor new];
            desc.vertexFunction=[library newFunctionWithName:@"vs"];
            desc.fragmentFunction=[library newFunctionWithName:names[i]];
            desc.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
            pipelines[i]=[d newRenderPipelineStateWithDescriptor:desc error:&error];
            if (!pipelines[i]) throw std::runtime_error(error.localizedDescription.UTF8String);
        }
    }
    ~Blur() { CGColorSpaceRelease(colors); }
    id<MTLTexture> texture(unsigned w,unsigned h) {
        {
            std::lock_guard lock(pool->mutex);
            for(auto it=pool->textures.begin();it!=pool->textures.end();++it)
                if((*it).width==w&&(*it).height==h) {
                    id<MTLTexture> result=*it;pool->textures.erase(it);pool->bytes-=size_t(w)*h*4;return result;
                }
        }
        auto* desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
        desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget|MTLTextureUsageShaderWrite;
        desc.storageMode=MTLStorageModePrivate;
        id<MTLTexture> result=[device newTextureWithDescriptor:desc];
        if (!result) throw std::runtime_error("background texture allocation");
        return result;
    }
    id<MTLTexture> encode(CIImage* image, Params p, id<MTLCommandBuffer> command) {
        unsigned w=std::lround(image.extent.size.width),h=std::lround(image.extent.size.height);
        id<MTLTexture> current=texture(w,h);
        auto scratch=std::make_shared<std::vector<id<MTLTexture>>>();
        [context render:image toMTLTexture:current commandBuffer:command bounds:CGRectMake(0,0,w,h) colorSpace:colors];
        auto pass=[&](unsigned shader,unsigned width,unsigned height) {
            id<MTLTexture> next=texture(width,height);
            auto* desc=[MTLRenderPassDescriptor renderPassDescriptor];
            desc.colorAttachments[0].texture=next;
            desc.colorAttachments[0].loadAction=MTLLoadActionDontCare;
            desc.colorAttachments[0].storeAction=MTLStoreActionStore;
            id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:desc];
            p.texel={1.f/current.width,1.f/current.height};
            [encoder setRenderPipelineState:pipelines[shader]];
            [encoder setFragmentTexture:current atIndex:0];
            [encoder setFragmentBytes:&p length:sizeof(p) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];scratch->push_back(current);current=next;
        };
        pass(0,w,h);
        std::vector<std::pair<unsigned,unsigned>> levels{{w,h}};
        for(unsigned i=0;i<unsigned(p.passes);++i) {
            auto [x,y]=levels.back();levels.emplace_back(std::max(1u,(x+1)/2),std::max(1u,(y+1)/2));
            pass(1,levels.back().first,levels.back().second);
        }
        for(int i=int(p.passes)-1;i>=0;--i)pass(2,levels[i].first,levels[i].second);
        pass(3,w,h);
        auto returned=pool;
        [command addCompletedHandler:^(id<MTLCommandBuffer>){
            std::lock_guard lock(returned->mutex);
            for(id<MTLTexture> item:*scratch) {
                size_t bytes=item.width*item.height*4;
                if(returned->bytes+bytes<=128u*1024u*1024u) {
                    returned->textures.push_back(item);returned->bytes+=bytes;
                }
            }
        }];
        return current;
    }
    id<MTLTexture> encodeGaussian(CIImage* image,id<MTLCommandBuffer> command) {
        unsigned w=std::lround(image.extent.size.width),h=std::lround(image.extent.size.height);
        id<MTLTexture> input=texture(w,h),output=texture(w,h);
        [context render:image toMTLTexture:input commandBuffer:command bounds:CGRectMake(0,0,w,h) colorSpace:colors];
        [gaussian encodeToCommandBuffer:command sourceTexture:input destinationTexture:output];
        auto returned=pool;
        [command addCompletedHandler:^(id<MTLCommandBuffer>){
            std::lock_guard lock(returned->mutex);size_t bytes=input.width*input.height*4;
            if(returned->bytes+bytes<=128u*1024u*1024u){returned->textures.push_back(input);returned->bytes+=bytes;}
        }];
        return output;
    }
};
struct DisplayRequest {
    CGDirectDisplayID id{};
    CGRect bounds{};
    double scale{};
    bg::Rect desktop{},window{};
    double velocity_x{},velocity_y{};
};
struct Snapshot {
    CIImage* image=nil;
    CGRect bounds{}; // global Quartz points, top down
    double scale{};
    bg::Rect region{},desktop{};
    int64_t kernel{};
    uint64_t revision{};
};
struct Capture {
    SCStream* stream=nil;
    VFBackdropOutput* output=nil;
    DisplayRequest request;
    bg::Rect region{};
    std::vector<unsigned> excluded;
    bool starting{},busy{},failed{};
    double created_at=CACurrentMediaTime();
    bool sampled{};
    bool updating_filter{};
    uint64_t filter_revision{};
    std::shared_ptr<Capture> previous;
    bool published{};
    CMSampleBufferRef latest{};
    ~Capture() {
        if(latest)CFRelease(latest);
        output.sample=nil;output.failure=nil;
        [stream stopCaptureWithCompletionHandler:^(NSError*){}];
    }
};
bg::Rect pixels(CGRect rect,CGRect display,double scale) {
    return {int64_t(std::floor((CGRectGetMinX(rect)-display.origin.x)*scale)),
        int64_t(std::floor((CGRectGetMinY(rect)-display.origin.y)*scale)),
        int64_t(std::ceil((CGRectGetMaxX(rect)-display.origin.x)*scale)),
        int64_t(std::ceil((CGRectGetMaxY(rect)-display.origin.y)*scale))};
}
}
struct WindowBackground::State : std::enable_shared_from_this<State> {
    dispatch_queue_t queue=dispatch_queue_create("org.viewflow.window-background",DISPATCH_QUEUE_SERIAL);
    id<MTLDevice> device;
    std::unique_ptr<Blur> blur;
    std::map<unsigned,std::shared_ptr<Capture>> captures;
    std::mutex mutex;
    std::map<unsigned,Snapshot> snapshots;
    SCShareableContent* content=nil;
    bool inventory_pending{};
    std::atomic_bool stopped{};
    std::atomic_bool request_pending{};
    double next_request{},retry_after{};
    double last_geometry_time{};
    std::map<unsigned,bg::Rect> last_geometry;
    uint64_t revision{};
    std::set<unsigned> queried_missing;
    float sigma=12;
    bool hyprland{};
    int64_t kernel{};
    Params settings;
    uint64_t settings_revision{};
    std::atomic_bool enabled{true};
    explicit State(id<MTLDevice> d):device(d){
        if(const char* value=std::getenv("VIEWFLOW_ATLAS_BACKGROUND_CACHE"))hyprland=std::string_view(value)=="1";
        if(const char* value=std::getenv("VIEWFLOW_ATLAS_BLUR_SIGMA")) {
            char* end=nullptr;double parsed=std::strtod(value,&end);
            if(end==value||*end||!std::isfinite(parsed)||parsed<0||parsed>64)throw std::runtime_error("atlas blur sigma must be between 0 and 64 physical pixels");
            sigma=parsed;
        }
        kernel=hyprland?bg::hyprland_support(5,4):int64_t(std::ceil(4*sigma))+2;
        enabled=sigma>0;
    }
    void inventory() {
        if(inventory_pending||CACurrentMediaTime()<retry_after)return;
        retry_after=CACurrentMediaTime()+1;
        inventory_pending=true;auto self=shared_from_this();
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO completionHandler:^(SCShareableContent* result,NSError* error){
            dispatch_async(self->queue,^{
                self->inventory_pending=false;
                if(self->stopped)return;
                if(error) {
                    std::fprintf(stderr,"background inventory recovering: %s\n",error.localizedDescription.UTF8String);
                    self->retry_after=CACurrentMediaTime()+1;
                } else self->content=result;
            });
        }];
    }
    void update(std::vector<DisplayRequest> requests,unsigned target) {
        if(stopped)return;
        std::vector<unsigned> excluded;
        if(!requests.empty()) {
            // WindowServer inventory can block. Keep it off AppKit's input loop.
            NSArray* list=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
            bool found=false;
            for(NSDictionary* item in list) {
                unsigned number=[item[(__bridge NSString*)kCGWindowNumber] unsignedIntValue];
                if(number==target){excluded.push_back(number);found=true;break;}
                CGRect bounds{};
                if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)item[(__bridge NSString*)kCGWindowBounds],&bounds))continue;
                if([item[(__bridge NSString*)kCGWindowAlpha] doubleValue]<=0)continue;
                bool overlaps=false;
                for(const auto& request:requests) {
                    auto plan=bg::plan(request.window,request.desktop,kernel,request.velocity_x,request.velocity_y);
                    if(!bg::intersect(pixels(bounds,request.bounds,request.scale),plan.bounds).empty()){overlaps=true;break;}
                }
                if(overlaps)excluded.push_back(number);
            }
            if(!found)requests.clear();
            std::sort(excluded.begin(),excluded.end());
        }
        if(requests.empty()) {
            captures.clear();std::lock_guard lock(mutex);snapshots.clear();return;
        }
        if(!content){inventory();return;}
        std::set<unsigned> known;
        for(SCWindow* window in content.windows)known.insert(window.windowID);
        std::set<unsigned> missing;
        for(unsigned id:excluded)if(!known.contains(id))missing.insert(id);
        if(missing!=queried_missing){queried_missing=missing;inventory();return;}
        // Non-shareable system overlays can be absent from SCShareableContent.
        // The proxy itself must be represented to establish the correct cut.
        if(!known.contains(target)){inventory();return;}
        std::set<unsigned> live;
        for(auto request:requests) {
            live.insert(request.id);
            SCDisplay* display=nil;
            for(SCDisplay* candidate in content.displays)if(candidate.displayID==request.id)display=candidate;
            if(!display){inventory();continue;}
            auto found=captures.find(request.id);
            std::shared_ptr<Capture> previous;
            if(found!=captures.end()) {
                auto c=found->second;
                if(!c->sampled&&CACurrentMediaTime()-c->created_at>5)c->failed=true;
                if(c->failed&&CACurrentMediaTime()-c->created_at<1)continue;
                if(!c->failed && c->request.scale==request.scale &&
                   !bg::needs_urgent_refresh(c->region,request.window,request.desktop,kernel)) {
                    if(c->excluded!=excluded&&!c->updating_filter) {
                        NSMutableArray<SCWindow*>* windows=[NSMutableArray array];
                        for(SCWindow* window in content.windows)
                            if(std::find(excluded.begin(),excluded.end(),window.windowID)!=excluded.end())[windows addObject:window];
                        auto* filter=[[SCContentFilter alloc] initWithDisplay:display excludingWindows:windows];
                        c->updating_filter=true;++c->filter_revision;
                        auto self=shared_from_this();
                        [c->stream updateContentFilter:filter completionHandler:^(NSError* error){
                            dispatch_async(self->queue,^{
                                c->updating_filter=false;
                                if(error)c->failed=true;else c->excluded=excluded;
                            });
                        }];
                    }
                    continue;
                }
                if(c->request.scale!=request.scale) {
                    std::lock_guard lock(mutex);snapshots.erase(request.id);
                } else if(!c->failed) {
                    previous=c->published?c:c->previous;
                }
                captures.erase(found);
            }
            auto plan=bg::plan(request.window,request.desktop,kernel,request.velocity_x,request.velocity_y);
            if(!plan.fits_texture||plan.bounds.empty())continue;
            NSMutableArray<SCWindow*>* windows=[NSMutableArray array];
            for(SCWindow* window in content.windows)
                if(std::find(excluded.begin(),excluded.end(),window.windowID)!=excluded.end())[windows addObject:window];
            auto c=std::make_shared<Capture>();c->request=request;c->region=plan.bounds;c->excluded=excluded;c->previous=previous;
            c->output=[VFBackdropOutput new];c->starting=true;
            auto weak=weak_from_this();std::weak_ptr<Capture> capture=c;
            c->output.sample=^(CMSampleBufferRef sample) {
                auto self=weak.lock();auto current=capture.lock();
                if(!self||self->stopped||!current||current->busy||current->updating_filter)return;
                auto attachments=(__bridge NSArray*)CMSampleBufferGetSampleAttachmentsArray(sample,false);
                NSNumber* status=attachments.count?attachments[0][SCStreamFrameInfoStatus]:nil;
                if(status&&status.integerValue!=SCFrameStatusComplete)return;
                auto buffer=CMSampleBufferGetImageBuffer(sample);if(!buffer)return;
                if(current->latest!=sample) {
                    CFRetain(sample);if(current->latest)CFRelease(current->latest);current->latest=sample;
                }
                current->sampled=true;
                auto filter_revision=current->filter_revision;
                auto settings_revision=self->settings_revision;
                current->busy=true;
                @autoreleasepool {
                    try {
                        if(!self->blur)self->blur=std::make_unique<Blur>(self->device,self->sigma);
                        auto& blur=*self->blur;
                        CIImage* input=[CIImage imageWithCVPixelBuffer:buffer];
                        Params params=self->settings;auto region=current->region;auto desktop=current->request.desktop;
                        params.noise_origin={float(region.left)/desktop.width(),float(region.top)/desktop.height()};
                        params.noise_scale={float(region.width())/desktop.width(),float(region.height())/desktop.height()};
                        id<MTLCommandBuffer> command=[blur.commands commandBuffer];
                        auto texture=self->hyprland?blur.encode(input,params,command):blur.encodeGaussian(input,command);
                        // CIContext's Metal render and CIImage's Metal import
                        // agree on orientation; no extra vertical flip (tested).
                        CIImage* result=[CIImage imageWithMTLTexture:texture options:@{kCIImageColorSpace:(__bridge id)blur.colors}];
                        __block CIImage* retained_input=input;
                        [command addCompletedHandler:^(id<MTLCommandBuffer> done){
                            retained_input=nil;
                            dispatch_async(self->queue,^{
                                current->busy=false;
                                auto it=self->captures.find(current->request.id);
                                if(self->stopped||it==self->captures.end()||
                                    (it->second!=current&&it->second->previous!=current)||current->filter_revision!=filter_revision)return;
                                if(self->settings_revision!=settings_revision) {
                                    if(current->latest&&current->output.sample)current->output.sample(current->latest);
                                    return;
                                }
                                if(done.status==MTLCommandBufferStatusError){current->failed=true;return;}
                                current->published=true;current->previous.reset();
                                std::lock_guard lock(self->mutex);
                                if(!self->snapshots.contains(current->request.id))
                                    std::fprintf(stderr,"macos-window-background display=%u pixels=%lldx%lld exclusions=%zu backend=sck-metal algorithm=%s sigma=%.1f-physical-pixels\n",
                                        current->request.id,(long long)current->region.width(),(long long)current->region.height(),current->excluded.size(),
                                        self->hyprland?"hyprland-dual-kawase":"gaussian",self->sigma);
                                self->snapshots[current->request.id]={result,current->request.bounds,current->request.scale,
                                    current->region,current->request.desktop,self->kernel,++self->revision};
                            });
                        }];
                        [command commit];
                    } catch(const std::exception& error) {
                        current->busy=false;current->failed=true;
                        std::fprintf(stderr,"background GPU recovering: %s\n",error.what());
                    }
                }
            };
            c->output.failure=^(NSError* error){
                if(auto self=weak.lock())dispatch_async(self->queue,^{
                    if(auto current=capture.lock())current->failed=true;
                    std::fprintf(stderr,"background capture recovering code=%ld: %s\n",(long)error.code,error.localizedDescription.UTF8String);
                });
            };
            auto* config=[SCStreamConfiguration new];
            config.width=plan.bounds.width();config.height=plan.bounds.height();
            config.sourceRect=CGRectMake(plan.bounds.left/request.scale,plan.bounds.top/request.scale,
                plan.bounds.width()/request.scale,plan.bounds.height()/request.scale);
            config.minimumFrameInterval=CMTimeMake(1,30);config.queueDepth=3;
            config.pixelFormat=kCVPixelFormatType_32BGRA;config.showsCursor=NO;config.capturesAudio=NO;
            config.colorSpaceName=kCGColorSpaceSRGB;
            auto* filter=[[SCContentFilter alloc] initWithDisplay:display excludingWindows:windows];
            c->stream=[[SCStream alloc] initWithFilter:filter configuration:config delegate:c->output];
            NSError* error=nil;
            if(![c->stream addStreamOutput:c->output type:SCStreamOutputTypeScreen sampleHandlerQueue:queue error:&error])continue;
            captures[request.id]=c;
            std::fprintf(stderr,"background capture starting target=%u display=%u region=%lld,%lld %lldx%lld excluded=%zu\n",
                target,request.id,(long long)plan.bounds.left,(long long)plan.bounds.top,
                (long long)plan.bounds.width(),(long long)plan.bounds.height(),excluded.size());
            [c->stream startCaptureWithCompletionHandler:^(NSError* error){
                if(auto self=weak.lock())dispatch_async(self->queue,^{
                    if(auto current=capture.lock()) {
                        current->starting=false;current->failed=current->failed||error!=nil;
                        if(error)std::fprintf(stderr,"background start recovering: %s\n",error.localizedDescription.UTF8String);
                    }
                });
            }];
        }
        for(auto it=captures.begin();it!=captures.end();)if(!live.contains(it->first))it=captures.erase(it);else ++it;
        std::lock_guard lock(mutex);
        for(auto it=snapshots.begin();it!=snapshots.end();)if(!live.contains(it->first))it=snapshots.erase(it);else ++it;
    }
};
WindowBackground::WindowBackground(id<MTLDevice> device):state(std::make_shared<State>(device)){}
WindowBackground::~WindowBackground() {
    auto s=state;s->stopped=true;
    dispatch_async(s->queue,^{s->captures.clear();s->blur.reset();});
}
void WindowBackground::configure(const std::optional<reverse::BlurRecipe>& recipe) {
    if(!recipe||configured_recipe==recipe)return;
    configured_recipe=recipe;auto s=state;auto value=*recipe;
    dispatch_async(s->queue,^{
        if(s->stopped)return;
        s->hyprland=true;s->enabled=value.enabled;++s->settings_revision;
        s->settings.radius=value.size;s->settings.passes=value.passes;
        s->settings.contrast=value.contrast;s->settings.brightness=value.brightness;s->settings.noise=value.noise;
        s->settings.vibrancy=value.vibrancy;s->settings.vibrancy_darkness=value.vibrancy_darkness;
        s->kernel=value.support();
        std::fprintf(stderr,"macos-source-blur enabled=%d size=%u passes=%u contrast=%.6f brightness=%.6f noise=%.6f vibrancy=%.6f vibrancy-darkness=%.6f source=hyprland\n",
            int(value.enabled),value.size,value.passes,value.contrast,value.brightness,value.noise,value.vibrancy,value.vibrancy_darkness);
        if(!value.enabled){s->captures.clear();std::lock_guard lock(s->mutex);s->snapshots.clear();return;}
        // Reblur the retained capture even when the host background is static.
        // If a submission is busy, its completion observes settings_revision.
        for(auto& [id,capture]:s->captures) {
            (void)id;
            if(capture->latest&&capture->output.sample)capture->output.sample(capture->latest);
        }
    });
}
void WindowBackground::request(NSWindow* window,bool enabled) {
    auto s=state;double now=CACurrentMediaTime();
    if(now<s->next_request||s->request_pending.exchange(true))return;
    s->next_request=now+1.0/30;
    std::vector<DisplayRequest> requests;
    if(enabled&&s->enabled.load()&&window.isVisible) {
        double top=NSScreen.screens.firstObject.frame.size.height;
        CGRect rect=CGRectMake(window.frame.origin.x,top-NSMaxY(window.frame),window.frame.size.width,window.frame.size.height);
        for(NSScreen* screen in NSScreen.screens) {
            CGDirectDisplayID id=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
            CGRect bounds=CGDisplayBounds(id);double scale=screen.backingScaleFactor;
            auto area=pixels(rect,bounds,scale),desktop=pixels(bounds,bounds,scale);
            if(!bg::intersect(area,desktop).empty()) {
                double vx=0,vy=0;
                auto previous=s->last_geometry.find(id);
                if(previous!=s->last_geometry.end()&&now>s->last_geometry_time) {
                    vx=(area.left-previous->second.left)/(now-s->last_geometry_time);
                    vy=(area.top-previous->second.top)/(now-s->last_geometry_time);
                }
                requests.push_back({id,bounds,scale,desktop,area,vx,vy});
            }
        }
    }
    s->last_geometry.clear();for(const auto& request:requests)s->last_geometry[request.id]=request.window;
    s->last_geometry_time=now;
    unsigned target=static_cast<unsigned>(window.windowNumber);
    dispatch_async(s->queue,^{s->request_pending=false;s->update(requests,target);});
}
CIImage* WindowBackground::image(NSWindow* window,uint64_t& revision) {
    std::unique_lock lock(state->mutex,std::try_to_lock);if(!lock.owns_lock())return nil;
    CIImage* combined=nil;uint64_t newest=0;
    double top=NSScreen.screens.firstObject.frame.size.height;
    CGRect rect=CGRectMake(window.frame.origin.x,top-NSMaxY(window.frame),window.frame.size.width,window.frame.size.height);
    for(const auto& [id,snapshot]:state->snapshots) {
        (void)id;
        auto area=pixels(rect,snapshot.bounds,snapshot.scale);
        auto visible=bg::intersect(area,snapshot.desktop);
        if(visible.empty())continue;
        // Clip to valid cached pixels. Never scale an old cache across newly
        // exposed background while a replacement capture warms up.
        auto valid=bg::intersect(visible,bg::usable(snapshot.region,snapshot.desktop,snapshot.kernel));
        if(valid.empty())continue;
        auto crop=CGRectMake(valid.left-snapshot.region.left,snapshot.region.bottom-valid.bottom,valid.width(),valid.height());
        CIImage* part=[snapshot.image imageByCroppingToRect:crop];
        double ratio=window.backingScaleFactor/snapshot.scale;
        part=[part imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x,-crop.origin.y)];
        part=[part imageByApplyingTransform:CGAffineTransformMakeScale(ratio,ratio)];
        part=[part imageByApplyingTransform:CGAffineTransformMakeTranslation(
            (snapshot.bounds.origin.x+valid.left/snapshot.scale-rect.origin.x)*window.backingScaleFactor,
            (CGRectGetMaxY(rect)-snapshot.bounds.origin.y-valid.bottom/snapshot.scale)*window.backingScaleFactor)];
        combined=combined?[part imageByCompositingOverImage:combined]:part;
        newest=std::max(newest,snapshot.revision);
    }
    revision=newest;return combined;
}
void background_self_test(id<MTLDevice> device) {
    Blur blur(device);Params params;params.noise=0;
    CIImage* input=[[CIImage imageWithColor:[CIColor colorWithRed:.5 green:.5 blue:.5 alpha:1]] imageByCroppingToRect:CGRectMake(0,0,31,19)];
    auto command=[blur.commands commandBuffer];auto output=blur.encode(input,params,command);
    [command commit];[command waitUntilCompleted];
    if(command.status==MTLCommandBufferStatusError||output.width!=31||output.height!=19)
        throw std::runtime_error("background Metal blur self-test");
    std::vector<uint8_t> pattern(63*37*4);
    for(size_t i=0;i<pattern.size()/4;++i) {
        pattern[i*4]=uint8_t((i*37+17)%256);pattern[i*4+1]=uint8_t((i*13+73)%256);
        pattern[i*4+2]=uint8_t((i*61+103)%256);pattern[i*4+3]=255;
    }
    auto reference=blur_reference::run(63,37,pattern);
    NSData* data=[NSData dataWithBytes:pattern.data() length:pattern.size()];
    input=[CIImage imageWithBitmapData:data bytesPerRow:63*4 size:CGSizeMake(63,37) format:kCIFormatRGBA8 colorSpace:blur.colors];
    command=[blur.commands commandBuffer];output=blur.encode(input,params,command);
    [command commit];[command waitUntilCompleted];
    CIImage* check=[CIImage imageWithMTLTexture:output options:@{kCIImageColorSpace:(__bridge id)blur.colors}];
    std::vector<uint8_t> actual(pattern.size());
    [blur.context render:check toBitmap:actual.data() rowBytes:63*4 bounds:CGRectMake(0,0,63,37) format:kCIFormatRGBA8 colorSpace:blur.colors];
    int maximum_error=0;
    for(size_t i=0;i<actual.size();++i)maximum_error=std::max(maximum_error,std::abs(int(actual[i])-int(reference[i])));
    std::fprintf(stderr,"macos-background Windows-equation comparison max-byte-error=%d\n",maximum_error);
    if(maximum_error>3)throw std::runtime_error("background Windows blur equation mismatch");
    // The Windows default is Gaussian sigma=12 in physical pixels. Test a step
    // edge against an analytical Gaussian, including the measured spread; this
    // catches accidental DPI multiplication and a wrong algorithm/default.
    std::vector<uint8_t> step(128*64*4,255);
    for(unsigned y=0;y<64;++y)for(unsigned x=0;x<128;++x)
        for(unsigned c=0;c<3;++c)step[(y*128+x)*4+c]=x<64?0:255;
    data=[NSData dataWithBytes:step.data() length:step.size()];
    input=[CIImage imageWithBitmapData:data bytesPerRow:128*4 size:CGSizeMake(128,64) format:kCIFormatRGBA8 colorSpace:blur.colors];
    command=[blur.commands commandBuffer];output=blur.encodeGaussian(input,command);
    [command commit];[command waitUntilCompleted];
    check=[CIImage imageWithMTLTexture:output options:@{kCIImageColorSpace:(__bridge id)blur.colors}];
    std::vector<uint8_t> gaussian_result(step.size());
    [blur.context render:check toBitmap:gaussian_result.data() rowBytes:128*4 bounds:CGRectMake(0,0,128,64) format:kCIFormatRGBA8 colorSpace:blur.colors];
    maximum_error=0;double weight_sum=0;
    for(int i=-48;i<=48;++i)weight_sum+=std::exp(-i*i/(2.0*12*12));
    double variance=0,mass=0;
    for(int x=0;x<128;++x) {
        double expected=0;
        for(int i=-48;i<=48;++i)if(x+i>=64)expected+=std::exp(-i*i/(2.0*12*12));
        int actual_value=gaussian_result[(32*128+x)*4];
        maximum_error=std::max(maximum_error,std::abs(actual_value-int(std::lround(expected*255/weight_sum))));
        if(x) {
            double delta=actual_value-gaussian_result[(32*128+x-1)*4];
            variance+=delta*(x-64)*(x-64);mass+=delta;
        }
    }
    double measured_sigma=std::sqrt(variance/mass);
    std::fprintf(stderr,"macos-background Gaussian sigma=12 max-byte-error=%d measured-sigma=%.3f physical-pixels\n",maximum_error,measured_sigma);
    if(maximum_error>3||std::abs(measured_sigma-12)>.5)throw std::runtime_error("background Gaussian/DPI mismatch");
    // Numerical coverage contract shared with the Windows SOURCE_IN graph.
    for(double a:{0.0,.125,.25,.5,.75,1.0}) {
        CIImage* fg=[[CIImage imageWithColor:[CIColor colorWithRed:1 green:0 blue:0 alpha:a]] imageByCroppingToRect:CGRectMake(0,0,1,1)];
        CIImage* bg=[[CIImage imageWithColor:[CIColor colorWithRed:0 green:1 blue:0 alpha:1]] imageByCroppingToRect:CGRectMake(0,0,1,1)];
        CIImage* covered=[bg imageByApplyingFilter:@"CISourceInCompositing" withInputParameters:@{kCIInputBackgroundImageKey:fg}];
        CIImage* result=[fg imageByCompositingOverImage:covered];
        float pixel[4]{};
        [blur.context render:result toBitmap:pixel rowBytes:sizeof(pixel) bounds:CGRectMake(0,0,1,1) format:kCIFormatRGBAf colorSpace:blur.colors];
        // CI output converts its linear working result to sRGB; alpha remains linear.
        if(std::abs(pixel[3]-(a+a*(1-a)))>.002 || (a==0 && (pixel[0]!=0||pixel[1]!=0)))
            throw std::runtime_error("background SOURCE_IN alpha coverage mismatch");
    }
    // Disable the nontrivial kernel to establish the Core Image/Metal origin
    // contract with an asymmetric image, rather than trusting a solid-color test.
    params.radius=0;params.contrast=1;params.vibrancy=0;
    CIImage* lower=[[CIImage imageWithColor:[CIColor colorWithRed:1 green:0 blue:0 alpha:1]] imageByCroppingToRect:CGRectMake(0,0,512,256)];
    CIImage* upper=[[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:1 alpha:1]] imageByCroppingToRect:CGRectMake(0,256,512,256)];
    command=[blur.commands commandBuffer];output=blur.encode([upper imageByCompositingOverImage:lower],params,command);
    [command commit];[command waitUntilCompleted];
    CIImage* oriented=[CIImage imageWithMTLTexture:output options:@{kCIImageColorSpace:(__bridge id)blur.colors}];
    uint8_t pixel[4]{};
    [blur.context render:oriented toBitmap:pixel rowBytes:4 bounds:CGRectMake(256,64,1,1) format:kCIFormatRGBA8 colorSpace:blur.colors];
    if(pixel[0]<250||pixel[2]>5)throw std::runtime_error("background Metal vertical origin mismatch");
    std::fprintf(stderr,"macos-background self-test passed: Metal pipelines, odd dimensions, SOURCE_IN coverage, vertical origin\n");
}
}

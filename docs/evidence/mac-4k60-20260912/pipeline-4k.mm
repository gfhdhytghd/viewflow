#include "window_pixels.hpp"
#include "window_codec.hpp"
#include "window_frame_schedule.hpp"
#include "window_worker.hpp"
#import <Metal/Metal.h>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <cstdlib>
#include <fstream>

int main() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    @autoreleasepool {
        constexpr unsigned count=180;
        const bool small=std::getenv("VIEWFLOW_BENCH_SMALL")!=nullptr;
        const unsigned width=small ? 144 : 3840, height=small ? 144 : 2160;
        const bool direct_nv12=std::getenv("VIEWFLOW_BENCH_DIRECT_NV12")!=nullptr;
        const unsigned codec=std::getenv("VIEWFLOW_BENCH_HEVC") ? 2 : 1;
        auto space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        auto context=[CIContext contextWithMTLDevice:MTLCreateSystemDefaultDevice()
            options:@{kCIContextWorkingColorSpace:(__bridge id)space}];
        std::vector<CVPixelBufferRef> inputs;
        auto attributes=@{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{},
            (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey:@YES};
        // Prepare changing detailed inputs once; generated capture is outside
        // this source-stage benchmark, just as SCK is outside the encode worker.
        for(unsigned i=0;i<4;++i) {
            CVPixelBufferRef pixels=nullptr;
            if(CVPixelBufferCreate(nullptr,width,height,direct_nv12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
                (__bridge CFDictionaryRef)attributes,&pixels)!=kCVReturnSuccess)return 1;
            if(direct_nv12)CVBufferSetAttachment(pixels,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
            auto filter=[CIFilter filterWithName:@"CICheckerboardGenerator" withInputParameters:@{
                @"inputCenter":[CIVector vectorWithX:i*7 Y:i*3], @"inputWidth":@32,
                @"inputColor0":[CIColor colorWithRed:.15 green:.4 blue:.8 alpha:1],
                @"inputColor1":[CIColor colorWithRed:.8 green:.7 blue:.15 alpha:1]}];
            [context render:filter.outputImage toCVPixelBuffer:pixels bounds:CGRectMake(0,0,width,height) colorSpace:space];
            inputs.push_back(pixels);
        }
        auto time=[] {return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();};
        struct Metric {double start, split, alpha, submitted, done;};
        std::vector<Metric> metrics(count);
        std::vector<viewflow::reverse::Frame> frames(count);
        std::mutex mutex; std::condition_variable changed; unsigned pending=0;
        viewflow::macos::Encoder encoder(60,true);
        viewflow::macos::ExactAlphaCache alpha;
        viewflow::macos::SerialWorker completion;
        for(unsigned i=0;i<count;++i) {@autoreleasepool {
            {std::unique_lock lock(mutex); changed.wait(lock,[&]{return pending<2;}); ++pending;}
            Metric m{};m.start=time();
            auto pixels=inputs[i%inputs.size()];
            auto planes=[&] {
                if(!direct_nv12)return viewflow::macos::split_planes(context,[CIImage imageWithCVPixelBuffer:pixels],width,height,space,pixels,true);
                viewflow::macos::Planes result;result.color=CVPixelBufferRetain(pixels);result.alpha.assign(width*height,255);return result;
            }();
            m.split=time();
            viewflow::reverse::Frame frame;frame.width=width;frame.height=height;frame.codec=codec;frame.pts=(i+1)*1000000ll/60;
            frame.alpha=alpha.encode(planes.alpha,width,height);m.alpha=time();
            auto ticket=encoder.submit(planes.color,std::move(frame));m.submitted=time();
            if(!completion.submit_wait([&,i,m,ticket]() mutable {@autoreleasepool {
                try {
                    auto result=encoder.finish(ticket);
                    const auto bytes=viewflow::reverse::pack_frame(result);
                    if(bytes.empty())std::terminate();
                    frames[i]=std::move(result);
                } catch(const std::exception& error) {std::fprintf(stderr,"frame %u: %s\n",i,error.what());}
                m.done=time();metrics[i]=m;
                {std::lock_guard lock(mutex);--pending;}changed.notify_all();
            }}))return 2;
        }}
        encoder.flush();
        {std::unique_lock lock(mutex);changed.wait(lock,[&]{return pending==0;});}
        unsigned completed=0;
        for(unsigned i=10;i<count;++i) {
            if(frames[i].color.empty())continue;
            ++completed;
            const auto& m=metrics[i];
            std::printf("%.4f %.4f %.4f %.4f\n",m.split-m.start,m.alpha-m.split,m.done-m.alpha,m.done-m.start);
        }
        std::fprintf(stderr,"warmed-source-fps=%.3f frames=%u dropped=%u width=%u height=%u pipeline=2 direct-nv12=%u\n",
            completed*1000./(metrics.back().done-metrics[9].done),completed,count-10-completed,width,height,unsigned(direct_nv12));
        viewflow::macos::Decoder decoder;
        std::ofstream fixture;
        if(const char* path=std::getenv("VIEWFLOW_BENCH_ANNEXB"))fixture.open(path,std::ios::binary);
        for(unsigned i=0;i<count;++i) {
            if(frames[i].color.empty())continue;
            if(frames[i].pts!=(i+1)*1000000ll/60)return 3;
            auto pixels=decoder.decode(frames[i]);
            if(!pixels || CVPixelBufferGetWidth(pixels)!=width || CVPixelBufferGetHeight(pixels)!=height)return 4;
            CVPixelBufferRelease(pixels);
            if(fixture.is_open())fixture.write(reinterpret_cast<const char*>(frames[i].color.data()),frames[i].color.size());
        }
        std::fprintf(stderr,"all delivered generated frames decoded in order; no capture or input\n");
        for(auto pixels:inputs)CVPixelBufferRelease(pixels);
        CGColorSpaceRelease(space);
    }
}

#include "window_pixels.hpp"
#include "window_codec.hpp"
#include "window_frame_schedule.hpp"
#import <Metal/Metal.h>
#include <chrono>
#include <cstdio>
#include <deque>
#include <pthread/qos.h>

int main(int argc, char**) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
    @autoreleasepool {
        constexpr unsigned width=3840, height=2160;
        auto space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        auto context=[CIContext contextWithMTLDevice:MTLCreateSystemDefaultDevice()
            options:@{kCIContextWorkingColorSpace:(__bridge id)space}];
        CVPixelBufferRef capture=nullptr;
        NSDictionary* attributes=@{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{},
            (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey:@YES};
        if(CVPixelBufferCreate(nullptr,width,height,kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)attributes,&capture)!=kCVReturnSuccess)return 1;
        viewflow::macos::Encoder encoder(60,true);
        viewflow::macos::ExactAlphaCache alpha;
        auto clock=[] {return std::chrono::steady_clock::now();};
        auto ms=[](auto a,auto b){return std::chrono::duration<double,std::milli>(b-a).count();};
        struct Pending { viewflow::macos::Encoder::Ticket ticket; std::chrono::steady_clock::time_point start; };
        std::deque<Pending> pending;
        const auto all_start=clock();
        for(unsigned i=0;i<100;++i) {@autoreleasepool {
            auto pattern=[[CIImage imageWithColor:[CIColor colorWithRed:(i%17)/17. green:0.5 blue:0.25 alpha:1.]]
                imageByCroppingToRect:CGRectMake(0,0,width,height)];
            [context render:pattern toCVPixelBuffer:capture bounds:CGRectMake(0,0,width,height) colorSpace:space];
            const auto start=clock();
            auto planes=viewflow::macos::split_planes(context,[CIImage imageWithCVPixelBuffer:capture],width,height,space,capture,true);
            const auto split=clock();
            viewflow::reverse::Frame frame;frame.width=width;frame.height=height;frame.codec=1;frame.pts=i*1000000ll/60;
            frame.alpha=alpha.encode(planes.alpha,width,height);
            const auto a=clock();
            auto frame_start=start;
            if(argc>1) {
                pending.push_back({encoder.submit(planes.color,std::move(frame)),start});
                if(pending.size()<2)continue;
                frame_start=pending.front().start;
                frame=encoder.finish(pending.front().ticket);pending.pop_front();
            } else frame=encoder.encode(planes.color,std::move(frame));
            const auto encoded=clock();
            auto bytes=viewflow::reverse::pack_frame(frame);
            const auto done=clock();
            if(i>=10)std::printf("%.4f %.4f %.4f %.4f %.4f %zu %.4f\n",ms(start,split),ms(split,a),ms(a,encoded),ms(encoded,done),ms(start,done),bytes.size(),ms(frame_start,done));
        }}
        encoder.flush();
        for(auto& ticket:pending)encoder.finish(ticket.ticket);
        std::fprintf(stderr,"generated-4k-throughput-fps=%.3f\n",100000./ms(all_start,clock()));
        CVPixelBufferRelease(capture);CGColorSpaceRelease(space);
    }
}

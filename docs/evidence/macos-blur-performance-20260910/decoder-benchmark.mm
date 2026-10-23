#include "window_pixels.hpp"
#include "window_codec.hpp"
#import <Metal/Metal.h>
#include <chrono>
#include <algorithm>
#include <cstdio>
namespace vm = viewflow::macos;
namespace vf = viewflow::reverse;
int main() { @autoreleasepool {
 const unsigned width=3840, height=2400;
 auto space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
 auto device=MTLCreateSystemDefaultDevice();
 CIContext* context=[CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace:(__bridge id)space}];
 auto attrs=@{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{},(__bridge NSString*)kCVPixelBufferMetalCompatibilityKey:@YES};
 CVPixelBufferRef color=nullptr, output=nullptr;
 if(CVPixelBufferCreate(nullptr,width,height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&color) ||
    CVPixelBufferCreate(nullptr,width,height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&output)) return 2;
 CVPixelBufferLockBaseAddress(color,0);
 auto* base=static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(color));
 const auto stride=CVPixelBufferGetBytesPerRow(color);
 for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x){auto* p=base+y*stride+x*4;p[0]=x%256;p[1]=y%256;p[2]=(x+y)%256;p[3]=255;}
 CVPixelBufferUnlockBaseAddress(color,0);
 std::vector<uint8_t> alpha(size_t(width)*height,128);
 std::vector<vf::Frame> frames;
 vm::Encoder encoder(60,true);
 for(unsigned i=0;i<44;++i){vf::Frame frame;frame.codec=1;frame.width=width;frame.height=height;frame.pts=(i+1)*16667;frame.alpha=vf::encode_alpha(alpha);frame.tiles.push_back({1,0,0,0,width,height,0,0,"generated",0,0});frames.push_back(encoder.encode(color,std::move(frame)));}
 for(bool yuv : {false,true,true,false}) { @autoreleasepool {
  vm::Decoder decoder(yuv);std::vector<double> samples;
  for(unsigned i=0;i<frames.size();++i){ @autoreleasepool {
   const auto start=std::chrono::steady_clock::now();
   CVPixelBufferRef decoded=decoder.decode(frames[i]);if(!decoded)return 3;
   CIImage* image=vm::join_planes(decoded,alpha);
   [context render:image toCVPixelBuffer:output bounds:CGRectMake(0,0,width,height) colorSpace:space];
   if(CVPixelBufferLockBaseAddress(output,kCVPixelBufferLock_ReadOnly))return 4;
   volatile uint8_t sample=static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(output))[3];(void)sample;
   CVPixelBufferUnlockBaseAddress(output,kCVPixelBufferLock_ReadOnly);CVPixelBufferRelease(decoded);
   const double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
   if(i>=4)samples.push_back(ms);
  }}
  printf("{\"output\":\"%s\",\"width\":%u,\"height\":%u,\"samples_ms\":[",yuv?"nv12":"bgra",width,height);
  for(size_t i=0;i<samples.size();++i)printf("%s%.4f",i?",":"",samples[i]);
  std::sort(samples.begin(),samples.end());printf("],\"median_ms\":%.4f,\"p95_ms\":%.4f}\n",samples[samples.size()/2],samples[samples.size()*95/100]);
 }}
 CVPixelBufferRelease(color);CVPixelBufferRelease(output);CGColorSpaceRelease(space);
}}

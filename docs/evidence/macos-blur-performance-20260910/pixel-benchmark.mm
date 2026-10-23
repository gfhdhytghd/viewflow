#include "window_pixels.hpp"
#import <Metal/Metal.h>
#include <chrono>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
int main(int argc, char** argv) {
 @autoreleasepool {
  const unsigned width=argc>1?std::atoi(argv[1]):3840,height=argc>2?std::atoi(argv[2]):2400;
  auto space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CIContext* context=[CIContext contextWithMTLDevice:MTLCreateSystemDefaultDevice() options:@{kCIContextWorkingColorSpace:(__bridge id)space}];
  CVPixelBufferRef color=nullptr,output=nullptr;
  auto attrs=@{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{},(__bridge NSString*)kCVPixelBufferMetalCompatibilityKey:@YES};
  if(CVPixelBufferCreate(nullptr,width,height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&color)!=kCVReturnSuccess ||
     CVPixelBufferCreate(nullptr,width,height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&output)!=kCVReturnSuccess)return 2;
  CVPixelBufferLockBaseAddress(color,0);
  std::memset(CVPixelBufferGetBaseAddress(color),192,CVPixelBufferGetBytesPerRow(color)*height);
  CVPixelBufferUnlockBaseAddress(color,0);
  std::vector<uint8_t> alpha(size_t(width)*height,128);
  std::vector<double> elapsed;
  for(unsigned i=0;i<44;++i) { @autoreleasepool {
   alpha[(i*1777)%alpha.size()]=uint8_t(i);
   auto start=std::chrono::steady_clock::now();
   CIImage* composed=viewflow::macos::join_planes(color,alpha);
   [context render:composed toCVPixelBuffer:output bounds:CGRectMake(0,0,width,height) colorSpace:space];
   // Lock forces completed output, rather than timing GPU submission alone.
   if(CVPixelBufferLockBaseAddress(output,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess)return 3;
   volatile uint8_t sample=static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(output))[3];(void)sample;
   CVPixelBufferUnlockBaseAddress(output,kCVPixelBufferLock_ReadOnly);
   double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
   if(i>=4)elapsed.push_back(ms);
  }}
  std::printf("{\"width\":%u,\"height\":%u,\"samples_ms\":[",width,height);
  for(size_t i=0;i<elapsed.size();++i)std::printf("%s%.4f",i?",":"",elapsed[i]);
  std::sort(elapsed.begin(),elapsed.end());
  std::printf("],\"median_ms\":%.4f,\"p95_ms\":%.4f}\n",elapsed[elapsed.size()/2],elapsed[elapsed.size()*95/100]);
  CVPixelBufferRelease(color);CVPixelBufferRelease(output);CGColorSpaceRelease(space);
 }
}

#include "window_retained_image.hpp"
#include <array>
#include <stdexcept>
#include <cstdio>

int main() { @autoreleasepool {
    namespace vf=viewflow::reverse;
    namespace vm=viewflow::macos;
    CIContext* context=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
    CIImage* red=[[CIImage imageWithColor:[CIColor colorWithRed:1 green:0 blue:0 alpha:1]] imageByCroppingToRect:CGRectMake(0,0,4,4)];
    CIImage* blue=[[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:1 alpha:1]] imageByCroppingToRect:CGRectMake(0,0,1,1)];
    CIImage* transparent=[[CIImage imageWithColor:CIColor.clearColor] imageByCroppingToRect:CGRectMake(0,0,1,1)];
    vf::Tile tile;tile.id=1;tile.width=tile.height=4;
    vf::set_resident_rect(tile,{1,1,1,1});
    auto image=vm::retain_window_patch(context,red,blue,1,tile);
    std::array<unsigned char,64> pixels{};
    auto read=[&](CIImage* value){[context render:value toBitmap:pixels.data() rowBytes:16 bounds:CGRectMake(0,0,4,4) format:kCIFormatRGBA8 colorSpace:nil];};
    read(image);
    for(unsigned y=0;y<4;++y)for(unsigned x=0;x<4;++x) {
        const auto p=&pixels[(y*4+x)*4];
        const bool patch=x==1 && y==1;
        if(p[0]!=(patch?0:255) || p[2]!=(patch?255:0) || p[3]!=255) {
            std::fprintf(stderr,"pixel %u,%u rgba=%u,%u,%u,%u\n",x,y,p[0],p[1],p[2],p[3]);
            throw std::runtime_error("partial update discarded frozen pixels");
        }
    }
    image=vm::retain_window_patch(context,image,transparent,1,tile);read(image);
    if(pixels[(1*4+1)*4+3]!=0 || pixels[3]!=255)
        throw std::runtime_error("transparent update must replace old alpha only inside patch");
    vf::set_resident_rect(tile,{});
    if(vm::retain_window_patch(context,image,blue,1,tile)!=image)
        throw std::runtime_error("empty residency must freeze exact image");
    // Long pause and atlas eviction do not accumulate CI dependency graphs.
    for(unsigned i=0;i<100;++i)image=vm::retain_window_patch(context,image,blue,1,tile);
    read(image);if(pixels[3]!=255)throw std::runtime_error("pause lost frame");
    vf::set_resident_rect(tile,{0,0,4,4});
    image=vm::retain_window_patch(context,image,red,4,tile);read(image);
    if(pixels[(1*4+1)*4]!=255 || pixels[(1*4+1)*4+3]!=255)
        throw std::runtime_error("complete resume did not replace frozen frame");
} }

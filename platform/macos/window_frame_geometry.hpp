#pragma once
#include <cstdint>
#include <cstddef>
#include <algorithm>
#include <array>

namespace viewflow::macos {
struct FrameRect { unsigned x{},y{},width{},height{}; };
// SCK's boundingRect includes framing. The authoritative window size comes
// from screenRect; locate its straight alpha edges inside that framing rather
// than assuming symmetric shadow padding or counting the shadow as content.
inline FrameRect window_body(const std::uint8_t* bgra,std::size_t stride,
                             FrameRect outer,unsigned width,unsigned height) {
    if(!bgra || !width || !height || width>outer.width || height>outer.height)return {};
    auto alpha=[&](int x,int y) -> int {
        if(x<int(outer.x) || y<int(outer.y) || x>=int(outer.x+outer.width) || y>=int(outer.y+outer.height))return 0;
        return bgra[std::size_t(y)*stride+std::size_t(x)*4+3];
    };
    unsigned left=outer.x+(outer.width-width)/2,top=outer.y+(outer.height-height)/2;
    int best_x=0,best_y=0;
    for(unsigned x=outer.x;x<=outer.x+outer.width-width;++x) {
        int score=0;
        for(unsigned y=outer.y;y<outer.y+outer.height;y+=std::max(1u,outer.height/64))
            score+=alpha(x,y)-alpha(int(x)-1,y)+alpha(x+width-1,y)-alpha(x+width,y);
        if(score>best_x){best_x=score;left=x;}
    }
    for(unsigned y=outer.y;y<=outer.y+outer.height-height;++y) {
        int score=0;
        for(unsigned x=left;x<left+width;x+=std::max(1u,width/64))
            score+=alpha(x,y)-alpha(x,int(y)-1)+alpha(x,y+height-1)-alpha(x,y+height);
        if(score>best_y){best_y=score;top=y;}
    }
    return {left,top,width,height};
}
}

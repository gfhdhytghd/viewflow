#pragma once
#include <algorithm>
#include <cstdint>
#include <utility>
namespace viewflow::reverse {
// Retain capacity across popup animation; shrink only after a stable idle interval.
class AtlasCapacity {
    unsigned width_{},height_{},candidate_width_{},candidate_height_{};
    std::int64_t stable_since_{};
public:
    std::pair<unsigned,unsigned> select(unsigned w,unsigned h,std::int64_t now,bool busy,unsigned max_width=8192,unsigned max_height=4096,unsigned width_alignment=512,unsigned height_alignment=256) {
        w=std::min(max_width,((w+width_alignment-1)/width_alignment)*width_alignment);h=std::min(max_height,((h+height_alignment-1)/height_alignment)*height_alignment);
        if(w!=candidate_width_ || h!=candidate_height_ || busy){candidate_width_=w;candidate_height_=h;stable_since_=now;}
        if(w>width_ || h>height_){width_=std::max(width_,w);height_=std::max(height_,h);}
        else if(!busy && now-stable_since_>=3000){width_=w;height_=h;}
        return {width_,height_};
    }
    std::pair<unsigned,unsigned> select_shared(unsigned w,unsigned h,std::int64_t now,bool busy,unsigned max_width,unsigned max_height) {
        return select(w,h,now,busy,max_width,max_height,1,1);
    }
};
}

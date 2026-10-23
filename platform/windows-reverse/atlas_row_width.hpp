#pragma once
#include <algorithm>
#include <vector>
namespace viewflow::reverse {
struct AtlasExtent {
    unsigned width{},height{};bool popup{};
    bool operator==(const AtlasExtent&) const = default;
};
// Keep tile order, including the existing separate IME band. Try the current
// allocation before growing a horizontal shelf into a new encoder size.
inline unsigned atlas_row_width(const std::vector<AtlasExtent>& tiles,unsigned width,unsigned height,unsigned max_width=8192,unsigned max_height=4096) {
    if(!width || !height || width>max_width || height>max_height)return max_width;
    unsigned x=0,y=0,row_height=0,needed_height=192,body_height=192;
    bool popup_band=false;
    for(const auto& tile:tiles){
        const auto w=tile.width,h=tile.height;
        if(w>max_width || h>max_height)continue; // Same unsupported extents as the caller.
        if(w>width)return max_width;
        if(tile.popup && !popup_band){body_height=needed_height;y=(body_height+63)&~63u;x=0;row_height=0;popup_band=true;}
        if(x+w>width){y+=row_height;x=0;row_height=0;}
        if(y+h>height)return max_width;
        x+=w;row_height=std::max(row_height,h);needed_height=std::max(needed_height,y+h);
    }
    if(!popup_band)body_height=needed_height;
    const auto reserved=std::min(max_height,((body_height+63)&~63u)+512u);
    return std::max(needed_height,reserved)<=height?width:max_width;
}
}

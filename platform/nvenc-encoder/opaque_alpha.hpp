#pragma once
#include "gpu_dmabuf_encoder.cuh"
#include <algorithm>
#include <array>
#include <cmath>

namespace viewflow::gpu {
// Execute capture/download only when requested. Kept inline so the enabled
// path adds only the cached policy branch.
template<class Capture> bool readAlphaIfEnabled(bool enabled, Capture&& capture) {
    return !enabled || capture();
}
// Geometry-only immutable alpha: no GPU read, and no per-frame pixel work when
// the content rectangles are unchanged. Coordinates are displayed crop pixels.
class OpaqueAlphaCache {
    using Rect = std::array<int, 4>;
    std::vector<Rect> previous_;
    int width_{}, height_{};
    std::shared_ptr<const std::vector<unsigned char>> bytes_;
public:
    std::shared_ptr<const std::vector<unsigned char>> get(
        int width, int height, const std::vector<DmabufAtlasTile>& tiles,
        const SparseResult* sparse = nullptr) {
        std::vector<Rect> rects;
        auto append = [&](const DmabufFrame& frame, int x, int y, int sx, int sy, int w, int h) {
            Rect r{x,y,x+w,y+h};
            if(frame.shadow) {
                const auto& s=*frame.shadow;
                r[0]=std::max(r[0],int(std::clamp(std::ceil(x+s.cutoutLeft-sx-.5),0.,double(width))));
                r[1]=std::max(r[1],int(std::clamp(std::ceil(y+s.cutoutTop-sy-.5),0.,double(height))));
                r[2]=std::min(r[2],int(std::clamp(std::ceil(x+s.cutoutLeft+s.cutoutWidth-sx-.5),0.,double(width))));
                r[3]=std::min(r[3],int(std::clamp(std::ceil(y+s.cutoutTop+s.cutoutHeight-sy-.5),0.,double(height))));
            }
            r[0]=std::clamp(r[0],0,width);r[2]=std::clamp(r[2],0,width);
            r[1]=std::clamp(r[1],0,height);r[3]=std::clamp(r[3],0,height);
            if(r[0]<r[2] && r[1]<r[3])rects.push_back(r);
        };
        if(sparse) for(const auto& p:sparse->patches)
            append(tiles.at(p.source).frame,p.x,p.y,p.sourceX,p.sourceY,p.width,p.height);
        else for(const auto& t:tiles)append(t.frame,t.x,t.y,0,0,t.frame.cropWidth,t.frame.cropHeight);
        if(!bytes_ || width!=width_ || height!=height_ || rects!=previous_) {
            auto bytes=std::make_shared<std::vector<unsigned char>>(size_t(width)*height,0);
            for(const auto& r:rects)for(int y=r[1];y<r[3];++y)
                std::fill(bytes->begin()+size_t(y)*width+r[0],bytes->begin()+size_t(y)*width+r[2],255);
            bytes_=std::move(bytes);previous_=std::move(rects);width_=width;height_=height;
        }
        return bytes_;
    }
};
}

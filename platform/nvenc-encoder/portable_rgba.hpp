#pragma once
#include "gpu_dmabuf_encoder.cuh"
#include <array>
#include <span>
#include <cstring>

namespace viewflow::gpu {
struct CpuTile { int width{},height{},x{},y{}; std::vector<unsigned char> rgba; };
inline CpuTile prepareCpuTile(std::span<const unsigned char> pixels,const DmabufAtlasTile& tile) {
    const auto& f=tile.frame;
    if(f.cropWidth<=0 || f.cropHeight<=0 || pixels.size()!=size_t(f.cropWidth)*f.cropHeight*4)
        throw std::invalid_argument("invalid portable RGBA crop");
    CpuTile out{f.cropWidth,f.cropHeight,tile.x,tile.y,std::vector<unsigned char>(pixels.size())};
    for(int y=0;y<out.height;++y) for(int x=0;x<out.width;++x) {
        const auto* p=pixels.data()+(size_t(f.flipVertical?out.height-1-y:y)*out.width+x)*4;
        auto* d=out.rgba.data()+(size_t(y)*out.width+x)*4;
        d[3]=p[3];
        for(int c=0;c<3;++c) d[c]=p[3]?std::min((int(p[c])*255+p[3]/2)/p[3],255):0;
    }
    // Preserve the existing single-row titlebar seam repair.
    for(int y=1;y<std::min(out.height-1,96);++y) {
        int first=-1,last=-1,n=0;
        auto pixel=[&](int x,int row){ return out.rgba.data()+(size_t(row)*out.width+x)*4; };
        for(int x=0;x<out.width;++x)
            if(pixel(x,y)[3]<=4 && pixel(x,y-1)[3]>=128 && pixel(x,y+1)[3]>=128) {
                if(first<0) first=x;
                last=x;++n;
            }
        if(n<std::max(16,out.width/3) || first<0 || last-first+1<std::max(16,out.width/2)) continue;
        for(int x=0;x<out.width;++x)
            if(pixel(x,y)[3]<=4 && pixel(x,y-1)[3]>=128 && pixel(x,y+1)[3]>=128)
                std::memcpy(pixel(x,y),pixel(x,y+1),4);
        break;
    }
    if(!f.shadow || !f.shadow->alpha) return out;
    const auto& s=*f.shadow;
    const double values[]={s.left,s.top,s.width,s.height,s.cutoutLeft,s.cutoutTop,s.cutoutWidth,s.cutoutHeight,
        s.range,s.rounding,s.windowRounding,s.roundingPower,s.left+s.width,s.top+s.height,
        s.left+s.cutoutLeft+s.cutoutWidth,s.top+s.cutoutTop+s.cutoutHeight};
    for(double v:values) if(!std::isfinite(v)) throw std::invalid_argument("non-finite shadow geometry");
    if(s.width<=0 || s.height<=0 || s.range<=0 || s.cutoutWidth<=0 || s.cutoutHeight<=0 ||
        s.rounding<0 || s.windowRounding<0 || s.roundingPower<1 || s.roundingPower>10 || s.power<1 || s.power>4)
        throw std::invalid_argument("invalid shadow geometry");
    auto floor=[](double v,int lo,int hi){return int(std::clamp(std::floor(v),double(lo),double(hi)));};
    auto ceil=[](double v,int lo,int hi){return int(std::clamp(std::ceil(v),double(lo),double(hi)));};
    int l=floor(s.left,0,out.width),t=floor(s.top,0,out.height);
    int r=ceil(s.left+s.width,l,out.width),b=ceil(s.top+s.height,t,out.height);
    int cl=floor(s.left+s.cutoutLeft,l,r),ct=floor(s.top+s.cutoutTop,t,b);
    int cr=ceil(s.left+s.cutoutLeft+s.cutoutWidth,cl,r),cb=ceil(s.top+s.cutoutTop+s.cutoutHeight,ct,b);
    auto region=[&](int x0,int y0,int x1,int y1,bool cutout) {
        for(int y=y0;y<y1;++y) for(int x=x0;x<x1;++x)
            repairShadowPixel(out.rgba.data()+(size_t(y)*out.width+x)*4,x,y,cutout,s);
    };
    region(l,t,r,ct,false);region(l,cb,r,b,false);region(l,ct,cl,cb,false);region(cr,ct,r,cb,false);
    int radius=ceil(s.windowRounding,0,std::max(cr-cl,cb-ct));
    int rx=std::min(radius,cr-cl),ry=std::min(radius,cb-ct);
    region(cl,ct,cl+rx,ct+ry,true);region(cr-rx,ct,cr,ct+ry,true);
    region(cl,cb-ry,cl+rx,cb,true);region(cr-rx,cb-ry,cr,cb,true);
    return out;
}
inline void classifyCpuCells(const std::vector<CpuTile>& tiles,std::vector<SparseCell>& cells) {
    for(auto& c:cells) {
        const auto& tile=tiles.at(c.source);
        bool nonzero=false,nonopaque=false;
        for(unsigned y=0;y<c.height;++y) for(unsigned x=0;x<c.width;++x) {
            auto a=tile.rgba.at((size_t(c.sourceY+y)*tile.width+c.sourceX+x)*4+3);
            nonzero|=a!=0;nonopaque|=a!=255;
        }
        c.alpha=!nonzero?CellAlpha::Empty:!nonopaque?CellAlpha::Opaque:CellAlpha::Mixed;
    }
}
inline void composeCpuSparse(const std::vector<CpuTile>& tiles,const SparsePlan& plan,int width,int height,std::vector<unsigned char>& out) {
    out.assign(size_t(width)*height*4,0);
    for(const auto& draw:plan.draws) {
        const auto& p=draw.patch;
        if(uint64_t(p.x)+p.width>unsigned(width) || uint64_t(p.y)+p.height>unsigned(height))
            throw std::invalid_argument("portable sparse patch outside canvas");
        for(unsigned y=0;y<p.height;++y) for(unsigned x=0;x<p.width;++x) {
            auto* d=out.data()+(size_t(p.y+y)*width+p.x+x)*4;
            for(const auto& layer:draw.layers) {
                const auto& t=tiles.at(layer.source);
                const auto* s=t.rgba.data()+(size_t(layer.sourceY+y)*t.width+layer.sourceX+x)*4;
                float a=float(s[3])/255.f,b=float(d[3])/255.f,alpha=a+b*(1-a);
                for(int c=0;c<3;++c) d[c]=alpha>0?std::min(255.f,(s[c]*a+d[c]*b*(1-a))/alpha+0.5f):0;
                d[3]=alpha*255.f+0.5f;
            }
        }
    }
}
}

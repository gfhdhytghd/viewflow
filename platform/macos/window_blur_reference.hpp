#pragma once
// CPU oracle for tests only. The production path never reads GPU pixels back.
// Implements the SDR UNORM equations in the Windows Hyprland blur shader.
#include <array>
#include <vector>
#include <algorithm>
#include <cmath>
#include <cstdint>
namespace viewflow::macos::blur_reference {
using Pixel=std::array<double,4>;
inline Pixel vibrancy(Pixel color) {
    double lo=std::min({color[0],color[1],color[2]}),hi=std::max({color[0],color[1],color[2]});
    double delta=hi-lo,l=(hi+lo)*.5,s=0,h=0;
    if(l>0&&l<1)s=delta/(2*std::min(l,1-l));
    if(delta>0) {
        if(hi==color[0])h=(color[1]-color[2])/delta;
        else if(hi==color[1])h=2+(color[2]-color[0])/delta;
        else h=4+(color[0]-color[1])/delta;
        h/=6;if(h<0)h+=1;
    }
    double perceived=std::sqrt(color[0]*color[0]*.299+color[1]*color[1]*.587+color[2]*color[2]*.114);
    perceived=perceived<=.8?.8-std::sqrt(.64-perceived*perceived):.8+std::sqrt(.04-(perceived-1)*(perceived-1));
    double boost=1-(std::pow(1-s*std::cos(.93),2)+std::pow(1-perceived*std::sin(.93),2));
    boost=std::clamp((boost-(.11-.66*.5))/.66,0.0,1.0);boost=boost*boost*(3-2*boost);
    s=std::clamp(s+(s>0?boost*.1696/4:0),0.0,1.0);
    Pixel xt;
    if(h<1.0/3)xt={6*(1.0/3-h),6*h,0,0};
    else if(h<2.0/3)xt={0,6*(2.0/3-h),6*(h-1.0/3),0};
    else xt={6*(h-2.0/3),0,6*(1-h),0};
    for(unsigned i=0;i<3;++i) {
        double ct=2*s*std::min(xt[i],1.0)+(1-s);
        color[i]=l>=.5?(1-l)*ct+2*l-1:l*ct;
    }
    return color;
}
inline std::vector<uint8_t> run(unsigned width,unsigned height,const std::vector<uint8_t>& bytes) {
    std::vector<Pixel> image(size_t(width)*height);
    for(size_t i=0;i<image.size();++i)for(unsigned c=0;c<4;++c)image[i][c]=bytes[i*4+c]/255.0;
    unsigned w=width,h=height;
    auto pass=[&](unsigned nw,unsigned nh,unsigned shader) {
        auto sample=[&](double u,double v) {
            double x=u*w-.5,y=v*h-.5;int ix=int(std::floor(x)),iy=int(std::floor(y));
            double fx=x-ix,fy=y-iy;Pixel result{};
            for(int dy=0;dy<2;++dy)for(int dx=0;dx<2;++dx) {
                const auto& p=image[size_t(std::clamp(iy+dy,0,int(h)-1))*w+std::clamp(ix+dx,0,int(w)-1)];
                double weight=(dx?fx:1-fx)*(dy?fy:1-fy);
                for(unsigned c=0;c<4;++c)result[c]+=p[c]*weight;
            }
            return result;
        };
        std::vector<Pixel> next(size_t(nw)*nh);
        for(unsigned y=0;y<nh;++y)for(unsigned x=0;x<nw;++x) {
            double u=(x+.5)/nw,v=(y+.5)/nh;Pixel color{};
            auto tap=[&](double dx,double dy,double weight) {
                auto p=sample(u+dx/w,v+dy/h);for(unsigned c=0;c<4;++c)color[c]+=p[c]*weight;
            };
            if(shader==0) {
                color=sample(u,v);
                for(unsigned c=0;c<3;++c) {
                    bool upper=color[c]>=.5;double a=.5*std::pow(2*(upper?1-color[c]:color[c]),.8916);
                    color[c]=upper?1-a:a;
                }
            } else if(shader==1) {
                tap(0,0,.5);tap(-5,-5,.125);tap(5,5,.125);tap(5,-5,.125);tap(-5,5,.125);
                color=vibrancy(color);
            } else {
                tap(-2.5,0,1.0/12);tap(-1.25,1.25,2.0/12);tap(0,2.5,1.0/12);tap(1.25,1.25,2.0/12);
                tap(2.5,0,1.0/12);tap(1.25,-1.25,2.0/12);tap(0,-2.5,1.0/12);tap(-1.25,-1.25,2.0/12);
            }
            for(unsigned c=0;c<4;++c)next[size_t(y)*nw+x][c]=std::round(std::clamp(color[c],0.0,1.0)*255)/255;
        }
        image=std::move(next);w=nw;h=nh;
    };
    pass(w,h,0);std::vector<std::pair<unsigned,unsigned>> levels{{w,h}};
    for(unsigned i=0;i<4;++i){levels.emplace_back(std::max(1u,(w+1)/2),std::max(1u,(h+1)/2));pass(levels.back().first,levels.back().second,1);}
    for(int i=3;i>=0;--i)pass(levels[i].first,levels[i].second,2);
    std::vector<uint8_t> output(bytes.size());
    for(size_t i=0;i<image.size();++i)for(unsigned c=0;c<4;++c)output[i*4+c]=uint8_t(std::round(image[i][c]*255));
    return output;
}
}

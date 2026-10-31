#pragma once
#include "../reverse-common/window_residency.hpp"
#include <GLES3/gl3.h>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <array>

namespace viewflow::reverse {
// A persistent destination; an omitted resident pixel is not a transparent
// update. Clear only new storage, and replace (never alpha-blend) received data.
class RetainedSurface {
    GLuint texture_{}, framebuffer_{};
    unsigned width_{},height_{};
public:
    RetainedSurface()=default;
    RetainedSurface(const RetainedSurface&)=delete;
    RetainedSurface& operator=(const RetainedSurface&)=delete;
    void reset() {
        if(framebuffer_)glDeleteFramebuffers(1,&framebuffer_);
        if(texture_)glDeleteTextures(1,&texture_);
        framebuffer_=texture_=width_=height_=0;
    }
    // Owner must reset with its EGL context current before context teardown.
    bool bind(unsigned width,unsigned height) {
        if(!width || !height)throw std::runtime_error("empty retained surface");
        if(width==width_ && height==height_) {glBindFramebuffer(GL_FRAMEBUFFER,framebuffer_);return false;}
        GLuint texture=0,framebuffer=0;
        glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
        glGenFramebuffers(1,&framebuffer);glBindFramebuffer(GL_FRAMEBUFFER,framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
        if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE) {
            glDeleteFramebuffers(1,&framebuffer);glDeleteTextures(1,&texture);
            glBindFramebuffer(GL_FRAMEBUFFER,framebuffer_);
            throw std::runtime_error("retained surface allocation failed");
        }
        glDisable(GL_SCISSOR_TEST);glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
        glClearColor(0,0,0,0);glClear(GL_COLOR_BUFFER_BIT);
        if(framebuffer_) {
            const auto w=std::min(width,width_),h=std::min(height,height_);
            glBindFramebuffer(GL_READ_FRAMEBUFFER,framebuffer_);
            // Shader UVs use top-left source coordinates; GL framebuffers are bottom-left.
            glBlitFramebuffer(0,height_-h,w,height_,0,height-h,w,height,GL_COLOR_BUFFER_BIT,GL_NEAREST);
        }
        reset();texture_=texture;framebuffer_=framebuffer;width_=width;height_=height;
        glBindFramebuffer(GL_FRAMEBUFFER,framebuffer_);return true;
    }
    void present(unsigned width,unsigned height,int x=0,int y=0,unsigned body_width=0,unsigned body_height=0) const {
        glBindFramebuffer(GL_READ_FRAMEBUFFER,framebuffer_);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER,0);glDisable(GL_SCISSOR_TEST);
        if(!body_width)body_width=width;
        if(!body_height)body_height=height;
        glClearColor(0,0,0,1);glClear(GL_COLOR_BUFFER_BIT);
        glBlitFramebuffer(0,0,width_,height_,x,height-y-body_height,x+body_width,height-y,GL_COLOR_BUFFER_BIT,GL_LINEAR);
        glBindFramebuffer(GL_FRAMEBUFFER,0);
    }
    unsigned width() const{return width_;}
    unsigned height() const{return height_;}
};

inline PixelRect retained_update_rect(const Tile& tile) {
    const bool body=tile.flags&16;
    const unsigned bx=body?tile.body_x:0,by=body?tile.body_y:0;
    const unsigned w=body?tile.body_width:tile.width,h=body?tile.body_height:tile.height;
    const auto r=resident_rect(tile);
    const unsigned left=std::max(bx,r.x),top=std::max(by,r.y);
    const unsigned right=std::min(bx+w,r.x+r.width),bottom=std::min(by+h,r.y+r.height);
    if(left>=right || top>=bottom)return {};
    return {left-bx,top-by,right-left,bottom-top};
}
class RetainedAlpha {
    std::array<unsigned,11> previous_layout_{};bool previous_valid_{};
public:
    unsigned width{},height{};std::vector<uint8_t> pixels;std::uint64_t revision{};
    void update(unsigned atlas_width,const Tile& tile,std::span<const uint8_t> alpha,bool same_source=false) {
        const bool body=tile.flags&16;
        const unsigned bx=body?tile.body_x:0,by=body?tile.body_y:0;
        const unsigned w=body?tile.body_width:tile.width,h=body?tile.body_height:tile.height;
        const auto resident=resident_rect(tile);
        const std::array<unsigned,11> layout{atlas_width,tile.atlas_x,tile.atlas_y,bx,by,w,h,resident.x,resident.y,resident.width,resident.height};
        if(same_source && previous_valid_ && previous_layout_==layout)return;
        previous_valid_=false;
        const auto incoming=retained_update_rect(tile);
        if(pixels.empty() && (!incoming.width || !incoming.height))return;
        bool changed=false;
        if(w!=width || h!=height) {
            changed=true;
            std::vector<uint8_t> next(size_t(w)*h,0);
            for(unsigned y=0;y<std::min(h,height);++y)
                std::copy_n(pixels.data()+size_t(y)*width,std::min(w,width),next.data()+size_t(y)*w);
            pixels=std::move(next);width=w;height=h;
        }
        const auto r=resident_rect(tile);
        const unsigned left=std::max(bx,r.x),top=std::max(by,r.y);
        const unsigned right=std::min(bx+w,r.x+r.width),bottom=std::min(by+h,r.y+r.height);
        if(left>=right || top>=bottom){if(changed)++revision;return;}
        for(unsigned y=top;y<bottom;++y) {
            const size_t offset=size_t(tile.atlas_y+y-r.y)*atlas_width+tile.atlas_x+left-r.x;
            const size_t count=right-left;
            if(count>alpha.size() || offset>alpha.size()-count)throw std::runtime_error("retained alpha atlas extent");
            const auto row=alpha.subspan(offset,count);
            auto* destination=pixels.data()+size_t(y-by)*w+left-bx;
            if(std::memcmp(row.data(),destination,count)) {std::memcpy(destination,row.data(),count);changed=true;}
        }
        if(changed)++revision;
        previous_layout_=layout;previous_valid_=true;
    }
};
}

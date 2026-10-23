#pragma once
#include "gpu_decoder.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <stdexcept>
// Standalone offscreen test adapter for the production decoder interface.
class ProgressiveTextureProbe {
    viewflow::reverse::GpuDecoder decoder_;
    bool complete_{};unsigned polls_{};
public:
    ProgressiveTextureProbe(){
    auto query=reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
    auto get_display=reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    EGLDeviceEXT devices[8]{};EGLint count{};if(!query || !get_display || !query(8,devices,&count) || !count)throw std::runtime_error("probe EGL devices");
    auto display=get_display(EGL_PLATFORM_DEVICE_EXT,devices[0],nullptr);
    if(!eglInitialize(display,nullptr,nullptr) || !eglBindAPI(EGL_OPENGL_ES_API))throw std::runtime_error("probe EGL init");
    const EGLint attrs[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config{};if(!eglChooseConfig(display,attrs,&config,1,&count) || !count)throw std::runtime_error("probe EGL config");
    const EGLint size[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE},version[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    auto surface=eglCreatePbufferSurface(display,config,size);auto context=eglCreateContext(display,config,EGL_NO_CONTEXT,version);
    if(!eglMakeCurrent(display,surface,surface,context))throw std::runtime_error("probe EGL context");

        decoder_.start(3);
    }
    void begin(std::shared_ptr<viewflow::reverse::shm::ProgressiveStorage::Read> lease){decoder_.begin_progressive(std::move(lease));}
    bool poll(){
        if(complete_)return true;
        const auto status=decoder_.poll_progressive();++polls_;
        if(status==viewflow::reverse::GpuDecoder::ProgressiveStatus::aborted)throw std::runtime_error("texture producer aborted");
        complete_=status==viewflow::reverse::GpuDecoder::ProgressiveStatus::complete;
        if(!complete_ && decoder_.y_texture())throw std::runtime_error("partial texture visible");
        return complete_;
    }
    std::vector<std::uint8_t> readback(unsigned width,unsigned height){
        if(!complete_)throw std::runtime_error("texture incomplete");
        GLuint fbo{};glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,decoder_.y_texture(),0);
        if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("texture framebuffer incomplete");
        std::vector<std::uint8_t> bytes(std::size_t(width)*height*4);
        glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,bytes.data());
        glDeleteFramebuffers(1,&fbo);
        if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("texture GL readback error");
        return bytes;
    }
    unsigned polls()const{return polls_;}
};

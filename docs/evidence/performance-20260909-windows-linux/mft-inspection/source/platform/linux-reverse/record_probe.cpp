#include "gpu_decoder.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
extern "C" {
#include <libavcodec/avcodec.h>
}
#include <fstream>
#include <iterator>
#include <cstdio>
#include <stdexcept>
#include <chrono>
#include "../reverse-common/wire.hpp"
int main(int argc,char** argv) {
    if(argc!=2 && argc!=3 && argc!=5) return 2;
    try {
        const unsigned codec_id=argc>=3?static_cast<unsigned>(std::stoul(argv[2])):1;
        if(codec_id!=1 && codec_id!=2) return 2;
        const unsigned expected_width=argc==5?static_cast<unsigned>(std::stoul(argv[3])):0;
        const unsigned expected_height=argc==5?static_cast<unsigned>(std::stoul(argv[4])):0;
        auto query=reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
        auto display_for=reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
        EGLDeviceEXT devices[8]{}; EGLint count{};
        if(!query || !display_for || !query(8,devices,&count) || !count) return 3;
        EGLDisplay display=display_for(EGL_PLATFORM_DEVICE_EXT,devices[0],nullptr);
        if(!eglInitialize(display,nullptr,nullptr) || !eglBindAPI(EGL_OPENGL_ES_API)) return 4;
        const EGLint attrs[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_NONE};
        EGLConfig config{}; if(!eglChooseConfig(display,attrs,&config,1,&count) || !count) return 5;
        const EGLint size[]={EGL_WIDTH,2,EGL_HEIGHT,2,EGL_NONE};
        EGLSurface surface=eglCreatePbufferSurface(display,config,size);
        const EGLint version[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
        EGLContext context=eglCreateContext(display,config,EGL_NO_CONTEXT,version);
        if(!eglMakeCurrent(display,surface,surface,context)) return 6;
        {
            viewflow::reverse::GpuDecoder decoder; decoder.start(codec_id);
            std::ifstream file(argv[1],std::ios::binary);if(!file)throw std::runtime_error("record file missing");
            unsigned units=0,decoded=0,previous=0;GLuint fbo{};glGenFramebuffers(1,&fbo);
            const auto ns=[](){return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();};
            for(;;){
                std::uint32_t size{};file.read(reinterpret_cast<char*>(&size),4);
                if(file.eof() && file.gcount()==0)break;
                if(file.gcount()!=4 || size>viewflow::reverse::max_record)throw std::runtime_error("record prefix invalid");
                std::vector<std::uint8_t> bytes(size);file.read(reinterpret_cast<char*>(bytes.data()),size);
                if(file.gcount()!=size)throw std::runtime_error("record truncated");
                const auto frame=viewflow::reverse::unpack_frame(bytes);
                if(frame.codec!=codec_id || frame.width!=expected_width || frame.height!=expected_height || frame.tiles.size()!=1 || frame.tiles[0].width!=expected_width || frame.tiles[0].height!=expected_height)throw std::runtime_error("fixture dimensions or tile count mismatch");
                const auto begin=ns();auto frames=decoder.submit(frame.color,frame.pts);const auto decode_end=ns();++units;
                for(auto& image:frames){
                    if(image->width!=expected_width || image->height!=expected_height)throw std::runtime_error("decoded dimensions mismatch");
                    const auto upload_begin=ns();decoder.upload(image);const auto uploaded=ns();++decoded;
                    glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,decoder.y_texture(),0);
                    if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("marker framebuffer incomplete");
                    std::vector<std::uint8_t> top(3072*4),bottom(3072*4);
                    glReadPixels(0,32,3072,1,GL_RGBA,GL_UNSIGNED_BYTE,top.data());glReadPixels(0,96,3072,1,GL_RGBA,GL_UNSIGNED_BYTE,bottom.data());
                    const auto error=glGetError();if(error)throw std::runtime_error("marker read GL error="+std::to_string(error));
                    unsigned marker=0;
                    for(unsigned bit=0;bit<24;++bit){const auto a=top[(bit*128+64)*4],b=bottom[(bit*128+64)*4];if(!((a<90 && b>160)||(a>160 && b<90)))throw std::runtime_error("invalid complementary marker");if(a>160)marker|=1u<<bit;}
                    if(!marker || marker<previous)throw std::runtime_error("marker sequence regression");previous=marker;
                    std::fprintf(stderr,"record_frame pts=%lld marker=%u decode_ns=%lld upload_ns=%lld\n",static_cast<long long>(image->pts),marker,static_cast<long long>(decode_end-begin),static_cast<long long>(uploaded-upload_begin));
                    glBindFramebuffer(GL_FRAMEBUFFER,0);
                }
            }
            std::fprintf(stderr,"record_decode units=%u decoded=%u gl_error=%u\n",units,decoded,glGetError());
            if(!units || units!=decoded)throw std::runtime_error("incomplete record decode");
            glDeleteFramebuffers(1,&fbo);
        }
        eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
        eglDestroyContext(display,context);eglDestroySurface(display,surface);eglTerminate(display);
        return 0;
    } catch(const std::exception& error) {std::fprintf(stderr,"%s\n",error.what());return 8;}
}

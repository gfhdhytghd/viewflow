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
#include <algorithm>
#include <map>
#include "../reverse-common/wire.hpp"
int main(int argc,char** argv) {
    if(argc!=2) return 2;
    try {
        const unsigned codec_id=2;
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
            std::map<std::int64_t,std::pair<unsigned,unsigned>> expected;
            unsigned units=0,decoded=0;GLuint fbo{};glGenFramebuffers(1,&fbo);
            const auto ns=[](){return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();};
            for(;;){
                std::uint32_t size{};file.read(reinterpret_cast<char*>(&size),4);
                if(file.eof() && file.gcount()==0)break;
                if(file.gcount()!=4 || size>viewflow::reverse::max_record)throw std::runtime_error("record prefix invalid");
                std::vector<std::uint8_t> bytes(size);file.read(reinterpret_cast<char*>(bytes.data()),size);
                if(file.gcount()!=size)throw std::runtime_error("record truncated");
                const auto frame=viewflow::reverse::unpack_frame(bytes);
                if(frame.codec!=codec_id)throw std::runtime_error("lifecycle codec mismatch");
                const auto alpha=viewflow::reverse::decode_alpha(frame.alpha,std::size_t(frame.width)*frame.height);
                std::vector<std::uint8_t> reference(alpha.size(),0);
                std::fprintf(stderr,"lifecycle_frame pts=%lld width=%u height=%u tiles=%zu keyframe=%u\n",static_cast<long long>(frame.pts),frame.width,frame.height,frame.tiles.size(),unsigned(frame.keyframe));
                for(const auto& t:frame.tiles){
                    const bool stripes=t.title=="lifecycle-original" || t.title=="lifecycle-renamed";
                    if(!stripes && t.title!="lifecycle-second")throw std::runtime_error("unexpected source window");
                    for(unsigned y=0;y<t.height;++y)for(unsigned x=0;x<t.width;++x){
                        const unsigned a=stripes?(x<t.width/4?0:x<t.width/2?64:x<3*t.width/4?128:255):255;
                        reference[std::size_t(t.atlas_y+y)*frame.width+t.atlas_x+x]=static_cast<std::uint8_t>(a);
                    }
                    std::fprintf(stderr,"lifecycle_tile pts=%lld id=%llu title=%s x=%d y=%d width=%u height=%u atlas_x=%u atlas_y=%u\n",static_cast<long long>(frame.pts),static_cast<unsigned long long>(t.id),t.title.c_str(),t.x,t.y,t.width,t.height,t.atlas_x,t.atlas_y);
                }
                if(alpha!=reference){const auto mismatch=std::mismatch(alpha.begin(),alpha.end(),reference.begin());const auto at=std::distance(alpha.begin(),mismatch.first);throw std::runtime_error("lifecycle alpha mismatch offset="+std::to_string(at)+" got="+std::to_string(*mismatch.first)+" expected="+std::to_string(*mismatch.second));}
                if(!expected.emplace(frame.pts,std::pair{frame.width,frame.height}).second)throw std::runtime_error("repeated source timestamp");
                const auto begin=ns();auto frames=decoder.submit(frame.color,frame.pts);const auto decode_end=ns();++units;
                for(auto& image:frames){
                    const auto found=expected.find(image->pts);if(found==expected.end())throw std::runtime_error("unexpected decoded timestamp");
                    if(image->width!=found->second.first || image->height!=found->second.second)throw std::runtime_error("decoded lifecycle dimensions mismatch");
                    const auto upload_begin=ns();decoder.upload(image);const auto uploaded=ns();++decoded;
                    if(glGetError())throw std::runtime_error("lifecycle GPU upload error");
                    std::fprintf(stderr,"lifecycle_decoded pts=%lld width=%d height=%d decode_ns=%lld upload_ns=%lld\n",static_cast<long long>(image->pts),image->width,image->height,static_cast<long long>(decode_end-begin),static_cast<long long>(uploaded-upload_begin));expected.erase(found);

                }
            }
            std::fprintf(stderr,"record_decode units=%u decoded=%u gl_error=%u fixture_alpha=verified\n",units,decoded,glGetError());
            if(!units || units!=decoded || !expected.empty())throw std::runtime_error("incomplete record decode");
            glDeleteFramebuffers(1,&fbo);
        }
        eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
        eglDestroyContext(display,context);eglDestroySurface(display,surface);eglTerminate(display);
        return 0;
    } catch(const std::exception& error) {std::fprintf(stderr,"%s\n",error.what());return 8;}
}

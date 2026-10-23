#include "gpu_alpha.hpp"
#include "gpu_decoder.hpp"
#include "bgra_alpha.hpp"
#include "alpha_upload_overlap.hpp"
#include "../reverse-common/wire.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <thread>
using namespace viewflow::reverse;
int main() {
    auto query=reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
    auto getDisplay=reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    EGLDeviceEXT devices[8]{};EGLint count=0;assert(query&&getDisplay&&query(8,devices,&count)&&count);
    auto display=getDisplay(EGL_PLATFORM_DEVICE_EXT,devices[0],nullptr);assert(eglInitialize(display,nullptr,nullptr));
    assert(eglBindAPI(EGL_OPENGL_ES_API));
    const EGLint attrs[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config{};assert(eglChooseConfig(display,attrs,&config,1,&count)&&count);
    const EGLint size[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE},version[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    auto surface=eglCreatePbufferSurface(display,config,size);auto context=eglCreateContext(display,config,EGL_NO_CONTEXT,version);
    assert(eglMakeCurrent(display,surface,surface,context));
    {
        GpuAlpha gpu;GpuDecoder decoder;decoder.start(3);AlphaUploadOverlap overlap;
        for(auto [w,h]:{std::pair{1u,1u},{3u,7u},{17u,9u},{257u,513u},{6144u,3456u},{31u,2u}}) {
            auto bytes=std::make_shared<std::vector<std::uint8_t>>(std::size_t(w)*h*4);
            for(std::size_t i=0;i<bytes->size();++i)(*bytes)[i]=(i*73+i/257)%256;
            auto pixels=std::make_shared<SharedPixels>(SharedPixels{bytes,*bytes,bytes});
            auto frame=decoder.raw_bgra(pixels,w,h,1);
            std::vector<std::uint8_t> alpha(std::size_t(w)*h+2,0x7b);
            auto target=std::span(alpha).subspan(1,alpha.size()-2);
            for(unsigned round=0;round<3;++round) {
                for(std::size_t i=0;i<target.size();++i)(*bytes)[i*4+3]=((*bytes)[i*4+3]+round*71)%256;
                decoder.upload(frame);glEnable(GL_CULL_FACE);glCullFace(GL_FRONT_AND_BACK);
                glEnable(GL_SCISSOR_TEST);glScissor(0,0,0,0);glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);
                assert(gpu.extract(decoder.y_texture(),w,h,target,true));
                assert(!gpu.extract(decoder.y_texture(),w,h,target,true));
                assert(alpha.front()==0x7b && alpha.back()==0x7b);
                for(std::size_t i=0;i<target.size();++i)assert(target[i]==(*bytes)[i*4+3]);
            }
            if(w==6144)for(unsigned method=0;method<4;++method) {
                std::vector<double> samples;
                for(unsigned k=0;k<65;++k) {
                    const auto begin=std::chrono::steady_clock::now();
                    if(method==0){extract_bgra_alpha(*bytes,target);decoder.upload(frame);}
                    else if(method==1)overlap.run(*bytes,target,[&]{decoder.upload(frame);});
                    else {decoder.upload(frame);gpu.extract(decoder.y_texture(),w,h,target,method==3);}
                    glFinish();
                    const auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
                    if(k>=5)samples.push_back(ms);
                }
                std::sort(samples.begin(),samples.end());
                std::printf("6K upload+alpha method=%s p50_ms=%.3f p95_ms=%.3f renderer=%s\n",method==0?"serial":method==1?"overlap":method==2?"gpu":"gpu-unchanged",samples[30],samples[57],glGetString(GL_RENDERER));
            }
        }
        // Same packed framebuffer size, different source length: zeros in
        // padding must not cause reuse of an alpha plane with the old extent.
        for(unsigned w:{1u,2u,3u}) {
            auto bytes=std::make_shared<std::vector<std::uint8_t>>(w*4,0);
            auto frame=decoder.raw_bgra(bytes,w,1,2);decoder.upload(frame);
            std::vector<std::uint8_t> target(w,0x7b);
            assert(gpu.extract(decoder.y_texture(),w,1,target,true));
            assert(std::all_of(target.begin(),target.end(),[](auto v){return v==0;}));
        }
        // Nonblocking two-stage alpha metadata; changing source after submit
        // cannot alter the queued extraction, and older versions never win.
        GpuAlphaAsync async;
        std::uint64_t version_id=100;
        auto finish_async=[&]() {
            const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
            while(std::chrono::steady_clock::now()<deadline) {
                if(auto result=async.poll())return *result;
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            assert(false && "async alpha completion watchdog");return GpuAlphaAsync::Result{};
        };
        for(auto [w,h]:{std::pair{1u,1u},{3u,1u},{17u,9u},{257u,513u},{6144u,3456u},{31u,2u}}) {
            auto bytes=std::make_shared<std::vector<std::uint8_t>>(std::size_t(w)*h*4,0);
            for(std::size_t i=0;i<std::size_t(w)*h;++i)(*bytes)[i*4+3]=(i*37)%256;
            auto frame=decoder.raw_bgra(bytes,w,h,3);decoder.upload(frame);
            const auto submitted=++version_id;
            assert(async.submit(decoder.y_texture(),w,h,submitted));
            assert(async.pending());
            assert(!async.submit(decoder.y_texture(),w,h,submitted+1));
            auto result=finish_async();
            assert(result.version==submitted && result.width==w && result.height==h && result.changed);
            for(std::size_t i=0;i<result.pixels->size();++i)assert((*result.pixels)[i]==(*bytes)[i*4+3]);
            assert(!async.poll() && !async.pending());
            assert(!async.submit(decoder.y_texture(),w,h,submitted));
            assert(!async.submit(decoder.y_texture(),w,h,submitted-1));
            assert(async.submit(decoder.y_texture(),w,h,++version_id));
            result=finish_async();assert(!result.changed && result.pixels && result.pixels->size()==std::size_t(w)*h);
            (*bytes)[3]^=0x7f;decoder.upload(frame);
            assert(async.submit(decoder.y_texture(),w,h,++version_id));
            result=finish_async();assert(result.changed && (*result.pixels)[0]==(*bytes)[3]);
            assert(async.submit(decoder.y_texture(),w,h,++version_id));
            result=finish_async();assert(!result.changed);
        }
        // Source can be reused on the same ordered GL context immediately;
        // extraction must preserve the pixels associated with its version.
        {
            auto bytes=std::make_shared<std::vector<std::uint8_t>>(16*4,0x12);
            auto frame=decoder.raw_bgra(bytes,16,1,4);decoder.upload(frame);
            assert(async.submit(decoder.y_texture(),16,1,++version_id));
            std::fill(bytes->begin(),bytes->end(),0x91);decoder.upload(frame);
            auto result=finish_async();
            assert(std::all_of(result.pixels->begin(),result.pixels->end(),[](auto v){return v==0x12;}));
            assert(async.submit(decoder.y_texture(),16,1,++version_id));
            result=finish_async();
            assert(std::all_of(result.pixels->begin(),result.pixels->end(),[](auto v){return v==0x91;}));
            assert(async.submit(decoder.y_texture(),16,1,++version_id));
            async.reset();assert(!async.pending() && !async.poll());
            assert(async.submit(decoder.y_texture(),16,1,1));
            result=finish_async();assert(result.version==1 && result.changed);
        }
        async.reset();
        std::puts("async alpha changed/unchanged, monotonic versions, resize and partial rows PASS");
        gpu.reset();
    }
    eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);eglDestroyContext(display,context);eglDestroySurface(display,surface);eglTerminate(display);
}

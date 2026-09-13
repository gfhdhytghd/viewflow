#include "gpu_decoder.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <chrono>
#include <algorithm>
extern "C" {
#include <libavcodec/avcodec.h>
}
#include <fstream>
#include <iterator>
#include <cstdio>
#include <stdexcept>
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
            std::ifstream file(argv[1],std::ios::binary);
            std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(file)),{});
            const auto total=bytes.size(); bytes.resize(total+AV_INPUT_BUFFER_PADDING_SIZE,0);
            AVCodecParserContext* parser=av_parser_init(codec_id==2?AV_CODEC_ID_HEVC:AV_CODEC_ID_H264);
            AVCodecContext* codec=avcodec_alloc_context3(nullptr);
            std::size_t offset=0; unsigned decoded=0,units=0,width=0,height=0;
            std::vector<double> decode_upload_ms;
            for(;;) {
                std::uint8_t* unit{};int length{};
                const bool flushing=offset==total;
                int consumed=av_parser_parse2(parser,codec,&unit,&length,flushing?nullptr:bytes.data()+offset,static_cast<int>(total-offset),AV_NOPTS_VALUE,AV_NOPTS_VALUE,0);
                if(consumed<0) throw std::runtime_error("parser failure");
                offset+=consumed;
                if(length) {
                    auto started=std::chrono::steady_clock::now();
                    auto frames=decoder.submit({unit,static_cast<std::size_t>(length)},units++*166667ll);
                    for(auto& frame:frames) {
                        width=frame->width;height=frame->height;
                        if(expected_width && (width!=expected_width || height!=expected_height))
                            throw std::runtime_error("decoded dimensions differ from requested fixture");
                        decoder.upload(frame);glFinish();++decoded;
                        decode_upload_ms.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count());
                        started=std::chrono::steady_clock::now();
                    }
                }
                if(!length && flushing) break;
                if(!consumed && offset!=total && !length) throw std::runtime_error("parser stalled");
            }
            av_parser_close(parser);avcodec_free_context(&codec);
            std::fprintf(stderr,"reverse GPU decode units=%u decoded=%u gl_error=%u renderer=%s\n",units,decoded,glGetError(),glGetString(GL_RENDERER));
            std::fprintf(stderr,"reverse GPU dimensions width=%u height=%u codec=%u\n",width,height,codec_id);
            if(decode_upload_ms.size()>10) {
                decode_upload_ms.erase(decode_upload_ms.begin(),decode_upload_ms.begin()+10);
                std::sort(decode_upload_ms.begin(),decode_upload_ms.end());
                std::fprintf(stderr,"reverse GPU decode+upload completed median-ms=%.3f p95-ms=%.3f samples=%zu (no presentation)\n",
                    decode_upload_ms[decode_upload_ms.size()/2],decode_upload_ms[decode_upload_ms.size()*95/100],decode_upload_ms.size());
            }
            if(decoded<59) return 7;
        }
        eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
        eglDestroyContext(display,context);eglDestroySurface(display,surface);eglTerminate(display);
        return 0;
    } catch(const std::exception& error) {std::fprintf(stderr,"%s\n",error.what());return 8;}
}

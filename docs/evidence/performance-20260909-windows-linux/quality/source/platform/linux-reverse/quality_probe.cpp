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
#include <set>
#include <cmath>
#include "../reverse-common/wire.hpp"
int main(int argc,char** argv) {
    if(argc!=2 && argc!=3 && argc!=5 && argc!=6) return 2;
    try {
        const unsigned codec_id=argc>=3?static_cast<unsigned>(std::stoul(argv[2])):1;
        if(codec_id!=1 && codec_id!=2) return 2;
        const unsigned expected_width=argc>=5?static_cast<unsigned>(std::stoul(argv[3])):0;
        const unsigned expected_height=argc>=5?static_cast<unsigned>(std::stoul(argv[4])):0;
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
            std::set<unsigned> selected,compared_markers;if(argc==6){std::ifstream list(argv[5]);unsigned n;while(list>>n)selected.insert(n);if(selected.empty())throw std::runtime_error("quality marker list empty");}
            const char* vs_source=R"(#version 300 es
void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.0-1.0,0,1);})";
            const char* fs_source=R"(#version 300 es
precision highp float;precision highp int;
uniform sampler2D luma;uniform sampler2D chroma;uniform uint marker;out vec4 result;
vec3 reference(ivec2 p){if(p.y<128){uint bit=uint(p.x/128)%24u;uint v=(marker>>bit)&1u;if(p.y>=64)v=1u-v;return vec3(float(v));}vec3 c=vec3(float((uint(p.x/96)+marker/4u)%17u)/16.0,float((p.y/96)%13)/12.0,0.3);if(abs(p.x-int((marker*21u)%6144u))<24)c=vec3(1);return floor(c*255.0+0.5)/255.0;}
void main(){ivec2 base=ivec2(gl_FragCoord.xy)*16;vec3 total=vec3(0);float maximum=0.0;for(int y=0;y<16;y++)for(int x=0;x<16;x++){ivec2 q=base+ivec2(x,y);vec2 p=(vec2(q)+vec2(0.5))/vec2(6144,3456);float l=(texture(luma,p).r-16.0/255.0)*255.0/219.0;vec2 c=(texture(chroma,p).rg-vec2(128.0/255.0))*255.0/224.0;vec3 rgb=clamp(vec3(l+1.5748*c.y,l-0.187324*c.x-0.468124*c.y,l+1.8556*c.x),0.0,1.0);vec3 delta=rgb-reference(q);total+=delta*delta;maximum=max(maximum,max(abs(delta.r),max(abs(delta.g),abs(delta.b))));}result=vec4(total,maximum);})";
            const auto compile=[](GLenum type,const char* text){GLuint s=glCreateShader(type);glShaderSource(s,1,&text,nullptr);glCompileShader(s);GLint okay;glGetShaderiv(s,GL_COMPILE_STATUS,&okay);if(!okay){char error[2048];glGetShaderInfoLog(s,2048,nullptr,error);throw std::runtime_error(error);}return s;};
            GLuint program=glCreateProgram(),vs=compile(GL_VERTEX_SHADER,vs_source),fs=compile(GL_FRAGMENT_SHADER,fs_source);glAttachShader(program,vs);glAttachShader(program,fs);glLinkProgram(program);GLint linked;glGetProgramiv(program,GL_LINK_STATUS,&linked);if(!linked)throw std::runtime_error("quality program link failed");glDeleteShader(vs);glDeleteShader(fs);
            GLuint quality_texture{},quality_fbo{};glGenTextures(1,&quality_texture);glBindTexture(GL_TEXTURE_2D,quality_texture);glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA32F,384,216);glGenFramebuffers(1,&quality_fbo);glBindFramebuffer(GL_FRAMEBUFFER,quality_fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,quality_texture,0);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("quality float framebuffer incomplete");glBindFramebuffer(GL_FRAMEBUFFER,0);
            std::vector<float> sums(384*216*4);unsigned compared=0;
            std::vector<std::uint8_t> last_alpha;
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
                if(frame.alpha!=last_alpha){const auto alpha=viewflow::reverse::decode_alpha(frame.alpha,std::size_t(expected_width)*expected_height);if(!std::all_of(alpha.begin(),alpha.end(),[](auto v){return v==255;}))throw std::runtime_error("opaque fixture alpha mismatch");last_alpha=frame.alpha;}
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
                    if(selected.contains(marker) && compared_markers.insert(marker).second){
                        glBindFramebuffer(GL_FRAMEBUFFER,quality_fbo);glViewport(0,0,384,216);glUseProgram(program);glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,decoder.y_texture());glUniform1i(glGetUniformLocation(program,"luma"),0);glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,decoder.uv_texture());glUniform1i(glGetUniformLocation(program,"chroma"),1);glUniform1ui(glGetUniformLocation(program,"marker"),marker);glDrawArrays(GL_TRIANGLES,0,3);glReadPixels(0,0,384,216,GL_RGBA,GL_FLOAT,sums.data());if(glGetError())throw std::runtime_error("quality rendering GL error");double sum=0,peak=0;for(size_t i=0;i<sums.size();i+=4){sum+=sums[i]+sums[i+1]+sums[i+2];peak=std::max(peak,double(sums[i+3]));}const double mse=sum/(6144.0*3456.0*3.0);std::fprintf(stderr,"quality_frame marker=%u mse=%.12g psnr=%.9g max_error=%.9g\n",marker,mse,-10*std::log10(std::max(mse,1e-20)),peak);++compared;
                    }
                    glBindFramebuffer(GL_FRAMEBUFFER,0);
                }
            }
            std::fprintf(stderr,"record_decode units=%u decoded=%u gl_error=%u opaque_alpha=verified\n",units,decoded,glGetError());
            if(!units || units!=decoded)throw std::runtime_error("incomplete record decode");
            if(compared!=selected.size())throw std::runtime_error("quality marker coverage mismatch");std::fprintf(stderr,"quality_complete frames=%u full_pixels_per_frame=21233664\n",compared);glDeleteFramebuffers(1,&quality_fbo);glDeleteTextures(1,&quality_texture);glDeleteProgram(program);glDeleteFramebuffers(1,&fbo);
        }
        eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
        eglDestroyContext(display,context);eglDestroySurface(display,surface);eglTerminate(display);
        return 0;
    } catch(const std::exception& error) {std::fprintf(stderr,"%s\n",error.what());return 8;}
}

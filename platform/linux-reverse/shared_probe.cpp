#include "shared_mapping.hpp"
#include "gpu_decoder.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <cstdio>
#include <chrono>
#include <algorithm>
using namespace viewflow::reverse;
int main(int argc,char** argv){try{
    const bool performance=argc>2 && std::string(argv[2])=="--performance";
    const auto started=std::chrono::steady_clock::now();
    auto mapping=std::make_shared<shm::Mapping>(argc>1?argv[1]:"/dev/shm/viewflow-frames");auto shared=mapping->frames();
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
    const char* vs="#version 300 es\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.0-1.0,0,1);}";
    const char* fs="#version 300 es\nprecision highp float;uniform sampler2D pixels;uniform vec2 point;out vec4 color;void main(){color=texture(pixels,point);}";
    auto shader=[](GLenum type,const char* text){auto s=glCreateShader(type);glShaderSource(s,1,&text,nullptr);glCompileShader(s);GLint ok{};glGetShaderiv(s,GL_COMPILE_STATUS,&ok);if(!ok)throw std::runtime_error("probe shader");return s;};
    auto program=glCreateProgram();glAttachShader(program,shader(GL_VERTEX_SHADER,vs));glAttachShader(program,shader(GL_FRAGMENT_SHADER,fs));glLinkProgram(program);GLint linked{};glGetProgramiv(program,GL_LINK_STATUS,&linked);if(!linked)throw std::runtime_error("probe program");glUseProgram(program);glViewport(0,0,1,1);glDisable(GL_DITHER);
    GpuDecoder decoder;decoder.start(3);unsigned received=0,stale=0,warm_received=0,warm_stale=0;std::chrono::steady_clock::time_point warm_begin{},warm_end{};std::vector<double> copy_times,upload_times;
    for(;;){std::uint8_t prefix[4];const auto got=fread(prefix,1,4,stdin);if(!got)break;if(got!=4)throw std::runtime_error("probe prefix");Reader r{{prefix,4}};auto length=r.u32();if(length>max_record)throw std::runtime_error("probe length");std::vector<std::uint8_t> bytes(length);if(fread(bytes.data(),1,length,stdin)!=length)throw std::runtime_error("probe record");auto f=unpack_frame(bytes);
        auto begin=std::chrono::steady_clock::now();std::shared_ptr<SharedPixels> pixels;
        if(std::getenv("VIEWFLOW_SHM_LEASE"))pixels=shared.acquire(f.color,f.width,f.height,mapping);
        else {auto copy=shared.read(f.color,f.width,f.height);if(copy)pixels=std::make_shared<SharedPixels>(SharedPixels{copy,*copy});}auto copied=std::chrono::steady_clock::now();if(!pixels){++stale;if(performance && f.pts>60)++warm_stale;continue;}
        if(!performance)for(unsigned y=0;y<f.height;++y)for(unsigned x=0;x<f.width;++x){const auto* p=pixels->data()+(std::size_t(y)*f.width+x)*4;if(p[0]!=(x+f.pts)%251 || p[1]!=(y+f.pts)%251 || p[2]!=f.pts%251 || p[3]!=128+(x+y)%128)throw std::runtime_error("shared pixel mismatch");}
        auto frame=decoder.raw_bgra(pixels,f.width,f.height,f.pts);auto upload=std::chrono::steady_clock::now();decoder.upload(frame);glFinish();auto uploaded=std::chrono::steady_clock::now();
        glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,decoder.y_texture());glUniform1i(glGetUniformLocation(program,"pixels"),0);
        if(!performance)for(auto point:{std::pair{0u,0u},std::pair{f.width/2,f.height/2},std::pair{f.width-1,f.height-1}}){auto [x,y]=point;glUniform2f(glGetUniformLocation(program,"point"),(x+.5f)/f.width,(y+.5f)/f.height);glDrawArrays(GL_TRIANGLES,0,3);std::uint8_t rgba[4]{};glReadPixels(0,0,1,1,GL_RGBA,GL_UNSIGNED_BYTE,rgba);const auto* p=pixels->data()+(std::size_t(y)*f.width+x)*4;if(rgba[0]!=p[2] || rgba[1]!=p[1] || rgba[2]!=p[0] || rgba[3]!=p[3])throw std::runtime_error("GPU BGRA/alpha mismatch");}
        if(performance && f.pts>60){if(!warm_received)warm_begin=uploaded;warm_end=uploaded;++warm_received;}
        if(glGetError())throw std::runtime_error("probe GL error");
        copy_times.push_back(std::chrono::duration<double,std::milli>(copied-begin).count());upload_times.push_back(std::chrono::duration<double,std::milli>(uploaded-upload).count());++received;
    }
    if(!received)throw std::runtime_error("no shared frames received");
    if(warm_received>1)std::fprintf(stderr,"after_warmup_received=%u obsolete=%u delivered_fps=%.3f warmup=60_source_frames\n",warm_received,warm_stale,(warm_received-1)/std::chrono::duration<double>(warm_end-warm_begin).count());
    std::sort(copy_times.begin(),copy_times.end());std::sort(upload_times.begin(),upload_times.end());
    std::fprintf(stderr,"ivshmem-probe received=%u obsolete=%u exact_cpu_pixels=%s gpu_rgb_alpha=%s renderer=%s copy_p50_ms=%.3f copy_p95_ms=%.3f upload_complete_p50_ms=%.3f upload_complete_p95_ms=%.3f (no desktop presentation)\n",received,stale,performance?"not_checked":"true",performance?"not_checked":"true",glGetString(GL_RENDERER),copy_times[received/2],copy_times[received*95/100],upload_times[received/2],upload_times[received*95/100]);std::fprintf(stderr,"receiver_elapsed_ms=%.3f (includes pipe startup/waits; no desktop presentation)\n",std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count());return 0;
}catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 1;}}

// Explicit isolated GPU validation; never registered in CTest.
#include "gpu_decoder.hpp"
#include "raw_dmabuf_upload.hpp"
#include <linux/udmabuf.h>
#include <linux/memfd.h>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <charconv>
#include <cstdio>
#include <vector>
#include <chrono>
#include <stdexcept>
using namespace viewflow::reverse;
namespace {
constexpr std::size_t capacity=1ull<<30;
void need(bool value,const char* text){if(!value)throw std::runtime_error(text);}
unsigned long long num(const char* text){unsigned long long n{};const auto end=text+std::strlen(text);auto r=std::from_chars(text,end,n);need(r.ec==std::errc{} && r.ptr==end,"integer");return n;}
struct Backing {
    int mem=-1,dma=-1;void* data=MAP_FAILED;
    ~Backing(){if(dma>=0)close(dma);if(data!=MAP_FAILED)munmap(data,capacity);if(mem>=0)close(mem);}
};
struct Context {
    EGLDisplay display=EGL_NO_DISPLAY;EGLContext context=EGL_NO_CONTEXT;EGLSurface surface=EGL_NO_SURFACE;
    ~Context(){if(display!=EGL_NO_DISPLAY){eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);if(context!=EGL_NO_CONTEXT)eglDestroyContext(display,context);if(surface!=EGL_NO_SURFACE)eglDestroySurface(display,surface);eglTerminate(display);}}
    void start(unsigned index){
        auto query=reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
        auto get=reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
        EGLDeviceEXT devices[32]{};EGLint count{};need(query&&get&&query(32,devices,&count)&&index<unsigned(count),"EGL device");
        display=get(EGL_PLATFORM_DEVICE_EXT,devices[index],nullptr);need(eglInitialize(display,nullptr,nullptr)&&eglBindAPI(EGL_OPENGL_ES_API),"EGL initialize");
        EGLint attrs[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};EGLConfig config{};
        need(eglChooseConfig(display,attrs,&config,1,&count)&&count,"config");
        EGLint sz[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE},version[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
        surface=eglCreatePbufferSurface(display,config,sz);context=eglCreateContext(display,config,EGL_NO_CONTEXT,version);need(eglMakeCurrent(display,surface,surface,context),"context");
    }
};
GLuint shader(GLenum type,const char* code){GLuint s=glCreateShader(type);glShaderSource(s,1,&code,nullptr);glCompileShader(s);GLint ok{};glGetShaderiv(s,GL_COMPILE_STATUS,&ok);need(ok,"test shader compile");return s;}
void validate(GLuint texture,unsigned w,unsigned h,unsigned revision=0){
    GLuint target{},fbo{},program{},vao{};glGenTextures(1,&target);glBindTexture(GL_TEXTURE_2D,target);glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,w,h);
    glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,target,0);need(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE,"test FBO");
    auto vs=shader(GL_VERTEX_SHADER,"#version 300 es\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.0-1.0,0,1);}");
    auto fs=shader(GL_FRAGMENT_SHADER,"#version 300 es\nprecision highp float;uniform highp sampler2D source;out vec4 c;void main(){c=texelFetch(source,ivec2(gl_FragCoord.xy),0);}");
    program=glCreateProgram();glAttachShader(program,vs);glAttachShader(program,fs);glLinkProgram(program);GLint ok{};glGetProgramiv(program,GL_LINK_STATUS,&ok);need(ok,"test link");glDeleteShader(vs);glDeleteShader(fs);
    glUseProgram(program);glUniform1i(glGetUniformLocation(program,"source"),0);glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,texture);glBindSampler(0,0);glGenVertexArrays(1,&vao);glBindVertexArray(vao);
    for(auto flag:{GL_CULL_FACE,GL_SCISSOR_TEST,GL_BLEND,GL_DITHER,GL_DEPTH_TEST,GL_STENCIL_TEST,GL_RASTERIZER_DISCARD})glDisable(flag);
    glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glViewport(0,0,w,h);glDrawArrays(GL_TRIANGLES,0,3);
    std::vector<unsigned char> result(std::size_t(w)*h*4);glReadPixels(0,0,w,h,GL_RGBA,GL_UNSIGNED_BYTE,result.data());glFinish();need(glGetError()==GL_NO_ERROR,"test readback");
    std::size_t wrong=0;
    for(std::size_t p=0;p<result.size()/4;++p)for(unsigned c=0;c<4;++c){const auto i=p*4+(c==0?2:c==2?0:c);if(result[p*4+c]!=((i*37+(i>>8)+91+revision*17)&255))++wrong;}
    std::printf("sampled snapshot BGRA swizzle+alpha full bytes=%zu mismatches=%zu\n",result.size(),wrong);
    glUseProgram(0);glDeleteProgram(program);glDeleteVertexArrays(1,&vao);glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&target);need(!wrong,"snapshot mismatch");
}
void cache_test(const std::shared_ptr<Backing>& backing){
    RawDmaBufUpload upload;GLuint texture{};glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
    glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,1024,1024);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_SWIZZLE_R,GL_BLUE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_SWIZZLE_B,GL_RED);
    auto submit=[&](int fd,unsigned width=1024,unsigned height=1024){
        auto slot=std::make_shared<int>(1);std::weak_ptr<int> weak=slot;
        auto pixels=std::make_shared<SharedPixels>();pixels->owner=slot;
        // Deliberately new wrapper every frame, as in Mapping::dma_buffer.
        auto wrapper=std::shared_ptr<int>(new int(dup(fd)),[backing](int* owned){close(*owned);delete owned;});
        need(*wrapper>=0,"cache owner duplicate");
        pixels->dma_buffer=std::make_shared<SharedDmaBuffer>(SharedDmaBuffer{fd,0,width*4,wrapper});
        upload.upload(pixels,texture,width,height);pixels.reset();slot.reset();
        need(!weak.expired(),"cached upload lost slot before poll");glFinish();upload.poll();
        need(weak.expired(),"cache retained slot lease");
    };
    int borrowed=dup(backing->dma);need(borrowed>=0,"dup DMA descriptor");
    submit(borrowed);const auto start=std::chrono::steady_clock::now();
    for(unsigned i=0;i<32;++i)submit(borrowed);
    const auto elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    need(upload.import_count()==1&&upload.cache_hits()==32,"stable export cache miss");validate(texture,1024,1024);
    std::printf("cache repeated uploads=32 imports=%zu hits=%zu wall_finish_ms_per_upload=%.6f\n",upload.import_count(),upload.cache_hits(),elapsed/32);
    auto update=[&](unsigned revision){
        dma_buf_sync sync{};sync.flags=DMA_BUF_SYNC_START|DMA_BUF_SYNC_WRITE;
        need(ioctl(backing->dma,DMA_BUF_IOCTL_SYNC,&sync)==0,"source CPU write sync START");
        for(std::size_t i=0;i<(4ull<<20);++i)
            static_cast<unsigned char*>(backing->data)[i]=(i*37+(i>>8)+91+revision*17)&255;
        sync.flags=DMA_BUF_SYNC_END|DMA_BUF_SYNC_WRITE;
        need(ioctl(backing->dma,DMA_BUF_IOCTL_SYNC,&sync)==0,"source CPU write sync END");
    };
    for(unsigned revision=1;revision<=32;++revision){
        update(revision);submit(borrowed);validate(texture,1024,1024,revision);
    }
    need(upload.import_count()==1&&upload.cache_hits()==64,"dynamic source was reimported");
    std::puts("same inode/image dynamic revisions=32 alpha_changes=32 imports=1 stale_bytes=0 DMA_BUF_SYNC_WRITE=passed");
    update(0);
    // A distinct export of the same memfd gets its own dma-buf inode. Reuse the
    // borrowed integer FD while the original cached export remains alive.
    const int control=open("/dev/udmabuf",O_RDWR|O_CLOEXEC);need(control>=0,"cache export control");
    udmabuf_create req{};req.memfd=backing->mem;req.flags=UDMABUF_FLAGS_CLOEXEC;req.size=4ull<<20;
    int second=ioctl(control,UDMABUF_CREATE,&req);close(control);need(second>=0,"second export");
    need(dup2(second,borrowed)==borrowed,"reuse FD integer");submit(borrowed);need(upload.import_count()==2,"FD integer incorrectly reused old import");
    validate(texture,1024,1024);
    submit(borrowed,512,1024);need(upload.import_count()==3,"extent change reused incompatible import");
    // Exceed the bounded cache using different valid geometries of this export.
    for(unsigned h=128;h<=896;h+=128)submit(borrowed,512,h);
    need(upload.cache_size()==8,"cache not bounded");
    submit(backing->dma);validate(texture,1024,1024);
    std::printf("cache FD reuse/extent/eviction passed imports=%zu entries=%zu pending=%zu\n",upload.import_count(),upload.cache_size(),upload.pending());
    close(second);close(borrowed);glDeleteTextures(1,&texture);
}

}
int main(int argc,char** argv){try{
    const bool inherited=argc==6 && std::string_view(argv[1])=="--run-fd";
    need(inherited || (argc==3 && std::string_view(argv[1])=="--run"),"usage: --run <EGLindex> | --run-fd <EGLindex> <fd> <width> <height>");
    const auto index=num(argv[2]),w=inherited?num(argv[4]):1024,h=inherited?num(argv[5]):1024;
    const auto page=sysconf(_SC_PAGESIZE);need(index<32&&w&&h&&w<=16384&&h<=16384&&page>0,"dimensions");const auto bytes=w*h*4;need(bytes%page==0,"page alignment");
    auto backing=std::make_shared<Backing>();
    if(inherited){need(num(argv[3])<=INT_MAX,"fd range");backing->mem=fcntl(int(num(argv[3])),F_DUPFD_CLOEXEC,0);}
    else {backing->mem=syscall(SYS_memfd_create,"viewflow-raw-upload-test",MFD_CLOEXEC|MFD_ALLOW_SEALING);need(backing->mem>=0&&ftruncate(backing->mem,capacity)==0&&fcntl(backing->mem,F_ADD_SEALS,F_SEAL_SHRINK|F_SEAL_GROW)==0,"create memfd");}
    struct stat st{};need(backing->mem>=0&&fstat(backing->mem,&st)==0&&st.st_size==capacity,"memfd size");
    const int seals=fcntl(backing->mem,F_GET_SEALS);need(seals>=0&&(seals&(F_SEAL_SHRINK|F_SEAL_GROW))==(F_SEAL_SHRINK|F_SEAL_GROW)&&!(seals&F_SEAL_WRITE),"memfd seals");
    backing->data=mmap(nullptr,capacity,inherited?PROT_NONE:(PROT_READ|PROT_WRITE),MAP_SHARED,backing->mem,0);need(backing->data!=MAP_FAILED,"map residency");
    if(!inherited){madvise(backing->data,capacity,MADV_NOHUGEPAGE);for(std::size_t i=0;i<bytes;++i)static_cast<unsigned char*>(backing->data)[i]=(i*37+(i>>8)+91)&255;}
    const int control=open("/dev/udmabuf",O_RDWR|O_CLOEXEC);need(control>=0,"open udmabuf");udmabuf_create req{};req.memfd=backing->mem;req.flags=UDMABUF_FLAGS_CLOEXEC;req.size=bytes;backing->dma=ioctl(control,UDMABUF_CREATE,&req);close(control);need(backing->dma>=0,"export udmabuf");
    Context context;context.start(index);
    {
        GpuDecoder decoder;RawDmaBufUpload direct;GLuint direct_texture{};decoder.start(3);setenv("VIEWFLOW_RAW_DMABUF","1",1);
        auto slot=std::make_shared<int>(7);std::weak_ptr<int> lifetime=slot;
        auto pixels=std::make_shared<SharedPixels>();pixels->owner=slot;pixels->bytes={static_cast<std::uint8_t*>(backing->data),std::size_t(bytes)};pixels->storage_owner=backing;
        pixels->dma_buffer=std::make_shared<SharedDmaBuffer>(SharedDmaBuffer{backing->dma,0,std::uint32_t(w*4),backing});
        glEnable(GL_CULL_FACE);glCullFace(GL_FRONT_AND_BACK);glEnable(GL_SCISSOR_TEST);glScissor(0,0,0,0);glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);
        GLuint texture{};
        if(inherited){glGenTextures(1,&direct_texture);glBindTexture(GL_TEXTURE_2D,direct_texture);glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,w,h);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_SWIZZLE_R,GL_BLUE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_SWIZZLE_B,GL_RED);direct.upload(pixels,direct_texture,w,h);texture=direct_texture;}
        else {auto frame=decoder.raw_bgra(pixels,w,h,1);decoder.upload(frame);need(decoder.last_upload_raw_dma(),"decoder unexpectedly used fallback");texture=decoder.y_texture();}
        need(glIsEnabled(GL_CULL_FACE)&&glIsEnabled(GL_SCISSOR_TEST),"draw state not restored");GLboolean mask[4]{};glGetBooleanv(GL_COLOR_WRITEMASK,mask);need(!mask[0]&&!mask[1]&&!mask[2]&&!mask[3],"color mask not restored");
        pixels.reset();slot.reset();need(!lifetime.expired(),"slot released before fence poll");
        validate(texture,w,h);need((inherited?direct.poll():decoder.poll_raw_dma())==0,"completed fence not retired");need(lifetime.expired(),"slot retained after fence");
        if(direct_texture)glDeleteTextures(1,&direct_texture);
        std::puts("slot retained before poll and released after completed GL fence passed");
    }
    if(!inherited)cache_test(backing);
    std::vector<unsigned char> pages(capacity/page);need(mincore(backing->data,capacity,pages.data())==0,"residency");std::size_t total=0,tail=0;const auto allowed=inherited?((bytes+(64ull<<20)-1)/(64ull<<20))*(64ull<<20):bytes;
    for(std::size_t i=0;i<pages.size();++i)if(pages[i]&1){total+=page;if(i*page>=allowed)tail+=page;}
    std::printf("resident_total=%zu beyond_allowed=%zu image_bytes=%llu allowed_extent=%llu CPU_source_access=%s\n",total,tail,bytes,allowed,inherited?"none(PROT_NONE)":"own-pattern-write");need(!tail,"unexpected tail resident");return 0;
}catch(const std::exception& error){std::fprintf(stderr,"raw DMA-BUF candidate test failed: %s\n",error.what());return 1;}}

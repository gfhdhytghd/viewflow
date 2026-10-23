// Standalone opt-in udmabuf experiment. Linux UAPI headers retain their
// GPL-2.0 WITH Linux-syscall-note license. No desktop/input/focus operations.
#include <linux/udmabuf.h>
#include <linux/dma-buf.h>
#include <linux/memfd.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <charconv>
#include <cstdint>
#include <climits>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {
constexpr std::size_t capacity=1ull<<30, exported_bytes=4ull<<20;
constexpr unsigned width=1024, height=1024, pitch=width*4;
static_assert(std::size_t(pitch)*height==exported_bytes);
void require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
void system_require(bool ok,const char* message){if(!ok)throw std::runtime_error(std::string(message)+": "+std::strerror(errno));}
std::uint64_t number(std::string_view text){
    std::uint64_t n{};const auto result=std::from_chars(text.data(),text.data()+text.size(),n);
    require(result.ec==std::errc{} && result.ptr==text.data()+text.size(),"invalid decimal device index");return n;
}
bool extension(const char* list,std::string_view wanted){
    std::string_view s=list?list:"";
    while(!s.empty()){const auto n=s.find(' ');if(s.substr(0,n)==wanted)return true;if(n==s.npos)break;s.remove_prefix(n+1);}return false;
}
unsigned char pattern(std::size_t pixel,unsigned bgra_channel){
    const auto x=pixel%width,y=pixel/width;
    switch(bgra_channel){
    case 0:return static_cast<unsigned char>((x*13+y*7+19)&255);
    case 1:return static_cast<unsigned char>((x*3+y*23+71)&255);
    case 2:return static_cast<unsigned char>((x*29+y*5+137)&255);
    default:return static_cast<unsigned char>((x+y*11+43)&255);
    }
}
unsigned char windows_pattern(std::size_t pixel,unsigned bgra){
    const std::uint64_t i=std::uint64_t(pixel)*4+bgra;
    return static_cast<unsigned char>((i*37+(i>>8)+91)&255);
}
std::size_t image_bytes(std::uint64_t w,std::uint64_t h,std::size_t page){
    require(w && h && w<=16384 && h<=16384 && page,"invalid image dimensions/page size");
    const std::uint64_t bytes=w*h*4;
    require(bytes<=capacity && bytes%page==0,"image extent must fit 1GiB and be page aligned");
    return bytes;
}
std::size_t verify(const std::vector<unsigned char>& rgba,const char* scope,std::size_t bytes=exported_bytes,bool win=false){
    require(rgba.size()==bytes,"readback length mismatch");
    std::size_t mismatches=0,first=0;
    for(std::size_t pixel=0;pixel<bytes/4;++pixel)
        for(unsigned c=0;c<4;++c){const unsigned bgra=c==0?2:c==2?0:c;
            if(rgba[pixel*4+c]!=(win?windows_pattern(pixel,bgra):pattern(pixel,bgra))){if(!mismatches)first=pixel*4+c;++mismatches;}}
    std::printf("%s bytes=%zu mismatches=%zu first_mismatch=%zu\n",scope,rgba.size(),mismatches,first);return mismatches;
}
struct Fd{int value=-1;~Fd(){if(value>=0)close(value);}};
struct Mapping{void* ptr=MAP_FAILED;~Mapping(){if(ptr!=MAP_FAILED)munmap(ptr,capacity);}};
struct Egl {
    EGLDisplay display=EGL_NO_DISPLAY;EGLContext context=EGL_NO_CONTEXT;EGLSurface surface=EGL_NO_SURFACE;
    EGLImageKHR image=EGL_NO_IMAGE_KHR;PFNEGLDESTROYIMAGEKHRPROC destroy=nullptr;bool current=false;
    ~Egl(){
        if(display==EGL_NO_DISPLAY)return;
        if(current){glFinish();eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);}
        if(image!=EGL_NO_IMAGE_KHR && destroy)destroy(display,image);
        if(context!=EGL_NO_CONTEXT)eglDestroyContext(display,context);
        if(surface!=EGL_NO_SURFACE)eglDestroySurface(display,surface);
        eglTerminate(display);
    }
};
struct Gl {
    GLuint source{},target{},fbo{},vs{},fs{},program{},vao{};
    ~Gl(){
        glFinish();
        if(program)glDeleteProgram(program);
        if(vs)glDeleteShader(vs);
        if(fs)glDeleteShader(fs);
        if(vao)glDeleteVertexArrays(1,&vao);
        if(fbo)glDeleteFramebuffers(1,&fbo);
        if(source)glDeleteTextures(1,&source);
        if(target)glDeleteTextures(1,&target);
    }
};
void gl_check(const char* operation){const auto error=glGetError();if(error!=GL_NO_ERROR){char text[160];std::snprintf(text,sizeof(text),"%s GL error=0x%x",operation,error);throw std::runtime_error(text);}}
void sync(int fd,std::uint64_t flags){dma_buf_sync s{};s.flags=flags;int result;do{result=ioctl(fd,DMA_BUF_IOCTL_SYNC,&s);}while(result<0 && errno==EINTR);system_require(result==0,"DMA_BUF_IOCTL_SYNC");}
struct Residency{std::size_t prefix,slack,tail;};
Residency residency(void* ptr,std::size_t page,const char* stage,std::size_t bytes,std::size_t allowed){
    std::vector<unsigned char> pages(capacity/page);
    system_require(mincore(ptr,capacity,pages.data())==0,"mincore");
    std::size_t prefix=0,slack=0,tail=0;
    for(std::size_t i=0;i<pages.size();++i)if(pages[i]&1){if(i*page<bytes)++prefix;else if(i*page<allowed)++slack;else ++tail;}
    std::printf("resident stage=%s image_resident_bytes=%zu segment_slack_resident_bytes=%zu beyond_segments_resident_bytes=%zu capacity=%zu image_bytes=%zu allowed_segment_extent=%zu\n",stage,prefix*page,slack*page,tail*page,capacity,bytes,allowed);
    return {prefix*page,slack*page,tail*page};
}
GLuint shader(GLenum kind,const char* source){
    const GLuint result=glCreateShader(kind);require(result!=0,"glCreateShader");
    glShaderSource(result,1,&source,nullptr);glCompileShader(result);GLint ok=0;glGetShaderiv(result,GL_COMPILE_STATUS,&ok);
    if(!ok){char log[2048]{};glGetShaderInfoLog(result,sizeof(log),nullptr,log);glDeleteShader(result);throw std::runtime_error(std::string("shader compile: ")+log);}return result;
}
void self_test(){
    require(capacity==1073741824 && exported_bytes==4194304,"extent arithmetic");
    require(number("0")==0 && number("13")==13,"index parse");
    for(const char* bad:{"","-1","1x","18446744073709551616"}){bool rejected=false;try{number(bad);}catch(const std::exception&){rejected=true;}require(rejected,"invalid index accepted");}
    std::vector<unsigned char> rgba(exported_bytes);
    for(std::size_t p=0;p<rgba.size()/4;++p)for(unsigned c=0;c<4;++c)rgba[p*4+c]=pattern(p,c==0?2:c==2?0:c);
    require(verify(rgba,"CPU generated pattern") == 0,"pattern self-test");rgba[rgba.size()/2]^=1;require(verify(rgba,"CPU intentional corruption") == 1,"corruption not detected");
    require(image_bytes(6144,3456,4096)==84934656 && image_bytes(16384,16384,4096)==capacity,"dynamic dimensions");
    bool rejected=false;try{image_bytes(1,1,4096);}catch(const std::exception&){rejected=true;}require(rejected,"unaligned image accepted");
    require(windows_pattern(0,0)==91 && windows_pattern(0,1)==128 && windows_pattern(0,2)==165 && windows_pattern(0,3)==202 && windows_pattern(64,0)==92,"Windows pattern known values");
    for(std::size_t p=0;p<rgba.size()/4;++p)for(unsigned c=0;c<4;++c)rgba[p*4+c]=windows_pattern(p,c==0?2:c==2?0:c);
    require(verify(rgba,"CPU Windows pattern",rgba.size(),true)==0,"Windows pattern verification");
    rgba.back()^=1;require(verify(rgba,"CPU Windows corruption",rgba.size(),true)==1,"Windows corruption detection");
    std::puts("CPU self-test passed; no memfd/device/EGL/GPU activity");
}
bool gl_extension(std::string_view wanted){
    GLint count=0;glGetIntegerv(GL_NUM_EXTENSIONS,&count);
    for(GLint i=0;i<count;++i){const auto* value=glGetStringi(GL_EXTENSIONS,i);if(value && wanted==reinterpret_cast<const char*>(value))return true;}return false;
}
void import_capabilities(EGLDisplay display){
    const auto formats=reinterpret_cast<PFNEGLQUERYDMABUFFORMATSEXTPROC>(eglGetProcAddress("eglQueryDmaBufFormatsEXT"));
    const auto modifiers=reinterpret_cast<PFNEGLQUERYDMABUFMODIFIERSEXTPROC>(eglGetProcAddress("eglQueryDmaBufModifiersEXT"));
    if(!formats || !modifiers || !extension(eglQueryString(display,EGL_EXTENSIONS),"EGL_EXT_image_dma_buf_import_modifiers")){
        std::puts("DMA-BUF format/modifier query unavailable; external_only unknown");return;
    }
    EGLint count=0;
    if(!formats(display,0,nullptr,&count) || count<0 || count>65536){std::printf("DMA-BUF formats count query failed EGL=0x%x\n",eglGetError());return;}
    std::vector<EGLint> values(count);const EGLint allocated=count;
    if(!formats(display,allocated,values.data(),&count) || count<0 || count>allocated){std::printf("DMA-BUF formats query failed EGL=0x%x\n",eglGetError());return;}
    bool argb=false;for(EGLint i=0;i<count;++i)if(values[i]==DRM_FORMAT_ARGB8888)argb=true;
    std::printf("DMA-BUF format_count=%d ARGB8888_advertised=%u\n",count,unsigned(argb));
    count=0;
    if(!modifiers(display,DRM_FORMAT_ARGB8888,0,nullptr,nullptr,&count) || count<0 || count>65536){std::printf("ARGB8888 modifier count query failed EGL=0x%x\n",eglGetError());return;}
    std::vector<EGLuint64KHR> mods(count);std::vector<EGLBoolean> external(count);const EGLint mod_allocated=count;
    if(!modifiers(display,DRM_FORMAT_ARGB8888,mod_allocated,mods.data(),external.data(),&count) || count<0 || count>mod_allocated){std::printf("ARGB8888 modifier query failed EGL=0x%x\n",eglGetError());return;}
    unsigned linear=0;
    for(EGLint i=0;i<count;++i)if(mods[i]==DRM_FORMAT_MOD_LINEAR){++linear;std::printf("ARGB8888 LINEAR advertised=1 external_only=%u\n",unsigned(external[i]));}
    if(!linear)std::printf("ARGB8888 LINEAR advertised=0 modifier_count=%d; external_only unknown\n",count);
}
void run(std::uint64_t device_index,bool external_mode,int inherited_fd=-1,
         unsigned image_width=width,unsigned image_height=height){
    const bool inherited=inherited_fd>=0;
    const long ps=sysconf(_SC_PAGESIZE);require(ps>0 && capacity%ps==0,"unsupported host page size");
    const auto bytes=image_bytes(image_width,image_height,ps);
    constexpr std::size_t segment=64ull<<20;
    const auto allowed=inherited?((bytes+segment-1)/segment)*segment:bytes;
    const unsigned row_pitch=image_width*4;
    Fd memfd;
    if(inherited){
        memfd.value=fcntl(inherited_fd,F_DUPFD_CLOEXEC,0);system_require(memfd.value>=0,"duplicate inherited memfd");
        struct stat st{};system_require(fstat(memfd.value,&st)==0,"inherited memfd fstat");
        require(S_ISREG(st.st_mode) && st.st_size==static_cast<off_t>(capacity),"inherited memfd must be regular 1GiB backing");
        const int flags=fcntl(memfd.value,F_GETFL),seals=fcntl(memfd.value,F_GET_SEALS);
        require(flags>=0 && (flags&O_ACCMODE)==O_RDWR,"inherited memfd requires O_RDWR");
        require(seals>=0 && (seals&(F_SEAL_SHRINK|F_SEAL_GROW))==(F_SEAL_SHRINK|F_SEAL_GROW) && !(seals&F_SEAL_WRITE),"inherited memfd requires SHRINK/GROW seals and no WRITE seal");
        std::printf("source=inherited-fd image=%ux%u image_bytes=%zu segment_extent=%zu CPU_source_read=none CPU_source_write=none producer_completion=caller-precondition\n",image_width,image_height,bytes,allowed);
    }else{
        memfd.value=static_cast<int>(syscall(SYS_memfd_create,"viewflow-udmabuf-probe",MFD_CLOEXEC|MFD_ALLOW_SEALING));
        system_require(memfd.value>=0,"memfd_create");system_require(ftruncate(memfd.value,capacity)==0,"ftruncate 1GiB sparse capacity");
        system_require(fcntl(memfd.value,F_ADD_SEALS,F_SEAL_SHRINK|F_SEAL_GROW)==0,"seal memfd size");
    }
    Mapping memory;memory.ptr=mmap(nullptr,capacity,inherited?PROT_NONE:(PROT_READ|PROT_WRITE),MAP_SHARED,memfd.value,0);system_require(memory.ptr!=MAP_FAILED,"mmap memfd residency view");
    if(!inherited)system_require(madvise(memory.ptr,capacity,MADV_NOHUGEPAGE)==0,"MADV_NOHUGEPAGE");
    const auto before=residency(memory.ptr,ps,"before-export",bytes,allowed);
    Fd device;device.value=open("/dev/udmabuf",O_RDWR|O_CLOEXEC);system_require(device.value>=0,"open /dev/udmabuf");
    udmabuf_create request{};request.memfd=memfd.value;request.flags=UDMABUF_FLAGS_CLOEXEC;request.offset=0;request.size=bytes;
    Fd dma;dma.value=ioctl(device.value,UDMABUF_CREATE,&request);system_require(dma.value>=0,"UDMABUF_CREATE image prefix");
    std::printf("actual udmabuf export passed offset=0 size=%zu; EGL import still pending\n",bytes);
    if(!inherited){
        sync(dma.value,DMA_BUF_SYNC_START|DMA_BUF_SYNC_WRITE);
        auto* data=static_cast<unsigned char*>(memory.ptr);
        for(std::size_t p=0;p<bytes/4;++p)for(unsigned c=0;c<4;++c)data[p*4+c]=pattern(p,c);
        sync(dma.value,DMA_BUF_SYNC_END|DMA_BUF_SYNC_WRITE);
    }
    const auto after_fill=residency(memory.ptr,ps,inherited?"after-export-no-CPU-access":"after-export-fill",bytes,allowed);
    const auto query=reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
    const auto get_display=reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    require(query && get_display,"headless EGL device API unavailable");
    EGLint count=0;require(query(0,nullptr,&count) && count>0 && device_index<std::uint64_t(count),"EGL device unavailable");
    std::vector<EGLDeviceEXT> devices(count);require(query(count,devices.data(),&count) && device_index<std::uint64_t(count),"EGL inventory changed");
    Egl egl;egl.display=get_display(EGL_PLATFORM_DEVICE_EXT,devices[device_index],nullptr);
    require(egl.display!=EGL_NO_DISPLAY && eglInitialize(egl.display,nullptr,nullptr),"EGL initialize");
    require(eglBindAPI(EGL_OPENGL_ES_API),"EGL bind GLES");
    const EGLint ca[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config{};require(eglChooseConfig(egl.display,ca,&config,1,&count) && count,"EGL config");
    const EGLint sa[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE},va[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    egl.surface=eglCreatePbufferSurface(egl.display,config,sa);require(egl.surface!=EGL_NO_SURFACE,"EGL pbuffer");
    egl.context=eglCreateContext(egl.display,config,EGL_NO_CONTEXT,va);require(egl.context!=EGL_NO_CONTEXT,"EGL context");
    require(eglMakeCurrent(egl.display,egl.surface,egl.surface,egl.context),"EGL make current");egl.current=true;
    std::printf("EGL_device_index=%llu mode=%s EGL_vendor=%s GL_renderer=%s GL_version=%s\n",
        (unsigned long long)device_index,external_mode?"EXTERNAL_OES":"TEXTURE_2D",
        eglQueryString(egl.display,EGL_VENDOR),glGetString(GL_RENDERER),glGetString(GL_VERSION));
    import_capabilities(egl.display);
    const bool external_essl3=gl_extension("GL_OES_EGL_image_external_essl3");
    const bool external_base=gl_extension("GL_OES_EGL_image_external");
    std::printf("GL_external_OES=%u GL_external_ESSL3=%u GL_OES_EGL_image=%u\n",
        unsigned(external_base),unsigned(external_essl3),unsigned(gl_extension("GL_OES_EGL_image")));
    gl_check("extension diagnostics");
    if(external_mode)require(external_base && external_essl3,"external texture ESSL3 extensions unavailable");
    const char* exts=eglQueryString(egl.display,EGL_EXTENSIONS);require(extension(exts,"EGL_EXT_image_dma_buf_import"),"EGL DMA-BUF extension absent");
    const auto create=reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
    egl.destroy=reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
    const auto bind_image=reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    require(create && egl.destroy && bind_image,"EGL/GL image entry points unavailable");
    std::vector<EGLint> ia={EGL_WIDTH,static_cast<EGLint>(image_width),EGL_HEIGHT,static_cast<EGLint>(image_height),EGL_LINUX_DRM_FOURCC_EXT,DRM_FORMAT_ARGB8888,
        EGL_DMA_BUF_PLANE0_FD_EXT,dma.value,EGL_DMA_BUF_PLANE0_OFFSET_EXT,0,EGL_DMA_BUF_PLANE0_PITCH_EXT,static_cast<EGLint>(row_pitch)};
    if(extension(exts,"EGL_EXT_image_dma_buf_import_modifiers"))ia.insert(ia.end(),{EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,0,EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,0});
    ia.push_back(EGL_NONE);egl.image=create(egl.display,EGL_NO_CONTEXT,EGL_LINUX_DMA_BUF_EXT,nullptr,ia.data());
    if(egl.image==EGL_NO_IMAGE_KHR){char text[96];std::snprintf(text,sizeof(text),"actual EGL DMA-BUF import failed error=0x%x",eglGetError());throw std::runtime_error(text);}
    std::puts("actual EGL DMA-BUF import passed; sampling/readback still pending");
    const GLenum source_target=external_mode?GL_TEXTURE_EXTERNAL_OES:GL_TEXTURE_2D;
    Gl gl;glGenTextures(1,&gl.source);glBindTexture(source_target,gl.source);gl_check("create source texture");
    bind_image(source_target,egl.image);gl_check("glEGLImageTargetTexture2DOES");
    glTexParameteri(source_target,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(source_target,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glTexParameteri(source_target,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(source_target,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);gl_check("imported texture parameters");
    glGenTextures(1,&gl.target);glBindTexture(GL_TEXTURE_2D,gl.target);glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,image_width,image_height);
    glGenFramebuffers(1,&gl.fbo);glBindFramebuffer(GL_FRAMEBUFFER,gl.fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,gl.target,0);
    require(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE,"output framebuffer incomplete");
    gl.vs=shader(GL_VERTEX_SHADER,"#version 300 es\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.0-1.0,0.0,1.0);}");
    const char* fragment_2d="#version 300 es\nprecision highp float;precision highp int;uniform highp sampler2D image;out vec4 color;void main(){color=texelFetch(image,ivec2(gl_FragCoord.xy),0);}";
    const char* fragment_external="#version 300 es\n#extension GL_OES_EGL_image_external_essl3 : require\nprecision highp float;precision highp int;uniform highp samplerExternalOES image;uniform highp vec2 imageSize;out vec4 color;void main(){color=texture(image,gl_FragCoord.xy/imageSize);}";
    gl.fs=shader(GL_FRAGMENT_SHADER,external_mode?fragment_external:fragment_2d);
    gl.program=glCreateProgram();glAttachShader(gl.program,gl.vs);glAttachShader(gl.program,gl.fs);glLinkProgram(gl.program);
    GLint linked=0;glGetProgramiv(gl.program,GL_LINK_STATUS,&linked);require(linked,"shader link failed");glUseProgram(gl.program);
    glUniform1i(glGetUniformLocation(gl.program,"image"),0);
    if(external_mode){glUniform2f(glGetUniformLocation(gl.program,"imageSize"),image_width,image_height);}
    glActiveTexture(GL_TEXTURE0);glBindTexture(source_target,gl.source);
    glGenVertexArrays(1,&gl.vao);glBindVertexArray(gl.vao);glViewport(0,0,image_width,image_height);glDisable(GL_BLEND);glDisable(GL_DITHER);glDisable(GL_DEPTH_TEST);glDisable(GL_SCISSOR_TEST);
    glDrawArrays(GL_TRIANGLES,0,3);gl_check("sample imported DMA-BUF");
    std::vector<unsigned char> rgba(bytes);glPixelStorei(GL_PACK_ALIGNMENT,1);glReadPixels(0,0,image_width,image_height,GL_RGBA,GL_UNSIGNED_BYTE,rgba.data());glFinish();gl_check("readback");
    const auto wrong=verify(rgba,inherited?"GPU Windows-pattern RGBA readback":"GPU own-pattern RGBA readback",bytes,inherited);
    const auto after_gpu=residency(memory.ptr,ps,"after-GPU-readback",bytes,allowed);
    struct stat st{};system_require(fstat(memfd.value,&st)==0,"memfd fstat");
    std::printf("memfd capacity=%lld allocated_blocks_bytes=%llu seals=0x%x EGL_vendor=%s GL_renderer=%s\n",(long long)st.st_size,(unsigned long long)st.st_blocks*512,fcntl(memfd.value,F_GET_SEALS),eglQueryString(egl.display,EGL_VENDOR),glGetString(GL_RENDERER));
    require(wrong==0,"sampled pixels mismatch");
    require((inherited || before.prefix==0) && before.tail==0 && after_fill.prefix==bytes && after_fill.tail==0 && after_gpu.prefix==bytes && after_gpu.tail==0,"unexpected memfd image/tail residency");
    std::printf("PASS mode=%s source=%s image_bytes=%zu image_resident=%zu segment_slack_resident=%zu tail_resident=%zu: actual DMA-BUF import/draw/full-byte RGBA verification; producer identity/completion require caller evidence; NOT scanout or latency proof\n",external_mode?"EXTERNAL_OES":"TEXTURE_2D",inherited?"inherited-Windows-pattern":"own-4MiB-pattern",bytes,after_gpu.prefix,after_gpu.slack,after_gpu.tail);
}
}
int main(int argc,char** argv){try{
    if(argc==1 || (argc==2 && std::string_view(argv[1])=="--self-test")){self_test();return 0;}
    if(argc==3 && (std::string_view(argv[1])=="--run" || std::string_view(argv[1])=="--run-external")){run(number(argv[2]),std::string_view(argv[1])=="--run-external");return 0;}
    if(argc==6 && std::string_view(argv[1])=="--run-bgra-fd"){
        const auto fd=number(argv[3]),w=number(argv[4]),h=number(argv[5]);
        require(fd<=INT_MAX && w<=16384 && h<=16384,"inherited fd/dimensions out of range");
        run(number(argv[2]),true,static_cast<int>(fd),static_cast<unsigned>(w),static_cast<unsigned>(h));return 0;
    }
    std::fprintf(stderr,"usage: %s [--self-test] | <--run|--run-external> <explicit-EGL-device-index> | --run-bgra-fd <index> <inherited-fd> <width> <height>\nHardware modes initialize GPU and uses /dev/udmabuf; no desktop/input/focus operations.\n",argv[0]);return 2;
}catch(const std::exception& e){std::fprintf(stderr,"udmabuf probe failed: %s\n",e.what());return 1;}}

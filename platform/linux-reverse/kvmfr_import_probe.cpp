// Independent opt-in diagnostic. Includes the unmodified Looking Glass KVMFR
// UAPI supplied at build time (module/kvmfr.h, GPL-2.0-or-later, Looking Glass
// Authors). No Looking Glass implementation is copied here.
#include <kvmfr.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <drm_fourcc.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <charconv>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {
struct Layout { std::uint64_t offset{}, width{}, height{}, pitch{}, bytes{}; };
std::uint64_t number(std::string_view text) {
    std::uint64_t value{};
    const auto result=std::from_chars(text.data(),text.data()+text.size(),value);
    if(result.ec!=std::errc{} || result.ptr!=text.data()+text.size()) throw std::runtime_error("invalid decimal integer");
    return value;
}
Layout layout(std::uint64_t offset,std::uint64_t width,std::uint64_t height,std::uint64_t pitch,std::uint64_t page) {
    if(!page || (page&(page-1)) || offset%page) throw std::runtime_error("offset must be page aligned");
    if(!width || !height || width>16384 || height>16384 || pitch<width*4 || pitch%4 || pitch>std::uint64_t(std::numeric_limits<EGLint>::max()))
        throw std::runtime_error("invalid BGRA dimensions or pitch");
    const auto used=pitch*(height-1)+width*4;
    const auto bytes=(used+page-1)&~(page-1);
    if(offset>std::numeric_limits<std::uint64_t>::max()-bytes) throw std::runtime_error("export extent overflow");
    return {offset,width,height,pitch,bytes};
}
void bounds(const Layout& l,std::uint64_t capacity) {
    if(l.offset>capacity || l.bytes>capacity-l.offset) throw std::runtime_error("export exceeds KVMFR capacity");
}
bool extension(const char* list,std::string_view name) {
    std::string_view all=list?list:"";
    while(!all.empty()) {
        const auto end=all.find(' ');
        if(all.substr(0,end)==name)return true;
        if(end==all.npos)break;
        all.remove_prefix(end+1);
    }
    return false;
}
struct Fd { int value{-1}; ~Fd(){if(value>=0)close(value);} };
struct Display {
    EGLDisplay value{EGL_NO_DISPLAY};
    ~Display(){if(value!=EGL_NO_DISPLAY)eglTerminate(value);}
};
void self_test() {
    auto require=[](bool b){if(!b)throw std::runtime_error("CPU validation failed");};
    const auto six=layout(4096,6144,3456,24576,4096);
    require(six.bytes==84934656);bounds(six,six.offset+six.bytes);
    require(layout(0,1,1,4,4096).bytes==4096);
    require(layout(0,16384,16384,65536,4096).bytes==1073741824);
    auto rejected=[&](auto fn){bool failed=false;try{fn();}catch(const std::runtime_error&){failed=true;}require(failed);};
    rejected([&]{bounds(six,six.offset+six.bytes-1);});
    rejected([]{layout(1,1,1,4,4096);});
    rejected([]{layout(0,16385,1,65540,4096);});
    rejected([]{layout(0,10,10,39,4096);});
    rejected([]{layout(UINT64_MAX-4095,1,1,4,4096);});
    rejected([]{number("-1");});rejected([]{number("1x");});
    require(extension("EGL_A EGL_B","EGL_B") && !extension("EGL_AB","EGL_A"));
    std::puts("CPU argument/extent validation passed; no device opened, EGL initialized or import attempted");
}
}
int main(int argc,char** argv) {try {
    if(argc==2 && std::string_view(argv[1])=="--self-test"){self_test();return 0;}
    if(argc!=8 || std::string_view(argv[1])!="--run") {
        std::fprintf(stderr,"usage: %s --self-test | --run /dev/kvmfrN offset width height pitch egl-device-index\nExplicit --run performs GPU-driver import work; no windows/input/focus or pixel writes.\n",argv[0]);return 2;
    }
    const std::string_view device=argv[2];
    if(!device.starts_with("/dev/kvmfr") || device.size()==10 || device.substr(10).find_first_not_of("0123456789")!=device.npos)
        throw std::runtime_error("explicit /dev/kvmfrN required");
    const long page=sysconf(_SC_PAGESIZE);if(page<=0)throw std::runtime_error("page size unavailable");
    const auto l=layout(number(argv[3]),number(argv[4]),number(argv[5]),number(argv[6]),page);
    const auto device_index=number(argv[7]);
    Fd kvmfr;kvmfr.value=open(argv[2],O_RDWR|O_CLOEXEC|O_NOFOLLOW);
    if(kvmfr.value<0)throw std::runtime_error(std::string("open KVMFR: ")+std::strerror(errno));
    struct stat st{};if(fstat(kvmfr.value,&st) || !S_ISCHR(st.st_mode))throw std::runtime_error("KVMFR must be a character device");
    // The driver returns capacity as long, not through a pointer. libc ioctl
    // returns int, which would truncate a >= 2 GiB successful capacity result.
    const long capacity=syscall(SYS_ioctl,kvmfr.value,KVMFR_DMABUF_GETSIZE,0);
    if(capacity<=0)throw std::runtime_error("KVMFR GETSIZE failed or empty");
    bounds(l,static_cast<std::uint64_t>(capacity));
    kvmfr_dmabuf_create request{};
    request.flags=KVMFR_DMABUF_FLAG_CLOEXEC;request.offset=l.offset;request.size=l.bytes;
    Fd dma;const long exported=syscall(SYS_ioctl,kvmfr.value,KVMFR_DMABUF_CREATE,&request);
    if(exported<0 || exported>std::numeric_limits<int>::max())throw std::runtime_error(std::string("KVMFR export failed: ")+std::strerror(errno));
    dma.value=static_cast<int>(exported);
    std::printf("KVMFR export succeeded capacity=%ld offset=%llu bytes=%llu; EGL import not yet verified\n",capacity,(unsigned long long)l.offset,(unsigned long long)l.bytes);
    const auto query=reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
    const auto get_display=reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if(!query || !get_display)throw std::runtime_error("headless EGL device enumeration unavailable");
    EGLint count{};if(!query(0,nullptr,&count) || count<=0 || device_index>=static_cast<std::uint64_t>(count))throw std::runtime_error("EGL device index unavailable");
    std::vector<EGLDeviceEXT> devices(count);
    if(!query(count,devices.data(),&count) || device_index>=static_cast<std::uint64_t>(count))throw std::runtime_error("EGL device inventory changed");
    Display display;display.value=get_display(EGL_PLATFORM_DEVICE_EXT,devices[device_index],nullptr);
    if(display.value==EGL_NO_DISPLAY || !eglInitialize(display.value,nullptr,nullptr))throw std::runtime_error("headless EGL initialize failed");
    const char* extensions=eglQueryString(display.value,EGL_EXTENSIONS);
    if(!extension(extensions,"EGL_EXT_image_dma_buf_import"))throw std::runtime_error("EGL DMA-BUF import extension absent");
    const auto create=reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
    const auto destroy=reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
    if(!create || !destroy)throw std::runtime_error("EGL image functions unavailable");
    std::vector<EGLint> attrs={EGL_WIDTH,static_cast<EGLint>(l.width),EGL_HEIGHT,static_cast<EGLint>(l.height),
        EGL_LINUX_DRM_FOURCC_EXT,DRM_FORMAT_ARGB8888,EGL_DMA_BUF_PLANE0_FD_EXT,dma.value,
        EGL_DMA_BUF_PLANE0_OFFSET_EXT,0,EGL_DMA_BUF_PLANE0_PITCH_EXT,static_cast<EGLint>(l.pitch)};
    const bool modifiers=extension(extensions,"EGL_EXT_image_dma_buf_import_modifiers");
    if(modifiers)attrs.insert(attrs.end(),{EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,0,EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,0});
    attrs.push_back(EGL_NONE);
    const EGLImageKHR image=create(display.value,EGL_NO_CONTEXT,EGL_LINUX_DMA_BUF_EXT,nullptr,attrs.data());
    if(image==EGL_NO_IMAGE_KHR){char error[96];std::snprintf(error,sizeof(error),"actual EGL DMA-BUF import failed error=0x%x",eglGetError());throw std::runtime_error(error);}
    const bool released=destroy(display.value,image);
    if(!released)throw std::runtime_error("EGL image destruction failed");
    const char* vendor=eglQueryString(display.value,EGL_VENDOR);
    std::printf("actual EGL DMA-BUF import and release passed device_index=%llu vendor=%s linear_modifier=%u; pixel integrity, GPU sampling, synchronization, scanout and latency NOT tested\n",
        (unsigned long long)device_index,vendor?vendor:"unknown",unsigned(modifiers));
    return 0;
} catch(const std::exception& error){std::fprintf(stderr,"KVMFR probe failed: %s\n",error.what());return 1;}}

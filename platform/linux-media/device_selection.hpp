#pragma once
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <vector>
#include <unistd.h>
#include <sys/sysmacros.h>
#include <dlfcn.h>
#include <string>
#include <stdexcept>
#include <sys/stat.h>

namespace viewflow::media {
struct Selection { bool vaapi; std::string renderNode; };
inline std::string currentRenderNode() {
    auto queryDisplay = reinterpret_cast<PFNEGLQUERYDISPLAYATTRIBEXTPROC>(eglGetProcAddress("eglQueryDisplayAttribEXT"));
    auto queryDevice = reinterpret_cast<PFNEGLQUERYDEVICESTRINGEXTPROC>(eglGetProcAddress("eglQueryDeviceStringEXT"));
    EGLAttrib device{};
    if (queryDisplay && queryDevice && eglGetCurrentDisplay()!=EGL_NO_DISPLAY &&
        queryDisplay(eglGetCurrentDisplay(), EGL_DEVICE_EXT, &device)) {
        const char* node=queryDevice(reinterpret_cast<EGLDeviceEXT>(device), EGL_DRM_RENDER_NODE_FILE_EXT);
        if(node) return node;
    }
    return {};
}
inline bool sameDevice(const std::string& a, const std::string& b) {
    struct stat x{}, y{};
    return !stat(a.c_str(), &x) && !stat(b.c_str(), &y) && S_ISCHR(x.st_mode) &&
           S_ISCHR(y.st_mode) && x.st_rdev==y.st_rdev;
}
// No ordinal/brand fallback for an explicitly selected device.
inline Selection selection(bool requireCurrentNvidia=true) {
    const char* value=std::getenv("VIEWFLOW_MEDIA_BACKEND");
    const std::string backend=value && *value?value:"auto";
    if(backend!="auto" && backend!="nvidia" && backend!="vaapi")
        throw std::runtime_error("VIEWFLOW_MEDIA_BACKEND must be auto, nvidia or vaapi");
    const char* requested=std::getenv("VIEWFLOW_MEDIA_RENDER_NODE");
    std::string node=requested && *requested?requested:currentRenderNode();
    if(node.empty() && eglGetCurrentContext()==EGL_NO_CONTEXT) {
        std::vector<std::string> nodes;
        std::error_code ec;
        for(const auto& item:std::filesystem::directory_iterator("/dev/dri",ec))
            if(item.path().filename().string().rfind("renderD",0)==0 && !access(item.path().c_str(),R_OK|W_OK))
                nodes.push_back(item.path().string());
        if(nodes.size()==1) node=nodes.front();
        else if(nodes.size()>1) throw std::runtime_error("multiple media render devices; set VIEWFLOW_MEDIA_RENDER_NODE explicitly");
    }
    if(!node.empty()) {
        struct stat info{};
        if(stat(node.c_str(), &info) || !S_ISCHR(info.st_mode) || major(info.st_rdev)!=226 || minor(info.st_rdev)<128)
            throw std::runtime_error("media render device is not an accessible character device: "+node);
    }
    const char* vendor=eglGetCurrentContext()==EGL_NO_CONTEXT?nullptr:reinterpret_cast<const char*>(glGetString(GL_VENDOR));
    std::string pciVendor;
    if(!node.empty()) {
        struct stat info{};
        if(!stat(node.c_str(),&info)) {
            std::ifstream file("/sys/dev/char/"+std::to_string(major(info.st_rdev))+":"+std::to_string(minor(info.st_rdev))+"/device/vendor");
            file>>pciVendor;
        }
    }
    const bool nvidia=!pciVendor.empty()?pciVendor=="0x10de":vendor && std::string(vendor).find("NVIDIA")!=std::string::npos;
    bool vaapi=backend=="vaapi" || (backend=="auto" && !nvidia);
    if(vaapi && node.empty()) throw std::runtime_error("VA-API needs an explicit VIEWFLOW_MEDIA_RENDER_NODE or an EGL render node");
    if(requireCurrentNvidia && !vaapi && requested && *requested && eglGetCurrentContext()!=EGL_NO_CONTEXT && !sameDevice(node,currentRenderNode()))
        throw std::runtime_error("selected NVIDIA media device does not match the current EGL renderer");
    return {vaapi,node};
}
inline int nvidiaOrdinal(const std::string& node) {
    if(node.empty()) return 0;
    struct stat info{};
    if(stat(node.c_str(),&info)) throw std::runtime_error("cannot stat NVIDIA render device");
    const auto pci=std::filesystem::canonical("/sys/dev/char/"+std::to_string(major(info.st_rdev))+":"+
        std::to_string(minor(info.st_rdev))+"/device").filename().string();
    static void* module=dlopen("libcuda.so.1",RTLD_NOW|RTLD_LOCAL);
    if(!module) throw std::runtime_error("selected NVIDIA encoder requires libcuda.so.1");
    auto init=reinterpret_cast<int (*)(unsigned)>(dlsym(module,"cuInit"));
    auto get=reinterpret_cast<int (*)(int*,const char*)>(dlsym(module,"cuDeviceGetByPCIBusId"));
    int ordinal=-1;
    if(!init || !get || init(0) || get(&ordinal,pci.c_str()))
        throw std::runtime_error("selected render node has no CUDA device: "+node);
    return ordinal;
}

}

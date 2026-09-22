#pragma once
#include "device_selection.hpp"
namespace viewflow::media {
// A private surfaceless/device context. EGLDisplay itself is process-shared.
class EglDevice {
    EGLDisplay display_=EGL_NO_DISPLAY;
    EGLContext context_=EGL_NO_CONTEXT;
    EGLSurface surface_=EGL_NO_SURFACE;
public:
    explicit EglDevice(const std::string& node) {
        try {
            auto query=reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
            auto get=reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
            auto name=reinterpret_cast<PFNEGLQUERYDEVICESTRINGEXTPROC>(eglGetProcAddress("eglQueryDeviceStringEXT"));
            EGLint count{};
            if(!query || !get || !name || !query(0,nullptr,&count) || count<=0)
                throw std::runtime_error("EGL device enumeration unavailable");
            std::vector<EGLDeviceEXT> devices(count);
            if(!query(count,devices.data(),&count)) throw std::runtime_error("EGL device enumeration failed");
            for(int i=0;i<count;++i) {
                const char* path=name(devices[i],EGL_DRM_RENDER_NODE_FILE_EXT);
                if(path && sameDevice(path,node)) { display_=get(EGL_PLATFORM_DEVICE_EXT,devices[i],nullptr);break; }
            }
            if(display_==EGL_NO_DISPLAY || !eglInitialize(display_,nullptr,nullptr) || !eglBindAPI(EGL_OPENGL_ES_API))
                throw std::runtime_error("cannot initialize EGL on selected render node: "+node);
            const EGLint attrs[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,EGL_NONE};
            EGLConfig config{};
            if(!eglChooseConfig(display_,attrs,&config,1,&count) || count!=1) throw std::runtime_error("EGL ES3 configuration unavailable");
            const EGLint size[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE}, version[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
            surface_=eglCreatePbufferSurface(display_,config,size);
            context_=eglCreateContext(display_,config,EGL_NO_CONTEXT,version);
            makeCurrent();
        } catch(...) { release();throw; }
    }
    EglDevice(const EglDevice&)=delete;
    EglDevice& operator=(const EglDevice&)=delete;
    ~EglDevice(){ release(); }
    void makeCurrent() {
        if(context_==EGL_NO_CONTEXT || surface_==EGL_NO_SURFACE || !eglMakeCurrent(display_,surface_,surface_,context_))
            throw std::runtime_error("cannot make selected media EGL context current");
    }
    EGLDisplay display()const{return display_;}
private:
    void release() noexcept {
        if(display_!=EGL_NO_DISPLAY) {
            if(eglGetCurrentContext()==context_) eglMakeCurrent(display_,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
            if(context_!=EGL_NO_CONTEXT) eglDestroyContext(display_,context_);
            if(surface_!=EGL_NO_SURFACE) eglDestroySurface(display_,surface_);
        }
    }
};
}

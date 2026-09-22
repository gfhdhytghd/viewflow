#include "portable_dmabuf_import.hpp"
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
namespace viewflow::gpu {
namespace {
struct Import {
    EGLDisplay display;
    EGLImageKHR image=EGL_NO_IMAGE_KHR;
    GLuint texture{},framebuffer{};
    PFNEGLDESTROYIMAGEKHRPROC destroy;
    explicit Import(EGLDisplay d):display(d),destroy(reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"))) {}
    ~Import() {
        // Even an error must finish all reads before the producer lease returns.
        glFinish();
        if(framebuffer) glDeleteFramebuffers(1,&framebuffer);
        if(texture) glDeleteTextures(1,&texture);
        if(image!=EGL_NO_IMAGE_KHR && destroy) destroy(display,image);
    }
};
} // namespace

CpuTile readPortableDmabuf(EGLDisplay display,const DmabufAtlasTile& tile) {
    const auto& f=tile.frame;
    auto create=reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
    auto bind=reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    Import imported(display);
    if(!create || !bind || !imported.destroy) throw std::runtime_error("EGL DMA-BUF import unavailable");
    std::vector<EGLint> attrs={EGL_WIDTH,int(f.imageWidth),EGL_HEIGHT,int(f.imageHeight),EGL_LINUX_DRM_FOURCC_EXT,int(f.fourcc),
        EGL_DMA_BUF_PLANE0_FD_EXT,f.dmaBufFd,EGL_DMA_BUF_PLANE0_OFFSET_EXT,int(f.offset),EGL_DMA_BUF_PLANE0_PITCH_EXT,int(f.stride)};
    if(f.modifier!=DRM_FORMAT_MOD_INVALID) attrs.insert(attrs.end(),{
        EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,int(f.modifier),EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,int(f.modifier>>32)});
    attrs.push_back(EGL_NONE);
    imported.image=create(display,EGL_NO_CONTEXT,EGL_LINUX_DMA_BUF_EXT,nullptr,attrs.data());
    if(imported.image==EGL_NO_IMAGE_KHR) throw std::runtime_error("capture DMA-BUF import failed on selected media render node");
    glGenTextures(1,&imported.texture);glBindTexture(GL_TEXTURE_2D,imported.texture);bind(GL_TEXTURE_2D,imported.image);
    glGenFramebuffers(1,&imported.framebuffer);glBindFramebuffer(GL_FRAMEBUFFER,imported.framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,imported.texture,0);
    if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE) throw std::runtime_error("captured DMA-BUF cannot be read by EGL");
    std::vector<unsigned char> pixels(size_t(f.cropWidth)*f.cropHeight*4);
    glPixelStorei(GL_PACK_ALIGNMENT,1);
    glReadPixels(f.cropX,f.cropY,f.cropWidth,f.cropHeight,GL_RGBA,GL_UNSIGNED_BYTE,pixels.data());
    if(glGetError()!=GL_NO_ERROR) throw std::runtime_error("DMA-BUF RGBA readback failed");
    return prepareCpuTile(pixels,tile);
}
}

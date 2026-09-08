// SPDX-License-Identifier: GPL-3.0-only
// Derived from HyprCapture caa7657c5f13b5828f984357f7686c98375f2949; see ../NOTICE.
#include "window_gpu_export.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <array>
#include <fcntl.h>
#include <string_view>
#include <unistd.h>
#include <utility>

namespace viewflow_capture {
namespace {
bool extension(std::string_view list, std::string_view name) {
    size_t offset = 0;
    while (offset < list.size()) {
        const size_t end = list.find(' ', offset);
        const auto item = list.substr(offset, end == std::string_view::npos ? end : end - offset);
        if (item == name) return true;
        if (end == std::string_view::npos) break;
        offset = end + 1;
    }
    return false;
}
struct Functions {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    PFNEGLCREATEIMAGEKHRPROC createImage = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC destroyImage = nullptr;
    PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC query = nullptr;
    PFNEGLEXPORTDMABUFIMAGEMESAPROC exportImage = nullptr;
    PFNEGLCREATESYNCKHRPROC createSync = nullptr;
    PFNEGLDESTROYSYNCKHRPROC destroySync = nullptr;
    PFNEGLDUPNATIVEFENCEFDANDROIDPROC duplicateFence = nullptr;
    bool available = false;

    bool load(EGLDisplay d, EGLContext c) {
        display = d;
        context = c;
        const char* raw = eglQueryString(display, EGL_EXTENSIONS);
        if (!raw || !extension(raw, "EGL_KHR_image_base") || !extension(raw, "EGL_MESA_image_dma_buf_export") ||
            !extension(raw, "EGL_ANDROID_native_fence_sync"))
            return available = false;
        createImage = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
        destroyImage = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
        query = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC>(eglGetProcAddress("eglExportDMABUFImageQueryMESA"));
        exportImage = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEMESAPROC>(eglGetProcAddress("eglExportDMABUFImageMESA"));
        createSync = reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(eglGetProcAddress("eglCreateSyncKHR"));
        destroySync = reinterpret_cast<PFNEGLDESTROYSYNCKHRPROC>(eglGetProcAddress("eglDestroySyncKHR"));
        duplicateFence = reinterpret_cast<PFNEGLDUPNATIVEFENCEFDANDROIDPROC>(eglGetProcAddress("eglDupNativeFenceFDANDROID"));
        return available = createImage && destroyImage && query && exportImage && createSync && destroySync && duplicateFence;
    }
};
}

struct WindowGpuExportCache::Impl {
    Functions functions;
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    int imageFd = -1;
    GLuint framebuffer = 0, texture = 0;
    GLint width = 0, height = 0, internalFormat = 0;
    std::uint32_t fourcc = 0, stride = 0;
    std::uint64_t offset = 0, modifier = 0, builds = 0, queries = 0;

    ~Impl() { reset(); }
    void reset() {
        if (image != EGL_NO_IMAGE_KHR) functions.destroyImage(functions.display, image);
        if (imageFd >= 0) close(imageFd);
        image = EGL_NO_IMAGE_KHR;
        imageFd = -1;
        framebuffer = texture = 0;
    }
};

WindowGpuExportCache::WindowGpuExportCache() : m_impl(std::make_unique<Impl>()) {}
WindowGpuExportCache::~WindowGpuExportCache() = default;
void WindowGpuExportCache::reset() { m_impl->reset(); }
std::uint64_t WindowGpuExportCache::imageBuilds() const { return m_impl->builds; }
std::uint64_t WindowGpuExportCache::capabilityQueries() const { return m_impl->queries; }

std::optional<WindowGpuPacket> WindowGpuExportCache::exportFrame(unsigned int framebuffer, gpuwire::Frame metadata) {
    auto& cache = *m_impl;
    auto& fn = cache.functions;
    const auto display = eglGetCurrentDisplay();
    const auto context = eglGetCurrentContext();
    if (!framebuffer || display == EGL_NO_DISPLAY || context == EGL_NO_CONTEXT) return std::nullopt;
    if (fn.display != display || fn.context != context) {
        cache.reset();
        ++cache.queries;
        fn.load(display, context);
    }
    if (!fn.available) return std::nullopt;

    GLint previous = 0, type = 0, name = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previous);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer);
    const bool complete = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
    glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &name);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(previous));
    if (!complete || type != GL_TEXTURE || name <= 0 || glGetError() != GL_NO_ERROR) return std::nullopt;

    GLint oldTexture = 0, width = 0, height = 0, internalFormat = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &oldTexture);
    glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(name));
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &width);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &height);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTERNAL_FORMAT, &internalFormat);
    glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(oldTexture));
    if (width <= 0 || height <= 0 || glGetError() != GL_NO_ERROR) return std::nullopt;

    if (cache.image == EGL_NO_IMAGE_KHR || cache.framebuffer != framebuffer || cache.texture != static_cast<GLuint>(name) ||
        cache.width != width || cache.height != height || cache.internalFormat != internalFormat) {
        cache.reset();
        constexpr EGLint preserve[]{EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
        cache.image = fn.createImage(display, context, EGL_GL_TEXTURE_2D_KHR,
                                    reinterpret_cast<EGLClientBuffer>(static_cast<uintptr_t>(name)), preserve);
        if (cache.image == EGL_NO_IMAGE_KHR) return std::nullopt;
        int fourcc = 0, planes = 0;
        std::array<EGLuint64KHR, 4> modifiers{};
        std::array<EGLint, 4> strides{}, offsets{};
        std::array<int, 4> descriptors{-1, -1, -1, -1};
        const bool exported = fn.query(display, cache.image, &fourcc, &planes, modifiers.data()) == EGL_TRUE && planes == 1 &&
            fn.exportImage(display, cache.image, descriptors.data(), strides.data(), offsets.data()) == EGL_TRUE;
        const bool valid = exported && descriptors[0] >= 0 && strides[0] > 0 && offsets[0] >= 0 &&
            static_cast<std::uint32_t>(fourcc) == gpuwire::HCGF_ABGR8888 && fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0;
        if (valid) cache.imageFd = std::exchange(descriptors[0], -1);
        for (int fd : descriptors) if (fd >= 0) close(fd);
        if (!valid) { cache.reset(); return std::nullopt; }
        cache.framebuffer = framebuffer;
        cache.texture = static_cast<GLuint>(name);
        cache.width = width;
        cache.height = height;
        cache.internalFormat = internalFormat;
        cache.fourcc = static_cast<std::uint32_t>(fourcc);
        cache.stride = static_cast<std::uint32_t>(strides[0]);
        cache.offset = static_cast<std::uint64_t>(offsets[0]);
        cache.modifier = modifiers[0];
        ++cache.builds;
    }
    metadata.imageWidth = static_cast<std::uint32_t>(width);
    metadata.imageHeight = static_cast<std::uint32_t>(height);
    metadata.fourcc = cache.fourcc;
    metadata.stride = cache.stride;
    metadata.offset = cache.offset;
    metadata.modifier = cache.modifier;
    WindowGpuPacket packet;
    if (!gpuwire::encode(metadata, packet.header)) return std::nullopt;
    // Each packet owns a duplicate; a failed send cannot invalidate the cache.
    packet.imageFd = fcntl(cache.imageFd, F_DUPFD_CLOEXEC, 0);
    if (packet.imageFd < 0) return std::nullopt;
    const auto sync = fn.createSync(display, EGL_SYNC_NATIVE_FENCE_ANDROID, nullptr);
    if (sync == EGL_NO_SYNC_KHR) return std::nullopt;
    glFlush();
    packet.fenceFd = fn.duplicateFence(display, sync);
    fn.destroySync(display, sync);
    if (packet.fenceFd < 0 || fcntl(packet.fenceFd, F_SETFD, FD_CLOEXEC) != 0) return std::nullopt;
    return packet;
}

std::optional<WindowGpuPacket> exportWindowGpuFrame(unsigned int framebuffer, gpuwire::Frame metadata) {
    WindowGpuExportCache cache;
    auto packet = cache.exportFrame(framebuffer, metadata);
    return packet;
}
}

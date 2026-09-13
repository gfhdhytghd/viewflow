// SPDX-License-Identifier: GPL-3.0-only
#include "popup_backdrop.hpp"
#include "../../reverse-common/backdrop_shm.hpp"
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/plugins/HookSystem.hpp>
#include <hyprland/src/render/pass/SurfacePassElement.hpp>
#include <functional>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>
#include <GLES3/gl3.h>
#include <filesystem>
#include <chrono>
#include <map>
#include <cstring>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <cerrno>

namespace viewflow::hyprland {
namespace {
namespace vf = viewflow::reverse;
using Clock = std::chrono::steady_clock;
struct Capture {
    int fd{-1};
    vf::BackdropShm* memory{};
    PHLWINDOWREF window;
    SP<Render::IFramebuffer> framebuffer;
    SP<Render::IFramebuffer> downsample;
    GLuint pbo{};
    GLsync fence{};
    uint32_t width{}, height{};
    int32_t x{}, y{}, logical_width{}, logical_height{}, window_x{}, window_y{};
    Clock::time_point next{};
    bool dead{};
    ~Capture() {
        if (pbo || fence) { Render::GL::g_pHyprOpenGL->makeEGLCurrent(); release_gpu(); }
        if (memory) munmap(memory, vf::backdrop_shm_size);
        if (fd >= 0) close(fd);
    }
    void release_gpu() {
        if (fence) glDeleteSync(fence);
        if (pbo) glDeleteBuffers(1, &pbo);
        fence = nullptr; pbo = 0;
    }
    void draw(const PHLMONITOR& monitor) {
        if (dead) { release_gpu(); return; }
        const auto target = window.lock();
        if (!target || !target->m_isMapped || !memory || monitor->m_transform != WL_OUTPUT_TRANSFORM_NORMAL) return;
        GLint previous = 0; glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &previous);
        if (fence) {
            const auto ready = glClientWaitSync(fence, 0, 0);
            if (ready == GL_WAIT_FAILED) { release_gpu(); return; }
            if (ready != GL_ALREADY_SIGNALED && ready != GL_CONDITION_SATISFIED) return;
            glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo);
            auto* pixels = static_cast<const unsigned char*>(glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, static_cast<GLsizeiptr>(width) * height * 4, GL_MAP_READ_BIT));
            if (pixels) {
                memory->sequence.fetch_add(1, std::memory_order_acq_rel);
                memory->width = width; memory->height = height; memory->x = x; memory->y = y;
                memory->logical_width = logical_width; memory->logical_height = logical_height;
                memory->window_x = window_x; memory->window_y = window_y;
                memory->timestamp_ns = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count());
                auto* out = reinterpret_cast<unsigned char*>(memory + 1);
                for (uint32_t row = 0; row < height; ++row)
                    std::memcpy(out + static_cast<size_t>(row) * width * 4, pixels + static_cast<size_t>(row) * width * 4, static_cast<size_t>(width) * 4);
                glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
                memory->sequence.fetch_add(1, std::memory_order_release);
            }
            glDeleteSync(fence); fence = nullptr;
            glBindBuffer(GL_PIXEL_PACK_BUFFER, static_cast<GLuint>(previous));
        }
        if (Clock::now() < next) return;
        const auto now = Clock::now();
        const auto period = std::chrono::microseconds(66667);
        next = next == Clock::time_point{} || now - next >= period ? now + period : next + period;
        const auto position = target->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
        
        const double scale = monitor->m_scale;
        const int left = 0, top = 0;
        const int right = static_cast<int>(monitor->m_pixelSize.x);
        const int bottom = static_cast<int>(monitor->m_pixelSize.y);
        if (right <= 0 || bottom <= 0 || right > 8192 || bottom > 8192 ||
            uint64_t(right) * static_cast<uint64_t>(bottom) * 4 > vf::backdrop_shm_pixels) return;
        width = static_cast<uint32_t>((right + 1) / 2); height = static_cast<uint32_t>((bottom + 1) / 2);
        x = static_cast<int32_t>(std::lround((monitor->m_position.x + left / scale) * 1000));
        y = static_cast<int32_t>(std::lround((monitor->m_position.y + top / scale) * 1000));
        logical_width = static_cast<int32_t>(std::lround(right / scale * 1000));
        logical_height = static_cast<int32_t>(std::lround(bottom / scale * 1000));
        window_x = static_cast<int32_t>(std::lround(position.x * 1000));
        window_y = static_cast<int32_t>(std::lround(position.y * 1000));
        if (!pbo) glGenBuffers(1, &pbo);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo);
        glBufferData(GL_PIXEL_PACK_BUFFER, static_cast<GLsizeiptr>(width) * height * 4, nullptr, GL_STREAM_READ);
        GLint alignment = 0, row_length = 0; glGetIntegerv(GL_PACK_ALIGNMENT, &alignment); glGetIntegerv(GL_PACK_ROW_LENGTH, &row_length);
        glPixelStorei(GL_PACK_ALIGNMENT, 1); glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        // Hyprland's intermediate framebuffer uses a flipped projection: its
        // low GL rows correspond to the top of the monitor. Read the same ROI
        // as the surface coordinates and preserve its row order for the PNG.
        // Hyprland binds its pass target as DRAW only. READ may still refer to
        // the completed previous frame, which contains the popup itself.
        GLint read_fb = 0, draw_fb = 0;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fb);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_fb);
        if (!downsample) downsample = g_pHyprRenderer->createFB("Viewflow half-resolution desktop");
        if (!downsample->alloc(static_cast<int>(width), static_cast<int>(height), DRM_FORMAT_ABGR8888)) {
            glPixelStorei(GL_PACK_ALIGNMENT, alignment); glPixelStorei(GL_PACK_ROW_LENGTH, row_length);
            glBindBuffer(GL_PIXEL_PACK_BUFFER, static_cast<GLuint>(previous));
            return;
        }
        downsample->bind();
        glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(draw_fb));
        glBlitFramebuffer(0, 0, right, bottom, 0, 0, static_cast<GLint>(width), static_cast<GLint>(height), GL_COLOR_BUFFER_BIT, GL_LINEAR);
        GLint scaled_fb = 0; glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &scaled_fb);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(scaled_fb));
        glReadPixels(left, top, static_cast<GLsizei>(width), static_cast<GLsizei>(height), GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(read_fb));
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, static_cast<GLuint>(draw_fb));
        fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        glPixelStorei(GL_PACK_ALIGNMENT, alignment); glPixelStorei(GL_PACK_ROW_LENGTH, row_length);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, static_cast<GLuint>(previous));
    }
};
// This predicate only affects the separate desktop render. It never changes
// the real window visibility, stacking, focus, or output framebuffer.
bool drawing_desktop = false;
CFunctionHook* pass_hook = nullptr;
void add_pass(Render::CRenderPass* pass, UP<IPassElement>&& element) {
    if (drawing_desktop && element && element->type() == EK_SURFACE) {
        // Cached monitor blur contains Mac proxies. Blur this render's own
        // background instead so no previous Mac image can feed back into it.
        static_cast<CSurfacePassElement*>(element.get())->m_data.blockBlurOptimization = true;
    }
    using Original = void(*)(Render::CRenderPass*, UP<IPassElement>&&);
    reinterpret_cast<Original>(pass_hook->m_original)(pass, std::move(element));
}
struct RendererAccess : Render::IHyprRenderer {
    using Render::IHyprRenderer::renderBackground;
    using Render::IHyprRenderer::renderLayer;
    using Render::IHyprRenderer::renderWindow;
};
void render_desktop(const std::shared_ptr<Capture>& capture, PHLMONITOR monitor) {
    auto& renderer = *g_pHyprRenderer;
    if (drawing_desktop || renderer.m_renderData.pMonitor || monitor->m_transform != WL_OUTPUT_TRANSFORM_NORMAL) return;
    if (capture->fence && Clock::now() < capture->next) {capture->draw(monitor); return;}
    if (!capture->framebuffer || capture->framebuffer->m_size != monitor->m_pixelSize) {
        capture->framebuffer = renderer.createFB("Viewflow Linux desktop background");
        capture->framebuffer->addStencil(renderer.createStencilTexture(static_cast<int>(monitor->m_pixelSize.x), static_cast<int>(monitor->m_pixelSize.y)));
    }
    if (!capture->framebuffer->alloc(static_cast<int>(monitor->m_pixelSize.x),
                                    static_cast<int>(monitor->m_pixelSize.y), DRM_FORMAT_ABGR8888)) return;
    capture->framebuffer->setImageDescription(monitor->workBufferImageDescription());
    CRegion damage{CBox{{}, monitor->m_transformedSize}};
    if (!renderer.beginFullFakeRender(monitor, damage, capture->framebuffer)) return;
    drawing_desktop = true;
    renderer.draw(CClearPassElement::SClearData{CHyprColor(0, 0, 0, 1)});
    renderer.startRenderPass();
    const auto now = Time::steadyNow();
    (renderer.*&RendererAccess::renderBackground)(monitor);
    auto layers = [&](size_t layer) {
        for (const auto& weak : monitor->m_layerSurfaceLayers[layer])
            if (auto surface = weak.lock())
                (renderer.*&RendererAccess::renderLayer)(surface, monitor, now, false, false);
    };
    layers(0); layers(1);
    // The compositor window order is bottom to top within each plane.
    // Rebuild all visible Linux windows, including content behind Mac proxies.
    for (int plane = 0; plane < 3; ++plane) {
        for (const auto& window : Desktop::windowState()->windows()) {
            if (!window->m_isMapped || window->isHidden() || window->m_class.starts_with("ViewflowReverse-") ||
                !renderer.shouldRenderWindow(window, monitor)) continue;
            const int window_plane = window->m_pinned ? 2 : (window->m_isFloating ? 1 : 0);
            if (window_plane != plane) continue;
            (renderer.*&RendererAccess::renderWindow)(window, monitor, now, true, Render::RENDER_PASS_ALL, false, false);
        }
    }
    layers(2); layers(3);
    // Complete the offscreen pass, then read its framebuffer. No normal
    // monitor render is interrupted and occlusion is computed without Mac.
    renderer.endRender();
    drawing_desktop = false;
    capture->framebuffer->bind();
    capture->draw(monitor);
    glFlush();
    renderer.m_renderPass.clear();
}

}
struct PopupBackdrops::Impl {
    void* handle;
    SP<CEventLoopTimer> timer;
    struct Entry {std::shared_ptr<Capture> capture;};
    std::map<std::string,Entry> entries;
    Clock::time_point scan_at{};
    explicit Impl(void* h):handle(h) {
        std::filesystem::create_directories(vf::backdrop_directory());
        auto hook = [this](const std::string& symbol, const void* callback) {
            CFunctionHook* result = nullptr;
            for (const auto& match : HyprlandAPI::findFunctionsByName(handle, symbol))
                if (match.signature == symbol) {result = HyprlandAPI::createFunctionHook(handle, match.address, callback); break;}
            if (result && result->hook()) return result;
            if (result) HyprlandAPI::removeFunctionHook(handle, result);
            throw std::runtime_error("desktop backdrop hook failed: " + symbol + (result ? " (hook rejected)" : " (symbol missing)"));
        };
        pass_hook = hook("_ZN6Render11CRenderPass3addEON9Hyprutils6Memory14CUniquePointerI12IPassElementEE", reinterpret_cast<const void*>(&add_pass));
        timer = makeShared<CEventLoopTimer>(std::chrono::milliseconds(4),
            [this](SP<CEventLoopTimer> current, void*) {update(); current->updateTimeout(std::chrono::milliseconds(4));}, nullptr);
        g_pEventLoopManager->addTimer(timer);
    }
    void update() {
        if(Clock::now()<scan_at)return;
        scan_at=Clock::now()+std::chrono::milliseconds(4);
        for(auto it=entries.begin();it!=entries.end();) {
            auto& entry=it->second;struct stat st{};
            if(entry.capture->window.expired() || fstat(entry.capture->fd,&st)!=0 || st.st_nlink==0) {
                entry.capture->dead=true;

                it=entries.erase(it);
            } else {if(entry.capture->fence || Clock::now()>=entry.capture->next)if(auto w=entry.capture->window.lock(); w && w->m_monitor.lock())render_desktop(entry.capture, w->m_monitor.lock());++it;}
        }
        std::error_code error;
        for(const auto& path:std::filesystem::directory_iterator(vf::backdrop_directory(),error)) {
            const auto name=path.path().string();if(entries.contains(name))continue;
            int fd=open(name.c_str(),O_RDWR|O_CLOEXEC|O_NOFOLLOW);struct stat st{};
            if(fd<0)continue;
            if(fstat(fd,&st)!=0 || !S_ISREG(st.st_mode) || st.st_uid!=getuid() || st.st_size!=static_cast<off_t>(vf::backdrop_shm_size)) {close(fd);continue;}
            auto* memory=static_cast<vf::BackdropShm*>(mmap(nullptr,vf::backdrop_shm_size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0));
            if(memory==MAP_FAILED){close(fd);continue;}
            PHLWINDOW window;
            if(memory->magic==vf::backdrop_shm_magic)for(const auto& w:Desktop::windowState()->windows())
                if(reinterpret_cast<uintptr_t>(w.get())==memory->window && w->m_isMapped && w->getPID()==static_cast<pid_t>(memory->pid) && w->m_class.starts_with("ViewflowReverse-MacNative-")){window=w;break;}
            if(!window){if(memory->magic==vf::backdrop_shm_magic && memory->pid>1 && kill(static_cast<pid_t>(memory->pid),0)<0 && errno==ESRCH)unlink(name.c_str());munmap(memory,vf::backdrop_shm_size);close(fd);continue;}
            auto capture=std::make_shared<Capture>();capture->fd=fd;capture->memory=memory;capture->window=window;
            entries.emplace(name,Entry{capture});
        }
    }
    ~Impl() {
        g_pEventLoopManager->removeTimer(timer);
        timer.reset();
        if(pass_hook)HyprlandAPI::removeFunctionHook(handle,pass_hook);
        pass_hook=nullptr;
        for(auto& [_,entry]:entries)entry.capture->dead=true;
    }
};
PopupBackdrops::PopupBackdrops(void* handle):impl_(std::make_unique<Impl>(handle)) {}
PopupBackdrops::~PopupBackdrops()=default;
}

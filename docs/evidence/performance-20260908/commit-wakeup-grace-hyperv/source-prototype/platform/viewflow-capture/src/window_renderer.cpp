// SPDX-License-Identifier: GPL-3.0-only
// Render scopes derive from HyprCapture caa7657; see ../NOTICE.
#include "window_renderer.hpp"
#include "window_capture_geometry.hpp"
#include "capture_geometry_epoch.hpp"
#include "window_gpu_export.hpp"
#include "ime_popup_scope.hpp"
#include <sstream>
#include <hyprland/src/plugins/PluginAPI.hpp>
#define private public
#define protected public
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/desktop/view/Popup.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/protocols/InputMethodV2.hpp>
#include <hyprland/src/render/gl/GLFramebuffer.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#undef protected
#undef private
#include <GLES3/gl3.h>
#include <drm_fourcc.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <vector>
#include <ctime>
namespace viewflow_capture {
using namespace Render;
using namespace Render::GL;
using CFramebuffer = Render::IFramebuffer;
namespace {
struct OwnedImePopup {
    SP<CWLSurfaceResource> surface;
    Vector2D position;
};

std::vector<OwnedImePopup> ownedImePopups(const PHLWINDOW& window, CBox& bounds) {
    std::vector<OwnedImePopup> result;
    if (window->m_isX11 || !g_pInputManager)
        return result;
    auto& relay = g_pInputManager->m_relay;
    const auto input = relay.getFocusedTextInput();
    const auto ime = relay.m_inputMethod.lock();
    if (!input || !ime)
        return result;
    const auto focused = input->focusedSurface();
    const auto captured = window->wlSurface()->resource();
    for (const auto& popup : relay.m_inputMethodPopups) {
        const auto protocol = popup->m_popup.lock();
        if (!protocol || !ownsImePopup(captured.get(), focused.get(), ime.get(),
                protocol->m_owner.lock().get(), input->isEnabled(), ime->m_active, protocol->m_mapped))
            continue;
        const auto surface = popup->getSurface();
        if (!surface || !surface->m_current.texture)
            continue;
        const auto position = popup->globalBox().pos();
        // Include subsurfaces as well as the candidate panel itself. Preserve
        // logical coordinates here; the existing capture planner rounds once.
        surface->breadthfirst([&](SP<CWLSurfaceResource> child, const Vector2D& offset, void*) {
            if (!child->m_current.texture || child->m_current.size.x < 1 || child->m_current.size.y < 1)
                return;
            const auto origin = position + offset;
            const auto right = std::max(bounds.x + bounds.w, origin.x + child->m_current.size.x);
            const auto bottom = std::max(bounds.y + bounds.h, origin.y + child->m_current.size.y);
            bounds.x = std::min(bounds.x, origin.x);
            bounds.y = std::min(bounds.y, origin.y);
            bounds.w = right - bounds.x;
            bounds.h = bottom - bounds.y;
        }, nullptr);
        result.push_back({surface, position});
    }
    return result;
}

void renderOwnedImePopup(const OwnedImePopup& popup, const PHLMONITOR& monitor, const Vector2D& offset) {
    CSurfacePassElement::SRenderData data;
    data.pMonitor = monitor;
    data.pos = popup.position + offset;
    data.w = popup.surface->m_current.size.x;
    data.h = popup.surface->m_current.size.y;
    data.squishOversized = false;
    // Transparent export has no desktop background to blur. Use the native
    // surface texture and alpha without sampling unrelated desktop content.
    popup.surface->breadthfirst([&](SP<CWLSurfaceResource> child, const Vector2D& local, void*) {
        if (!child->m_current.texture || child->m_current.size.x < 1 || child->m_current.size.y < 1)
            return;
        data.localPos = local;
        data.surface = child;
        data.texture = child->m_current.texture;
        data.mainSurface = child == popup.surface;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CSurfacePassElement>(data));
        ++data.surfaceCounter;
    }, nullptr);
}

class FullSurfaceVisibleRegionOverride {
  public:
    explicit FullSurfaceVisibleRegionOverride(const PHLWINDOW& window, const std::vector<OwnedImePopup>& imePopups) {
        if (!window || !window->wlSurface() || !window->wlSurface()->resource())
            return;

        overrideTree(window->wlSurface()->resource());
        // renderWindow(RENDER_PASS_ALL) also renders the owner's XDG popup
        // tree. Its surfaces are not wl_subsurfaces of the main wl_surface.
        // Keep the export's visibility scope aligned with that render tree,
        // without admitting unrelated windows or compositor-wide IME surfaces.
        if (!window->m_isX11 && window->m_popupHead) {
            window->m_popupHead->breadthfirst(
                [this](SP<Desktop::View::CPopup> popup, void*) {
                    if (popup && popup->aliveAndVisible() && popup->wlSurface())
                        overrideTree(popup->wlSurface()->resource());
                }, nullptr);
        }
        for (const auto& popup : imePopups)
            overrideTree(popup.surface);
    }

  private:
    void overrideTree(const SP<CWLSurfaceResource>& root) {
        if (!root)
            return;
        root->breadthfirst(
            [this](SP<CWLSurfaceResource> resource, const Vector2D&, void*) {
                auto surface = Desktop::View::CWLSurface::fromResource(resource);
                if (!surface || std::any_of(m_records.begin(), m_records.end(),
                        [&](const auto& record) { return record.surface == surface; }))
                    return;

                m_records.push_back({.surface = surface, .visibleRegion = surface->m_visibleRegion});

                const int width = std::max(1, static_cast<int>(std::lround(resource->m_current.bufferSize.x > 0 ? resource->m_current.bufferSize.x :
                                                                                                                 resource->m_current.size.x)));
                const int height = std::max(1, static_cast<int>(std::lround(resource->m_current.bufferSize.y > 0 ? resource->m_current.bufferSize.y :
                                                                                                                   resource->m_current.size.y)));
                surface->m_visibleRegion = CRegion{0, 0, double(width), double(height)};
            },
            nullptr);
    }

  public:
    ~FullSurfaceVisibleRegionOverride() {
        for (auto& record : m_records) {
            if (record.surface)
                record.surface->m_visibleRegion = record.visibleRegion;
        }
    }

    FullSurfaceVisibleRegionOverride(const FullSurfaceVisibleRegionOverride&) = delete;
    FullSurfaceVisibleRegionOverride& operator=(const FullSurfaceVisibleRegionOverride&) = delete;

  private:
    struct Record {
        SP<Desktop::View::CWLSurface> surface;
        CRegion                      visibleRegion;
    };

    std::vector<Record> m_records;
};

class WindowAnimationGoalOverride {
  public:
    explicit WindowAnimationGoalOverride(const PHLWINDOW& window) : m_window(window) {
        if (!m_window || !m_window->m_realPosition || !m_window->m_realSize)
            return;

        m_position = m_window->m_realPosition->value();
        m_size = m_window->m_realSize->value();
        m_active = true;
        setPositionOffset({});
    }

    void setPositionOffset(const Vector2D& offset) {
        if (!m_active || !m_window || !m_window->m_realPosition || !m_window->m_realSize)
            return;

        m_window->m_realPosition->value() = m_window->m_realPosition->goal() + offset;
        m_window->m_realSize->value() = m_window->m_realSize->goal();
        m_window->updateWindowDecos();
    }

    ~WindowAnimationGoalOverride() {
        if (!m_active || !m_window || !m_window->m_realPosition || !m_window->m_realSize)
            return;

        m_window->m_realPosition->value() = m_position;
        m_window->m_realSize->value() = m_size;
        m_window->updateWindowDecos();
    }

    WindowAnimationGoalOverride(const WindowAnimationGoalOverride&) = delete;
    WindowAnimationGoalOverride& operator=(const WindowAnimationGoalOverride&) = delete;

  private:
    PHLWINDOW m_window;
    Vector2D  m_position;
    Vector2D  m_size;
    bool      m_active = false;
};

class WindowLocalProjectionScope {
  public:
    explicit WindowLocalProjectionScope(const PHLMONITOR& monitor) : m_monitor(monitor), m_transform(monitor->m_transform),
        m_fbSize(g_pHyprRenderer->m_renderData.fbSize), m_projection(g_pHyprRenderer->m_renderData.targetProjection),
        m_type(g_pHyprRenderer->m_renderData.projectionType), m_transformDamage(g_pHyprRenderer->m_renderData.transformDamage),
        m_noSimplify(g_pHyprRenderer->m_renderData.noSimplify) {
        glGetIntegerv(GL_VIEWPORT, m_viewport.data());
        m_monitor->m_transform = WL_OUTPUT_TRANSFORM_NORMAL;
    }
    void apply(int width, int height) {
        g_pHyprRenderer->m_renderData.fbSize = Vector2D{width, height};
        g_pHyprRenderer->setProjectionType(RPT_EXPORT);
        g_pHyprRenderer->m_renderData.transformDamage = false;
        // Pass simplification clips against the physical monitor's bounds.
        // Export targets can be larger or have a different axis orientation.
        g_pHyprRenderer->m_renderData.noSimplify = true;
        g_pHyprOpenGL->setViewport(0, 0, width, height);
    }
    ~WindowLocalProjectionScope() {
        m_monitor->m_transform = m_transform;
        auto& data = g_pHyprRenderer->m_renderData;
        data.fbSize = m_fbSize;
        data.targetProjection = m_projection;
        data.projectionType = m_type;
        data.transformDamage = m_transformDamage;
        data.noSimplify = m_noSimplify;
        g_pHyprOpenGL->setViewport(m_viewport[0], m_viewport[1], m_viewport[2], m_viewport[3]);
    }
    WindowLocalProjectionScope(const WindowLocalProjectionScope&) = delete;
    WindowLocalProjectionScope& operator=(const WindowLocalProjectionScope&) = delete;
  private:
    PHLMONITOR m_monitor;
    wl_output_transform m_transform;
    Vector2D m_fbSize;
    Hyprutils::Math::Mat3x3 m_projection;
    Render::eRenderProjectionType m_type;
    bool m_transformDamage;
    bool m_noSimplify;
    std::array<GLint, 4> m_viewport{};
};


struct RendererFlags {
    bool feedback = g_pHyprRenderer->m_bBlockSurfaceFeedback;
    bool shader = g_pHyprRenderer->m_renderData.blockScreenShader;
    bool snapshot = g_pHyprRenderer->m_bRenderingSnapshot;
    ~RendererFlags() {
        g_pHyprRenderer->m_bBlockSurfaceFeedback = feedback;
        g_pHyprRenderer->m_renderData.blockScreenShader = shader;
        g_pHyprRenderer->m_bRenderingSnapshot = snapshot;
    }
};
}
struct WindowRenderer::Impl {
    WindowGpuSender sender;
    PHLWINDOW target;
    SP<CWLSurfaceResource> target_surface;
    CaptureGeometryEpoch geometryEpoch;
    SP<CFramebuffer> framebuffer;
    WindowGpuExportCache exporter;
    explicit Impl(std::string socket) : sender(std::move(socket)) {}
};
WindowRenderer::WindowRenderer(std::string socket) : impl_(std::make_unique<Impl>(std::move(socket))) {}
WindowRenderer::~WindowRenderer() = default;
int WindowRenderer::notification_fd() const { return impl_->sender.notificationFd(); }
void WindowRenderer::drain_notifications() { impl_->sender.drainNotifications(); }
bool WindowRenderer::capture(std::uint64_t address, std::uint64_t sequence) {
    const auto state = impl_->sender.state();
    if (state == WindowGpuSenderState::Connecting || state == WindowGpuSenderState::Busy) return true;
    if (state != WindowGpuSenderState::Ready || !g_pCompositor || !g_pHyprRenderer || !g_pHyprOpenGL) return false;
    PHLWINDOW window;
    for (const auto& candidate : Desktop::windowState()->windows())
        if (reinterpret_cast<std::uintptr_t>(candidate.get()) == address) { window = candidate; break; }
    if (!window || !window->m_isMapped || window->isHidden() || !window->wlSurface() || !window->wlSurface()->resource()) return false;
    if (impl_->target && impl_->target != window) return false;
    if (impl_->target_surface && impl_->target_surface != window->wlSurface()->resource()) return false;
    impl_->target = window;
    impl_->target_surface = window->wlSurface()->resource();
    const auto monitor = window->m_monitor.lock();
    if (!monitor) return false;
    g_pHyprOpenGL->makeEGLCurrent();
    WindowAnimationGoalOverride goal(window);
    CBox box = window->getFullWindowBoundingBox();
    if (window->m_workspace && !window->m_pinned) box.translate(window->m_workspace->m_renderOffset->value());
    box.translate(window->m_floatingOffset);
    const auto imePopups = ownedImePopups(window, box);
    const auto geometry = planWindowCaptureGeometry(box.x, box.y, box.w, box.h,
        monitor->m_position.x, monitor->m_position.y, monitor->m_scale, static_cast<int>(monitor->m_transform));
    if (!geometry.supported || static_cast<std::uint64_t>(geometry.pixelWidth) * geometry.pixelHeight > 64ULL * 1024 * 1024) return false;
    const int width = geometry.pixelWidth, height = geometry.pixelHeight;
    // Freeze the native identity and main-surface content rectangle before the
    // temporary capture-origin translation. This is evidence for a later local
    // input grant, never permission to inject. XWayland has no input binding.
    std::optional<std::array<std::uint8_t, gpuwire::HCGI_BYTES>> inputWire;
    if (!window->m_isX11) {
        auto content = window->getWindowMainSurfaceBox();
        if (window->m_workspace && !window->m_pinned) content.translate(window->m_workspace->m_renderOffset->value());
        content.translate(window->m_floatingOffset);
        const auto surface = window->wlSurface()->resource();
        const auto pid = window->getPID();
        gpuwire::InputGeometry input{
            address, reinterpret_cast<std::uintptr_t>(surface.get()),
            pid > 0 ? static_cast<std::uint64_t>(pid) : 0,
            {content.x, content.y, content.w, content.h},
            {surface->m_current.size.x, surface->m_current.size.y}
        };
        std::array<std::uint8_t, gpuwire::HCGI_BYTES> encoded{};
        if (gpuwire::encode(input, encoded)) inputWire = encoded;
    }
    const auto epoch = impl_->geometryEpoch.observe(geometry, inputWire);
    if (!epoch) return false;
    auto& fb = impl_->framebuffer;
    if (!fb || fb->m_size.x != width || fb->m_size.y != height) {
        impl_->exporter.reset();
        fb = g_pHyprRenderer->createFB("viewflow-capture-window");
        if (!fb || !fb->alloc(width, height, DRM_FORMAT_ABGR8888)) return false;
    }
    goal.setPositionOffset(monitor->m_position - Vector2D{geometry.x, geometry.y});
    timespec stamp{};
    if (clock_gettime(CLOCK_MONOTONIC, &stamp) != 0) return false;
    const auto capture_ns = std::uint64_t(stamp.tv_sec) * 1000000000ULL + std::uint64_t(stamp.tv_nsec);
    {
        RendererFlags flags;
        WindowLocalProjectionScope projection(monitor);
        CRegion damage{0, 0, double(width), double(height)};
        g_pHyprRenderer->m_bBlockSurfaceFeedback = true;
        fb->setImageDescription(monitor->workBufferImageDescription());
        if (!g_pHyprRenderer->beginFullFakeRender(monitor, damage, fb)) return false;
        projection.apply(width, height);
        g_pHyprRenderer->m_bRenderingSnapshot = true;
        FullSurfaceVisibleRegionOverride visible(window, imePopups);
        g_pHyprRenderer->draw(CClearPassElement::SClearData{CHyprColor{0., 0., 0., 0.}});
        g_pHyprRenderer->startRenderPass();
        g_pHyprRenderer->renderWindow(window, monitor, Time::steadyNow(), true, RENDER_PASS_ALL, false, false);
        for (const auto& popup : imePopups)
            renderOwnedImePopup(popup, monitor, monitor->m_position - Vector2D{geometry.x, geometry.y});
        g_pHyprRenderer->m_renderData.blockScreenShader = true;
        g_pHyprRenderer->endRender();
    }
    gpuwire::Frame metadata{
        .sequence = sequence, .captureMonotonicNs = capture_ns, .geometryEpoch = *epoch,
        .logicalX = geometry.x, .logicalY = geometry.y, .logicalWidth = geometry.width, .logicalHeight = geometry.height,
        .imageWidth = std::uint32_t(width), .imageHeight = std::uint32_t(height),
        .cropWidth = std::uint32_t(width), .cropHeight = std::uint32_t(height), .flipY = false,
    };
    const auto gl = dynamic_cast<Render::GL::CGLFramebuffer*>(fb.get());
    if (!gl) return false;
    auto packet = impl_->exporter.exportFrame(gl->getFBID(), metadata);
    if (packet) packet->inputGeometry = std::move(inputWire);
    return packet && impl_->sender.submit(std::move(*packet));
}
}

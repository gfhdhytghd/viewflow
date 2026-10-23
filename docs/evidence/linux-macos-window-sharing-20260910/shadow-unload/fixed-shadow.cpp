// SPDX-License-Identifier: GPL-3.0-only
#include "macos_shadow.hpp"
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>
#include <hyprland/src/config/shared/complex/ComplexDataTypes.hpp>
#include <map>
#include <algorithm>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>

namespace viewflow::hyprland {
namespace {
// Two native Hyprland shadow lobes approximate the broad macOS ambient
// shadow and the tighter contact edge. Values are logical points, independent
// of the user's ordinary-window shadow settings and display scale.
constexpr int AMBIENT_RANGE = 42;
constexpr int CONTACT_RANGE = 9;
constexpr float AMBIENT_ALPHA = 0.24F;
constexpr float CONTACT_ALPHA = 0.12F;
constexpr double AMBIENT_OFFSET_Y = 10.0;
constexpr double CONTACT_OFFSET_Y = 2.0;
constexpr double RADIUS = 12.0;

class ShadowPass final : public IPassElement {
  PHLWINDOWREF m_window;
  PHLMONITORREF m_monitor;
  float m_alpha;
public:
  ShadowPass(PHLWINDOW window, PHLMONITOR monitor, float alpha):m_window(window),m_monitor(monitor),m_alpha(alpha) {}
  bool needsLiveBlur() override {return false;}
  bool needsPrecomputeBlur() override {return false;}
  const char* passName() override {return "Viewflow Mac native shadow";}
  ePassElementType type() override {return EK_CUSTOM;}
  bool disableSimplification() override {return true;}
  std::vector<UP<IPassElement>> draw() override {
    const auto window=m_window.lock();const auto monitor=m_monitor.lock();
    if(!window || !monitor || !window->m_isMapped)return {};
    CBox base{window->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT),window->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT)};
    if(base.w<80 || base.h<40)return {};
    if(window->m_workspace && !window->m_pinned)base.translate(window->m_workspace->m_renderOffset->value());
    base.translate(window->m_floatingOffset-monitor->m_position);
    const auto saved=g_pHyprRenderer->m_renderData.currentWindow;
    g_pHyprRenderer->m_renderData.currentWindow=m_window;
    const auto lobe=[&](int range,double offset,float opacity) {
      auto box=base.copy().expand(range).translate(Vector2D{0.0,offset}).scale(monitor->m_scale).round();
      const Config::CGradientValueData color{CHyprColor{0.F,0.F,0.F,opacity}};
      g_pHyprRenderer->drawShadow(box,static_cast<int>(RADIUS*monitor->m_scale),2.F,
          static_cast<int>(range*monitor->m_scale),color,m_alpha);
    };
    lobe(AMBIENT_RANGE,AMBIENT_OFFSET_Y,AMBIENT_ALPHA);
    lobe(CONTACT_RANGE,CONTACT_OFFSET_Y,CONTACT_ALPHA);
    g_pHyprRenderer->m_renderData.currentWindow=saved;
    return {};
  }
};
class Decoration final : public IHyprWindowDecoration {
  PHLWINDOWREF m_window;
  CBox m_box;
public:
  explicit Decoration(PHLWINDOW window):IHyprWindowDecoration(window),m_window(window) {updateWindow(window);}
  SDecorationPositioningInfo getPositioningInfo() override {
    SDecorationPositioningInfo info;
    info.policy=DECORATION_POSITION_ABSOLUTE;
    info.desiredExtents={{44,34},{44,54}};
    info.edges=DECORATION_EDGE_TOP|DECORATION_EDGE_LEFT|DECORATION_EDGE_RIGHT|DECORATION_EDGE_BOTTOM;
    return info;
  }
  void onPositioningReply(const SDecorationPositioningReply&) override {}
  void draw(PHLMONITOR monitor,float const& alpha) override {
    const auto window=m_window.lock();if(!window || !window->m_isMapped)return;
    g_pHyprRenderer->addPassElement(makeUnique<ShadowPass>(window,monitor,alpha));
  }
  eDecorationType getDecorationType() override {return DECORATION_CUSTOM;}
  eDecorationLayer getDecorationLayer() override {return DECORATION_LAYER_BOTTOM;}
  uint64_t getDecorationFlags() override {return DECORATION_NON_SOLID;}
  std::string getDisplayName() override {return "Viewflow macOS shadow";}
  void updateWindow(PHLWINDOW window) override {
    damageEntire();
    m_box=CBox{window->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT),window->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT)};
    damageEntire();
  }
  void damageEntire() override {if(m_box.w>0 && m_box.h>0)g_pHyprRenderer->damageBox(m_box.copy().expand(54));}
};
}
struct MacOsShadows::Impl {
  void* handle;
  CHyprSignalListener opened,closed;
  std::map<void*,std::pair<PHLWINDOWREF,Decoration*>> decorations;
  void attach(PHLWINDOW window) {
    std::erase_if(decorations,[](const auto& entry){return entry.second.first.expired();});
    if(!window || !window->m_isMapped || !window->m_class.starts_with("ViewflowReverse-Mac-") || decorations.contains(window.get()))return;
    auto decoration=makeUnique<Decoration>(window);auto* ptr=decoration.get();
    if(HyprlandAPI::addWindowDecoration(handle,window,std::move(decoration)))decorations.emplace(window.get(),std::make_pair(PHLWINDOWREF{window},ptr));
  }
  explicit Impl(void* h):handle(h) {
    opened=Event::bus()->m_events.window.open.listen([this](PHLWINDOW window){attach(window);});
    // Closed windows may still be retained for fade-out, with decorations
    // whose code belongs to this plugin. Keep weak ownership until destruction.
    for(const auto& window:Desktop::windowState()->windows())attach(window);
  }
  ~Impl() {
    opened.reset();closed.reset();
    for(const auto& [_,entry]:decorations)if(const auto window=entry.first.lock()) {
      HyprlandAPI::removeWindowDecoration(handle,entry.second);
      // Hyprland defers decoration removal for hidden/unmapped windows.
      // Those windows can outlive this plugin through fade-out or grouping.
      std::erase(window->m_decosToRemove,entry.second);
      std::erase_if(window->m_windowDecorations,[&](const auto& decoration) {
        if(decoration.get()!=entry.second)return false;
        g_pDecorationPositioner->uncacheDecoration(decoration.get());
        return true;
      });
    }
    // Render passes retain plugin-defined deleters until the next render,
    // including off-screen overview snapshots. Dispose after decorations so
    // no decoration can enqueue another pass while its cleanup runs.
    g_pHyprRenderer->m_renderPass.removeAllOfType("Viewflow Mac native shadow");
    if(&g_pHyprRenderer->currentPass()!=&g_pHyprRenderer->m_renderPass)
      g_pHyprRenderer->currentPass().removeAllOfType("Viewflow Mac native shadow");
  }
};
MacOsShadows::MacOsShadows(void* handle):m_impl(std::make_unique<Impl>(handle)){}
MacOsShadows::~MacOsShadows()=default;
}

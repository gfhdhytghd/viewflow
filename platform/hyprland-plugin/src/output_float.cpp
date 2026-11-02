// SPDX-License-Identifier: GPL-3.0-only
#include "output_float.hpp"
#include "output_float_geometry.hpp"
#include "../../reverse-common/work_area_math.hpp"
#include <nlohmann/json.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include "../../hyprland-compat/float_geometry.hpp"
#include "../../hyprland-compat/work_area.hpp"
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/workspace/HLWorkspace.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <algorithm>
#include <vector>

namespace viewflow::hyprland {
struct OutputFloat::Impl {
    struct Route { std::string output, special, underlay; };
    std::vector<Route> routes;
    struct Area { PHLWINDOWREF window; nlohmann::json data; };
    std::vector<Area> areas;
    std::vector<PHLMONITORREF> reservedMonitors;
    bool updateAreas() {
        bool changed=false;
        std::erase_if(areas,[](const auto& a){return !a.window.lock();});
        std::vector<std::pair<PHLMONITOR,Area>> latest;
        for(const auto& area:areas) {
            const auto w=area.window.lock();if(!w || !owned(w))continue;
            const auto mon=w->m_workspace->m_monitor.lock();
            std::erase_if(latest,[&](const auto& entry){return entry.first==mon;});
            latest.emplace_back(mon,area);
        }
        for (const auto& [mon,selected]:latest) {
            const auto& area=selected;
            const auto scale=area.data.value("source_scale",double(mon->m_scale));
            if (!std::isfinite(scale) || scale<=0)continue;
            const auto box=mon->logicalBox();
            const auto& base=hyprland_compat::reserved_base(mon);
            std::array<double,4> edges{base.top(),base.right(),base.bottom(),base.left()};
            double best=0;
            for(const auto& d:area.data.at("displays")) {
                const auto v=d.at("values").get<std::array<double,8>>();
                const auto overlap=reverse::overlap({box.x,box.y,box.w,box.h},{v[0]/scale,v[1]/scale,v[2]/scale,v[3]/scale});
                if(overlap<=best)continue;
                best=overlap;
                for(size_t i=0;i<4;++i)edges[i]=std::max(i==0?base.top():i==1?base.right():i==2?base.bottom():base.left(),v[i+4]*(i==0 || i==2 ? box.h/v[3] : box.w/v[2]));
            }
            // An empty snapshot or an absent display clears the peer reservation.
            const Desktop::CReservedArea desired(edges[0],edges[1],edges[2],edges[3]);
            if(hyprland_compat::set_reserved(mon,desired)) {
                changed=true;
                if(std::none_of(reservedMonitors.begin(),reservedMonitors.end(),[&](auto& ref){return ref.lock()==mon;}))reservedMonitors.push_back(mon);
            }
        }
        return changed;
    }
    // Weak identities never keep a closed client alive or match a reused address.
    std::vector<PHLWINDOWREF> forced;
    CHyprSignalListener opened, closed, moved, floated, reloaded, monitors, workspace, button, fullscreen;
    wl_event_source* pending = nullptr;
    bool applying = false;
    bool owned(const PHLWINDOW& w) {
        if (!w->m_workspace) return false;
        const auto monitor = w->m_workspace->m_monitor.lock();
        if (!monitor) return false;
        const auto name = w->m_workspace->addressableName();
        for (const auto& r : routes)
            if (monitor->m_name == r.output && (name == r.special || name == "special:" + r.special || name == r.underlay || name == "name:" + r.underlay)) return true;
        return false;
    }
    void reconcile() {
        if (applying) return;
        applying = true;
        std::erase_if(forced, [](const auto& ref) { const auto w = ref.lock(); return !w || !w->mapped(); });
        updateAreas();
        const auto windows = Desktop::windowState()->windows();
        for (const auto& w : windows) {
            if (!w || !w->mapped()) continue;
            const auto entry = std::find_if(forced.begin(), forced.end(), [&](const auto& ref) { return ref.lock() == w; });
            if (!owned(w)) {
                if (entry != forced.end()) {
                    if (hyprland_compat::floating(w, false)) forced.erase(entry);
                }
                continue;
            }
            const bool wasFloating=w->isFloating();
            // Local and proxy-first drags retain their current owner. Clamp on
            // release or after the explicit remote geometry operation completes.
            if (g_layoutManager->dragController()->target()==w->layoutTarget()) continue;
            const auto geometry=wasFloating ? Desktop::View::IGeometric::GEOMETRIC_GOAL : Desktop::View::IGeometric::GEOMETRIC_CURRENT;
            auto before=w->geometricBox(geometry);before.addExtents(w->getFullWindowExtents());
            const auto base = w->position(geometry);
            const auto size = w->size(geometry);
            const auto work = w->m_workspace->m_monitor.lock()->logicalBoxMinusReserved();
            if (!wasFloating && !hyprland_compat::floating(w, true)) continue;
            if (!wasFloating && entry == forced.end()) forced.push_back(w);
            if(Fullscreen::controller()->isFullscreen(w) || work.w<=0 || work.h<=0)continue;
            // Use the tile's visible rectangle, never the remembered float size.
            // Keep decoration extents inside the logical work area as well.
            const auto fit=fitFloat({before.x,before.y,before.w,before.h},{work.x,work.y,work.w,work.h});
            if(wasFloating && fit.x==before.x && fit.y==before.y && fit.width==before.w && fit.height==before.h)continue;
            hyprland_compat::place(w, {fit.x + base.x - before.x, fit.y + base.y - before.y},
                {std::max(1.0, fit.width - (before.w - size.x)), std::max(1.0, fit.height - (before.h - size.y))});
        }
        applying = false;
    }
    void schedule() {
        if (applying || pending) return;
        // Move/open signals can precede the layout's final geometry update.
        pending = wl_event_loop_add_idle(g_pCompositor->m_wlEventLoop, [](void* data) {
            auto& self = *static_cast<Impl*>(data); self.pending = nullptr; self.reconcile();
        }, this);
    }
    Impl() {
        auto& e = Event::bus()->m_events;
        opened = e.window.openLate.listen([this](PHLWINDOW) { schedule(); });
        button=e.input.mouse.button.listen([this](IPointer::SButtonEvent event,Event::SCallbackInfo&){if(!event.state)schedule();});
        closed = e.window.close.listen([this](PHLWINDOW) { schedule(); });
        moved = e.window.moveToWorkspace.listen([this](PHLWINDOW, PHLWORKSPACE) { schedule(); });
        fullscreen=e.window.fullscreen.listen([this](PHLWINDOW){schedule();});
        floated = e.window.floating.listen([this](PHLWINDOW) { schedule(); });
        reloaded = e.config.reloaded.listen([this] { schedule(); });
        monitors = e.monitor.layoutChanged.listen([this] { schedule(); });
        workspace = e.workspace.moveToMonitor.listen([this](PHLWORKSPACE, PHLMONITOR) { schedule(); });
    }
    ~Impl() {
        if (pending) wl_event_source_remove(pending);
        for(auto& ref:reservedMonitors)if(auto mon=ref.lock()) {
            hyprland_compat::set_reserved(mon,hyprland_compat::reserved_base(mon));
        }
    }
};
OutputFloat::OutputFloat(): impl(std::make_unique<Impl>()) {}
OutputFloat::~OutputFloat() = default;
void OutputFloat::refresh(){impl->schedule();}
void OutputFloat::workarea(std::string selector,std::string snapshot) {
    const auto w=Desktop::viewState()->query().selector(selector).runWindow();if(!w)return;
    auto data=nlohmann::json::parse(snapshot);
    if(!data.contains("displays") || !data["displays"].is_array() || data["displays"].size()>16)throw std::runtime_error("work area displays");
    if(data.contains("source_scale")) {
        const auto scale=data["source_scale"].get<double>();
        if(!std::isfinite(scale) || scale<=0)throw std::runtime_error("work area source scale");
    }
    for(const auto& display:data["displays"]) {
        const auto v=display.at("values").get<std::array<double,8>>();
        if(!std::all_of(v.begin(),v.end(),[](double n){return std::isfinite(n);}) || v[2]<=0 || v[3]<=0 ||
           !std::all_of(v.begin()+4,v.end(),[](double n){return n>=0;}) || v[4]+v[6]>=v[3] || v[5]+v[7]>=v[2])
            throw std::runtime_error("work area geometry");
    }
    std::erase_if(impl->areas,[&](const auto& a){return a.window.lock()==w;});
    impl->areas.push_back({w,std::move(data)});impl->schedule();
}
void OutputFloat::add(std::string output, std::string special, std::string underlay) {
    auto& routes = impl->routes;
    if (std::any_of(routes.begin(),routes.end(),[&](const auto& r) {
        return r.output==output && r.special==special && r.underlay==underlay;
    })) return; // Registration is idempotent; events enforce the policy.
    std::erase_if(routes, [&](const auto& r) { return r.output == output; });
    routes.push_back({std::move(output), std::move(special), std::move(underlay)});
    impl->schedule();
}
}

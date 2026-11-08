#include "window_recall.hpp"
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowMetadata.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/workspace/HLWorkspace.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <aquamarine/backend/Backend.hpp>
#include <aquamarine/output/Output.hpp>
#include <nlohmann/json.hpp>
#include <cstdio>

namespace viewflow::hyprland {
namespace {
namespace vr=viewflow::recall;
vr::Shortcut shortcut;
PHLMONITORREF recentPhysical;
wl_event_source* pending=nullptr;
vr::Rect rect(const CBox& box) {return {box.x,box.y,box.width,box.height};}
bool physical(const PHLMONITOR& monitor) {
    if(!monitor || !monitor->m_enabled || !monitor->m_output || monitor->m_mirrorOf.lock())return false;
    const auto backend=monitor->m_output->getBackend();
    return backend && backend->type()==Aquamarine::AQ_BACKEND_DRM;
}
bool proxy(const PHLWINDOW& window) {
    return window->metadata().appID().starts_with("ViewflowReverse-") || window->metadata().appID().starts_with("viewflow-remote-");
}
}
viewflow::recall::Shortcut recallShortcut() {return shortcut;}
void configureRecallShortcut(std::string_view value) {
    const auto parsed=vr::parse_shortcut(value);
    if(parsed==vr::Shortcut{7,'D'})throw std::invalid_argument("Ctrl+Alt+Shift+D is reserved for forced input detach");
    shortcut=parsed;
}
void observeRecallInteraction() {
    const auto monitor=Desktop::focusState()->monitor();
    if(physical(monitor))recentPhysical=monitor;
}
nlohmann::json recallWindows(bool dryRun) {
    std::vector<PHLMONITOR> screens;std::vector<vr::Rect> rectangles;
    for(const auto& monitor:State::monitorState()->monitors())if(physical(monitor)) {
        screens.push_back(monitor);rectangles.push_back(rect(monitor->logicalBox()));
    }
    if(screens.empty())return {{"ok",false},{"error","No physical display"}};
    observeRecallInteraction();
    auto target=screens.front();
    if(auto recent=recentPhysical.lock();physical(recent))target=recent;
    const auto workspace=target->m_activeWorkspace;
    if(!workspace)return {{"ok",false},{"error","Physical display has no active workspace"}};
    const auto work=rect(target->logicalBoxMinusReserved());
    const auto focus=Desktop::focusState()->window();
    std::vector<PHLWINDOW> windows;
    for(const auto& window:Desktop::windowState()->windows()) {
        if(!window || !window->mapped() || proxy(window))continue;
        const auto ws=window->m_workspace;
        const auto owner=ws ? ws->m_monitor.lock() : PHLMONITOR{};
        const bool visible=ws && owner && (owner->m_activeSpecialWorkspace ? owner->m_activeSpecialWorkspace==ws : owner->m_activeWorkspace==ws);
        std::string_view wsName=ws ? std::string_view{ws->addressableName()} : std::string_view{};
        if(wsName.starts_with("name:"))wsName.remove_prefix(5);
        const bool viewflowWorkspace=wsName.starts_with("viewflow-");
        if(vr::needs_workspace_recall(rect(window->getFullWindowBoundingBox()),rectangles,
                                     physical(owner),visible,viewflowWorkspace,owner ? rect(owner->logicalBox()) : vr::Rect{}))
            windows.push_back(window);
    }
    unsigned moved=0,failed=0;bool focusedMoved=false;
    for(std::size_t index=0;index<windows.size();++index) {
        const auto& window=windows[index];
        const auto full=window->getFullWindowBoundingBox();
        const auto base=window->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
        const auto size=window->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
        const auto dest=vr::placement(rect(full),work,index);
        if(dryRun)continue;
        // Float recalled tiles so scrolling layout cannot place them off-screen
        // again. This changes only recalled windows, never the destination layout.
        Fullscreen::controller()->setFullscreenMode(window, Fullscreen::FSMODE_NONE, Fullscreen::FSMODE_NONE);
        if(!window->isFloating() && !Config::Actions::floatWindow(Config::Actions::TOGGLE_ACTION_ENABLE,window)) {
            ++failed; continue;
        }
        // Native xdg popups move with their parent; do not create another proxy.
        window->layoutTarget()->assignToSpace(workspace->space());
        bool ok=true;
        if(dest.width!=full.width || dest.height!=full.height) {
            const Vector2D desired{std::max(1.0,dest.width-(full.width-size.x)),std::max(1.0,dest.height-(full.height-size.y))};
            ok=Config::Actions::resize(desired,false,window).has_value();
        }
        const bool positioned=Config::Actions::move({dest.x+base.x-full.x,dest.y+base.y-full.y},false,window).has_value();
        if(positioned) {++moved;if(window==focus)focusedMoved=true;}
        if(!ok||!positioned)++failed;
    }
    if(focusedMoved)Desktop::focusState()->fullWindowFocus(focus,Desktop::FOCUS_REASON_KEYBIND);
    return {{"ok",failed==0},{"physical",screens.size()},{"eligible",windows.size()},{"moved",moved},{"failed",failed},{"dry_run",dryRun},{"monitor",target->m_name}};
}
void returnPointerToPhysicalScreen() {
    auto target=recentPhysical.lock();
    if(!physical(target)) {
        target=nullptr;
        for(const auto& monitor:State::monitorState()->monitors())if(physical(monitor)) {target=monitor;break;}
    }
    if(!target)return;
    const auto work=target->logicalBoxMinusReserved();
    // Inside the physical screen, away from remote handoff edges.
    Pointer::mgr()->warpTo({work.x+work.width/2,work.y+work.height/2});
}
void requestWindowRecall() {
    if(pending)return;
    pending=wl_event_loop_add_idle(g_pCompositor->m_wlEventLoop,[](void*) {
        pending=nullptr;
        try {std::fprintf(stderr,"viewflow-window-recall %s\n",recallWindows().dump().c_str());}
        catch(const std::exception& e){std::fprintf(stderr,"viewflow-window-recall failed=%s\n",e.what());}
    },nullptr);
}
void shutdownWindowRecall() {
    if(pending)wl_event_source_remove(pending);
    pending=nullptr;recentPhysical.reset();shortcut={};
}
}

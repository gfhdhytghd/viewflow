#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/plugins/PluginSystem.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>
extern "C" {
#include <lua.h>
}
APICALL EXPORT std::string PLUGIN_API_VERSION(){return HYPRLAND_API_VERSION;}
APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE h){
HyprlandAPI::addLuaFunction(h,"shadow_probe","unload",[](lua_State* l)->int{
 const char* path=lua_tostring(l,1);auto* plugin=g_pPluginSystem->getPluginByPath(path?path:"");
 if(!plugin){lua_pushstring(l,"plugin missing");return 1;}
 const int mode=lua_tointeger(l,2);
 std::vector<PHLWINDOW> held;
 int count=0;auto monitor=State::monitorState()->monitors().front();
 for(auto& w:Desktop::windowState()->windows())for(auto& d:w->m_windowDecorations)
  if(d->getDisplayName()=="Viewflow macOS shadow"){d->draw(monitor,1.F);held.push_back(w);++count;}
 if(!count){lua_pushstring(l,"no shadow decoration");return 1;}
 for(auto& w:held){if(mode==1)w->setHidden(true);if(mode==2)w->m_isMapped=false;}
 g_pPluginSystem->unloadPlugin(plugin);
 // Same deletion site as the production crash, before another frame races it.
 g_pHyprRenderer->m_renderPass.clear();
 for(auto& w:held){if(mode==1)w->setHidden(false);if(mode==2)w->m_isMapped=true;}
 lua_pushinteger(l,count);return 1;
});return {"viewflow-shadow-probe","isolated lifecycle test","Viewflow","1"};}
APICALL EXPORT void PLUGIN_EXIT(){}

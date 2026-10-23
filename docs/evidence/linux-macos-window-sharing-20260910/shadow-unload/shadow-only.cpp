#include <hyprland/src/plugins/PluginAPI.hpp>
#include "macos_shadow.hpp"
#include <memory>
std::unique_ptr<viewflow::hyprland::MacOsShadows> shadows;
APICALL EXPORT std::string PLUGIN_API_VERSION(){return HYPRLAND_API_VERSION;}
APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE h){shadows=std::make_unique<viewflow::hyprland::MacOsShadows>(h);return {"shadow-old-control","old cleanup negative control","Viewflow","1"};}
APICALL EXPORT void PLUGIN_EXIT(){shadows.reset();}

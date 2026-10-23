#pragma once
#include "../../window-recall/evdev_shortcut.hpp"
#include <nlohmann/json_fwd.hpp>
#include <string_view>
namespace viewflow::hyprland {
viewflow::recall::Shortcut recallShortcut();
void configureRecallShortcut(std::string_view value);
void observeRecallInteraction();
void requestWindowRecall();
void requestInputDetach();
void returnPointerToPhysicalScreen();
nlohmann::json recallWindows(bool dryRun=false);
void shutdownWindowRecall();
}

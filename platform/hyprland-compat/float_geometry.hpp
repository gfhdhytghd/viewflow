// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
namespace viewflow::hyprland_compat {
inline bool floating(const PHLWINDOW& w, bool enabled) {
    return Config::Actions::floatWindow(enabled ? Config::Actions::TOGGLE_ACTION_ENABLE : Config::Actions::TOGGLE_ACTION_DISABLE, w).has_value() && w->isFloating()==enabled;
}
inline void place(const PHLWINDOW& w, Vector2D position, Vector2D size) {
    (void)Config::Actions::resize(size, false, w);
    (void)Config::Actions::move(position, false, w);
}
}

// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <type_traits>

namespace viewflow::hyprland_compat {
// Upstream 0.57 adds workspaceScene. The older main-based fork has six
// parameters. Select by the installed header's signature, never by a tag.
template <typename Method, typename Renderer, typename Context, typename Layer,
          typename Monitor, typename Time>
void render_layer(Method method, Renderer& renderer, Context& context,
                  const Layer& layer, const Monitor& monitor, const Time& now) {
    if constexpr (std::is_invocable_v<Method, Renderer&, Context&, Layer, Monitor,
                                      const Time&, bool, bool, bool>)
        (renderer.*method)(context, layer, monitor, now, false, false, false);
    else
        (renderer.*method)(context, layer, monitor, now, false, false);
}
} // namespace viewflow::hyprland_compat

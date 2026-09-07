// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
namespace viewflow::hyprland {
// Diagnostic labels only; dispatch source never confers input authority.
enum class InputDispatchOrigin : std::uint32_t { Tick = 0, Readable = 1, Watchdog = 2, RenderPre = 3 };
}

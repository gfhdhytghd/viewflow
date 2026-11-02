// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
namespace viewflow::hyprland_compat {
// Native equivalent of addreserved on both supported Lua-fork and main headers.
// Preserve dynamic layer-shell reservations and read the config's static base.
inline const Desktop::CReservedArea& reserved_base(const PHLMONITOR& mon) {
    return mon->m_activeMonitorRule.m_reservedArea;
}
inline bool set_reserved(const PHLMONITOR& mon,const Desktop::CReservedArea& area) {
    const auto previous=mon->m_reservedArea;
    mon->m_reservedArea.setStatic(area);
    if(previous==mon->m_reservedArea)return false;
    g_layoutManager->recalculateMonitor(mon);return true;
}
}

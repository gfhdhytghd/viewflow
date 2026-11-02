// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "wire.hpp"
#include <array>
#include <cmath>
namespace viewflow::reverse {
struct WorkAreaDisplay {
    uint64_t id{};
    // Source-pixel coordinate plane: top-left origin, then top/right/bottom/left.
    std::array<double,8> values{};
    bool operator==(const WorkAreaDisplay&) const = default;
};
inline std::vector<uint8_t> pack_work_areas(uint64_t revision,const std::vector<WorkAreaDisplay>& displays) {
    if(!revision || displays.size()>16)throw std::runtime_error("work area snapshot extent");
    Writer w;w.u32(7);w.u32(1);w.u64(revision);w.u32(displays.size());w.u32(0);
    for(const auto& d:displays){w.u64(d.id);for(double v:d.values){if(!std::isfinite(v))throw std::runtime_error("work area value");w.u64(std::bit_cast<uint64_t>(v));}}
    return w.bytes;
}
struct WorkAreaUpdates {
    uint64_t revision{};
    std::vector<WorkAreaDisplay> displays;
    std::string preferences;
    bool changed(const std::vector<WorkAreaDisplay>& next,const std::string& prefs) const {
        return !revision || next!=displays || prefs!=preferences;
    }
    void commit(std::vector<WorkAreaDisplay> next,std::string prefs) {
        displays=std::move(next);preferences=std::move(prefs);++revision;
    }
};
struct ConstraintGeometry {
    std::array<int64_t,4> target{},actual{};
    uint64_t revision{};
    bool constrained{};
    bool suppress(std::array<int64_t,4> request,std::array<int64_t,4> local,uint64_t current) const {
        return constrained && revision==current && request==target && local==actual;
    }
    bool observe(std::array<int64_t,4> request,std::array<int64_t,4> local,uint64_t current) {
        if(request==local){constrained=false;return false;}
        if(suppress(request,local,current))return false;
        target=request;actual=local;revision=current;constrained=true;return true;
    }
};
}

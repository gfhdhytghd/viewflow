#pragma once
#include "geometry_sync.hpp"
#include <optional>
namespace viewflow::reverse {
// Coalesce layout/configure churn without blocking video or ordered input.
struct WindowResize {
    std::optional<Geometry> candidate;
    std::int64_t changed_ms{};
    void queue(Geometry geometry,std::int64_t now_ms,bool position_only=false) {
        candidate=geometry;changed_ms=position_only?now_ms-100:now_ms;
    }
    bool ready(std::int64_t now_ms) const {return candidate && now_ms-changed_ms>=100;}
    void cancel(){candidate.reset();}
};
}

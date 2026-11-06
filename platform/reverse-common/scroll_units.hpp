#pragma once
#include <cstdint>
#include <optional>
namespace viewflow::reverse {
// Window input wheel contract: a=axis (0 vertical, 1 horizontal), b=amount,
// c=0: 120 units per line/detent; c=1: 1000 units per point; d=1: gesture ended.
// Positive amounts follow AppKit on BOTH axes (opposite Wayland). Windows
// horizontal wheel has the opposite sign; adapt at each Windows boundary.
struct Scroll { int axis; double distance; bool precise; bool ended; };
inline std::optional<Scroll> decode_scroll(int axis, std::int32_t amount, int precise, int ended) {
    if ((axis!=0 && axis!=1) || (precise!=0 && precise!=1) || (ended!=0 && ended!=1)) return {};
    return Scroll{axis, amount/(precise?1000.0:120.0),precise!=0,precise!=0 && ended!=0};
}
// Quartz point fields are integral. Carry sub-point deltas across events so
// eight 0.125-point updates still produce one point (also across an end marker).
class ScrollPointAccumulator {
    std::int64_t remainder[2]{};
    bool active[2]{};
public:
    // Quartz scroll phase values, kept portable for unit tests.
    unsigned phase(int axis, bool ended) {
        if (ended) { active[axis]=false; return 4; }
        const unsigned result=active[axis]?2:1;
        active[axis]=true;return result;
    }
    std::int32_t take(int axis, std::int32_t milli_points) {
        auto total=remainder[axis]+milli_points;
        const auto points=total/1000;
        remainder[axis]=total%1000;
        return static_cast<std::int32_t>(points);
    }
};
inline constexpr int scroll_from_wayland(int amount) { return -amount; }
inline constexpr int scroll_from_windows(bool horizontal, int amount) { return horizontal ? -amount : amount; }
}

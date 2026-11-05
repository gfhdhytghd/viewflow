#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <map>
#include <vector>

namespace viewflow::macos {
struct SpaceWindow {
    uint64_t id;
    double x, y, width, height;
    uint32_t display;
};
// Metadata-only admission gate. It never owns or closes a capture/session.
class SpaceTransitionGate {
    std::map<uint64_t, SpaceWindow> previous;
    std::map<uint32_t, uint64_t> spaces;
    double until = 0;
public:
    static constexpr double settle_seconds = .25;
    bool observe(double now, bool animating, bool notified,
                 const std::map<uint32_t, uint64_t>& current_spaces,
                 const std::vector<SpaceWindow>& windows, bool geometry_sample = true) {
        bool changed = false;
        for (const auto& [display, space] : current_spaces) {
            auto old = spaces.find(display);
            changed |= space && old != spaces.end() && old->second && old->second != space;
        }
        spaces = current_spaces;
        struct Motion { uint32_t display; double dx; };
        std::vector<Motion> motions;
        for (const auto& w : windows) {
            const auto old = previous.find(w.id);
            if (old == previous.end()) continue;
            const auto& p = old->second;
            const double dx = w.x - p.x;
            if (w.display == p.display && std::abs(dx) >= 2 && std::abs(w.y-p.y) <= 2 &&
                std::abs(w.width-p.width) <= 2 && std::abs(w.height-p.height) <= 2)
                motions.push_back({w.display, dx});
        }
        bool coherent = false;
        for (const auto& m : motions) {
            coherent |= std::count_if(motions.begin(), motions.end(), [&](const auto& other) {
                return m.display == other.display && std::abs(m.dx-other.dx) <= 2;
            }) >= 3;
        }
        if (geometry_sample) {
            previous.clear();
            for (const auto& w : windows) previous.emplace(w.id, w);
        }
        if (animating || notified || changed || coherent) until = now + settle_seconds;
        return now < until;
    }
};
}

#pragma once

#include <algorithm>
#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <tuple>
#include <utility>
#include <vector>

namespace viewflow::activity {

// Scheduling state only: observing an event never activates a native window,
// authorizes input, changes its destination, or ends a connection.
// Callers serialize access and supply monotonic microseconds.
template<class Id> class Priority {
    struct Window {
        Id owner{};
        std::set<std::pair<unsigned, std::uint64_t>> held;
        std::uint64_t interaction{}, until{};
    };
    std::map<Id, Window> windows_;
    std::vector<Id> focus_history_;
    std::uint64_t sequence_{};
    Id root(Id id) const {
        std::set<Id> visited;
        while (visited.insert(id).second) {
            const auto it = windows_.find(id);
            if (it == windows_.end()) return {};
            if (it->second.owner == Id{} || !windows_.contains(it->second.owner)) return id;
            id = it->second.owner;
        }
        return {}; // A malformed owner cycle cannot win scheduling priority.
    }
public:
    static constexpr std::uint64_t grace_us = 500'000;
    Id owner_root(Id id) const { return root(id); }
    bool belongs(Id id, Id owner) const { return owner!=Id{} && root(id)==owner; }
    void membership(const std::vector<std::pair<Id, Id>>& visible) {
        std::set<Id> present;
        for (const auto& [id, owner] : visible) if (id != Id{}) {
            present.insert(id); windows_[id].owner = owner;
        }
        std::erase_if(windows_, [&](const auto& entry) { return !present.contains(entry.first); });
        std::erase_if(focus_history_, [&](Id id) { return !present.contains(id); });
    }
    void focus(Id id) {
        id = root(id); if (id == Id{}) return;
        std::erase(focus_history_, id); focus_history_.push_back(id);
    }
    Id last_focus() const { return focus_history_.empty() ? Id{} : focus_history_.back(); }
    void impulse(Id id, std::uint64_t now) {
        id = root(id); if (id == Id{}) return;
        auto& window = windows_.at(id);
        window.interaction = ++sequence_; window.until = now + grace_us;
    }
    void hold(Id id, unsigned kind, std::uint64_t token, bool down, std::uint64_t now) {
        id = root(id); if (id == Id{}) return;
        auto& window = windows_.at(id);
        if (down) window.held.emplace(kind, token);
        else window.held.erase({kind, token});
        impulse(id, now);
    }
    void release(Id id, std::uint64_t now) {
        if (id != Id{} && root(id) == Id{}) return;
        id = root(id);
        for (auto& [candidate, window] : windows_) if (id == Id{} || candidate == id) {
            if (!window.held.empty()) { window.held.clear(); window.until = now + grace_us; }
        }
    }
    Id interacting(std::uint64_t now) const {
        Id selected{}; std::uint64_t newest{};
        for (const auto& [id, window] : windows_)
            if ((!window.held.empty() || now < window.until) && window.interaction > newest) {
                newest = window.interaction; selected = id;
            }
        return selected;
    }
    Id preferred(std::uint64_t now) const {
        const auto active = interacting(now); return active == Id{} ? last_focus() : active;
    }
    unsigned rank(Id id, std::uint64_t now) const {
        id = root(id); if (id == Id{}) return 2;
        const auto active = interacting(now);
        if (active != Id{} && id == active) return 0;
        return id == last_focus() ? (active == Id{} ? 0u : 1u) : 2u;
    }
};

// Two refresh periods are a congestion measurement, never a validity cutoff.
class Congestion {
    std::uint64_t sample_start_{}, normal_since_{};
    unsigned bad_samples_{}, level_{};
    bool sampled_{}, bad_{};
public:
    bool observe(std::uint64_t now, std::uint64_t queue_us, bool saturated, unsigned fps) {
        if (!sampled_) { sample_start_ = now; sampled_ = true; }
        bad_ |= saturated || queue_us > 2'000'000 / std::max(1u, fps);
        if (now - sample_start_ < 250'000) return false;
        const auto previous = level_;
        if (bad_) {
            normal_since_ = 0;
            if (++bad_samples_ >= 3) { level_ = std::min(3u, level_ + 1); bad_samples_ = 0; }
        } else {
            bad_samples_ = 0;
            if (!normal_since_) normal_since_ = now;
            if (level_ && now - normal_since_ >= 2'000'000) { --level_; normal_since_ = now; }
        }
        sample_start_ = now; bad_ = false; return previous != level_;
    }
    unsigned level() const { return level_; }
    unsigned background_fps(unsigned target) const {
        constexpr unsigned limits[]{0, 30, 15, 5};
        return level_ ? std::min(target, limits[level_]) : target;
    }
};

// Order source work without changing atlas allocations or proxy stacking.
template<class Tile> std::vector<const Tile*> ordered_tiles(const std::vector<Tile>& tiles,
    std::uint64_t preferred, std::uint64_t focus) {
    std::vector<const Tile*> order;order.reserve(tiles.size());
    for(const auto& tile:tiles)order.push_back(&tile);
    auto belongs=[&](const Tile* tile,std::uint64_t owner){
        if(!owner)return false;
        auto id=tile->id;
        for(std::size_t steps=0;id && steps<=tiles.size();++steps){
            if(id==owner)return true;
            const auto found=std::find_if(tiles.begin(),tiles.end(),[&](const auto& candidate){return candidate.id==id;});
            if(found==tiles.end())return false;
            id=found->owner;
        }
        return false;
    };
    auto rank=[&](const Tile* tile){
        if(belongs(tile,preferred))return 0u;
        if(belongs(tile,focus))return 1u;
        return 2u;
    };
    std::stable_sort(order.begin(),order.end(),[&](const auto* a,const auto* b){return rank(a)<rank(b);});
    return order;
}

// A single encoder still gives the preferred window its target cadence.
// Other tiles join only when their background budget is due; skipped tiles
// remain visible through the connection-wide membership manifest.
class SingleLaneBudget {
    std::optional<std::uint64_t> background_;
public:
    bool background_due(std::uint64_t now, unsigned fps) const {
        const auto period=std::min<std::uint64_t>(200'000,1'000'000/std::max(1u,fps));
        return !background_ || now>=*background_+period;
    }
    void submitted_background(std::uint64_t now) { background_=now; }
};

// Fair selection among dirty windows. This bounds scheduling opportunities,
// not hardware completion time. No cached pixels get a fresh capture time.
template<class Id> class FairQueue {
    std::map<Id, std::uint64_t> serviced_;
    Id last_{};
public:
    std::optional<Id> next(const std::vector<Id>& ready, const Priority<Id>& priority, std::uint64_t now) {
        std::erase_if(serviced_, [&](const auto& item) { return std::find(ready.begin(), ready.end(), item.first) == ready.end(); });
        for (auto id : ready) serviced_.try_emplace(id, now);
        std::optional<Id> best;
        auto score = [&](Id id) {
            const auto found = serviced_.find(id);
            const auto age = found == serviced_.end() ? now : now - found->second;
            return std::tuple{age >= 200'000 ? 0u : 1u, age >= 200'000 ? 0u : priority.rank(id, now),
                              found == serviced_.end() ? std::uint64_t{} : found->second, id <= last_, id};
        };
        for (auto id : ready) if (!best || score(id) < score(*best)) best = id;
        return best;
    }
    void submitted(Id id, std::uint64_t now) { serviced_[id] = now; last_ = id; }
};
} // namespace viewflow::activity

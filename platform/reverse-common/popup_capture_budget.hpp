#pragma once
#include <cstdint>
#include <set>

namespace viewflow::reverse {
// One in-flight capture pair and at most 30 pairs/sec across all menus in a
// source. Round-robin admission prevents a parent menu starving its submenu.
class PopupCaptureBudget {
    std::set<std::uint64_t> owners;
    std::uint64_t previous{};
    double next{};
    bool busy{};
public:
    static constexpr unsigned frames_per_second = 30;
    void add(std::uint64_t id){owners.insert(id);}
    void remove(std::uint64_t id){owners.erase(id);}
    bool begin(std::uint64_t id,double now){
        if(busy || now<next || owners.empty())return false;
        auto candidate=owners.upper_bound(previous);
        if(candidate==owners.end())candidate=owners.begin();
        if(*candidate!=id)return false;
        previous=id;next=now+1.0/frames_per_second;busy=true;return true;
    }
    void complete(){busy=false;}
};
}

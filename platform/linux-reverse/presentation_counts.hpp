#pragma once
#include <algorithm>
#include <cstdint>
#include <map>
#include <string>
#include <unordered_set>
namespace viewflow::reverse {
// One row per proxy, never a sum of atlas copies presented by many proxies.
struct PresentationCounts {
    struct Window {
        std::uint64_t requested{},presented{},discarded{},invalid{},untracked{},duplicate_pts{},first_ns{},last_ns{};
        std::unordered_set<std::int64_t> source_pts;
        std::string output;
        void present(std::int64_t pts,std::uint64_t ns,bool valid,const std::string& where) {
            ++presented;
            if(!valid){++invalid;return;}
            if(output.empty())output=where;else if(output!=where)output="mixed";
            if(!first_ns || ns<first_ns)first_ns=ns;
            last_ns=std::max(last_ns,ns);
            if(!source_pts.insert(pts).second)++duplicate_pts;
        }
        double feedback_fps() const {
            return last_ns>first_ns?double(presented-invalid-1)*1e9/double(last_ns-first_ns):0;
        }
        double unique_source_fps() const {
            return last_ns>first_ns && !source_pts.empty()?double(source_pts.size()-1)*1e9/double(last_ns-first_ns):0;
        }
    };
    std::map<std::uint64_t,Window> windows;
    std::uint64_t interval_begin{};
    void begin(std::uint64_t now) {if(!interval_begin)interval_begin=now;}
    bool due(std::uint64_t now) const {return interval_begin && now>=interval_begin && now-interval_begin>=20000000000ULL;}
    void clear(std::uint64_t now) {windows.clear();interval_begin=now;}
};
}

#pragma once
#include "atlas_record.h"
#include <algorithm>
#include <limits>
#include <map>
#include <span>
#include <stdexcept>
#include <tuple>
#include <vector>

namespace viewflow::windows_preview {
struct CoalescedSparsePatches {
  std::vector<vfgp::AtlasPatch> patches;
  std::vector<uint8_t> opaque;
};
// Presentation-only union of adjacent rectangles with identical source-to-atlas
// translation and backdrop disposition. Wire layouts/input lineage stay intact.
// Overlapping source rectangles retain their original painter order unchanged.
inline CoalescedSparsePatches CoalesceSparsePatches(
    std::span<const vfgp::AtlasPatch> patches, std::span<const uint8_t> opaque={}) {
  if(!opaque.empty() && opaque.size()!=patches.size())throw std::runtime_error("sparse opacity count");
  CoalescedSparsePatches original{{patches.begin(),patches.end()},{opaque.begin(),opaque.end()}};
  if(patches.size()<2)return original;
  for(size_t i=0;i<patches.size();++i) {
    const auto& a=patches[i];
    const auto limit=std::numeric_limits<uint32_t>::max();
    if(!a.width || !a.height || uint64_t(a.source_x)+a.width>limit ||
       uint64_t(a.source_y)+a.height>limit || uint64_t(a.x)+a.width>limit ||
       uint64_t(a.y)+a.height>limit)return original;
  }
  struct Entry { vfgp::AtlasPatch patch; uint8_t opacity; size_t first; };
  std::vector<Entry> entries;entries.reserve(patches.size());
  for(size_t i=0;i<patches.size();++i)entries.push_back({patches[i],opaque.empty()?uint8_t(0):opaque[i],i});
  // Same sweep used by the wire parser: active x intervals are disjoint at
  // this y, so checking the two neighbours detects every source overlap.
  // This also keeps the manual helper bounded for the 32K-patch wire limit.
  std::sort(entries.begin(),entries.end(),[](const Entry& a,const Entry& b) {
    return std::tuple{a.patch.tile_index,a.patch.source_y,a.patch.source_x}<
        std::tuple{b.patch.tile_index,b.patch.source_y,b.patch.source_x};
  });
  std::map<uint32_t,uint64_t> active_x;
  std::multimap<uint64_t,uint32_t> expiry_y;
  uint32_t tile=entries.front().patch.tile_index;
  for(const auto& entry:entries) {
    const auto& p=entry.patch;
    if(p.tile_index!=tile) { active_x.clear();expiry_y.clear();tile=p.tile_index; }
    while(!expiry_y.empty() && expiry_y.begin()->first<=p.source_y) {
      active_x.erase(expiry_y.begin()->second);expiry_y.erase(expiry_y.begin());
    }
    const auto right=uint64_t(p.source_x)+p.width;
    const auto next=active_x.lower_bound(p.source_x);
    if(next!=active_x.end() && next->first<right)return original;
    if(next!=active_x.begin() && std::prev(next)->second>p.source_x)return original;
    active_x.emplace(p.source_x,right);expiry_y.emplace(uint64_t(p.source_y)+p.height,p.source_x);
  }
  auto group=[](const Entry& e) {
    const auto& p=e.patch;
    return std::tuple{p.tile_index,int64_t(p.x)-p.source_x,int64_t(p.y)-p.source_y,e.opacity};
  };
  for(bool horizontal:{true,false}) {
    auto axis=[&](const Entry& e) {
      const auto& p=e.patch;
      return horizontal?std::tuple{p.source_y,p.height,p.source_x}:std::tuple{p.source_x,p.width,p.source_y};
    };
    std::sort(entries.begin(),entries.end(),[&](const Entry& a,const Entry& b) {
      return std::tuple{group(a),axis(a)}<std::tuple{group(b),axis(b)};
    });
    size_t count=0;
    for(const auto current:entries) {
      if(count) {
        auto& last=entries[count-1];auto& p=last.patch;const auto& q=current.patch;
        const bool adjacent=horizontal?
            p.source_y==q.source_y && p.height==q.height && uint64_t(p.source_x)+p.width==q.source_x:
            p.source_x==q.source_x && p.width==q.width && uint64_t(p.source_y)+p.height==q.source_y;
        if(group(last)==group(current) && adjacent) {
          if(horizontal)p.width+=q.width;else p.height+=q.height;
          last.first=std::min(last.first,current.first);continue;
        }
      }
      entries[count++]=current;
    }
    entries.resize(count);
  }
  std::sort(entries.begin(),entries.end(),[](const Entry& a,const Entry& b){return a.first<b.first;});
  CoalescedSparsePatches result;result.patches.reserve(entries.size());
  if(!opaque.empty())result.opaque.reserve(entries.size());
  for(const auto& e:entries) {
    result.patches.push_back(e.patch);
    if(!opaque.empty())result.opaque.push_back(e.opacity);
  }
  return result;
}
} // namespace viewflow::windows_preview

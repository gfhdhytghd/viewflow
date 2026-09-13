#pragma once
#include "../reverse-common/wire.hpp"
#include <algorithm>
#include <map>
#include <tuple>
namespace viewflow::reverse {
// Skip only unchanged content AND unchanged window metadata. A periodic
// unchanged refresh is allowed; no capture age terminates a window/session.
class FrameChangeTracker {
 public:
  using Versions=std::map<std::uint64_t,std::uint64_t>;
  bool needs_frame(const std::vector<Tile>& tiles,const Versions& versions,bool keyframe,bool refresh) const {
    if(keyframe || refresh || versions!=versions_ || tiles.size()!=tiles_.size())return true;
    return !std::equal(tiles.begin(),tiles.end(),tiles_.begin(),[](const Tile& a,const Tile& b){
      const auto fields=[](const Tile& t){return std::tie(t.id,t.owner,t.x,t.y,t.width,t.height,t.atlas_x,t.atlas_y,t.title,t.flags,t.geometry_ack,t.grab_x,t.grab_y);};
      return fields(a)==fields(b);
    });
  }
  // Commit only the versions actually copied/submitted, after input acceptance.
  // A newer callback version arriving in the meantime remains pending work.
  void submitted(const std::vector<Tile>& tiles,Versions versions){tiles_=tiles;versions_=std::move(versions);}
 private:
  std::vector<Tile> tiles_;
  Versions versions_;
};
}

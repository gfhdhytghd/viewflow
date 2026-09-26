#pragma once
#include "wire.hpp"
#include <set>
#include <map>
namespace viewflow::activity {
// Shared proxy lifetime across independent decoder lanes. Decode old epochs to
// maintain codec references, but never let them overwrite a migrated proxy.
class Presentation {
    std::uint64_t epoch_{};
    std::set<std::uint64_t> members_;
    std::map<std::uint64_t,std::uint64_t> owners_;
public:
    bool admit(const reverse::Frame& frame) {
        if(!frame.activity_epoch)return true;
        if(frame.activity_epoch<epoch_)return false;
        epoch_=frame.activity_epoch;
        members_={frame.activity_members.begin(),frame.activity_members.end()};
        std::erase_if(owners_,[&](const auto& item){return !members_.contains(item.first);});
        for(const auto& tile:frame.tiles)if(members_.contains(tile.id))owners_[tile.id]=tile.owner;
        return true;
    }
    bool accepts(const reverse::Frame& frame,const reverse::Tile& tile)const {
        if(!frame.activity_epoch)return true;
        bool preferred=false;
        auto id=tile.id;std::set<std::uint64_t> visited;
        while(frame.activity_preferred && id && visited.insert(id).second){
            if(id==frame.activity_preferred){preferred=true;break;}
            const auto found=owners_.find(id);if(found==owners_.end())break;
            id=found->second;
        }
        return members_.contains(tile.id) && (frame.activity_lane==1)==preferred;
    }
    std::set<std::uint64_t> members(const reverse::Frame& frame)const {
        if(frame.activity_epoch)return members_;
        std::set<std::uint64_t> result;for(const auto& tile:frame.tiles)result.insert(tile.id);return result;
    }
};
}

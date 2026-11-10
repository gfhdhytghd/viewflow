#pragma once
#include <nlohmann/json.hpp>
#include <algorithm>

namespace viewflow::reverse {
inline bool outbound_parking_monitor(const nlohmann::json& monitor) {
    const auto name=monitor.find("name"), workspace=monitor.find("activeWorkspace");
    return name!=monitor.end() && name->is_string() && (name->get<std::string>().starts_with("HEADLESS-") || name->get<std::string>().starts_with("viewflow-")) &&
        workspace!=monitor.end() && workspace->is_object() && workspace->contains("name") && (*workspace)["name"].is_string() &&
        (*workspace)["name"].get<std::string>().starts_with("viewflow-");
}
// A parking-only snapshot does not describe the destination viewport. During
// connector re-probing, retain the previous demand instead of publishing zero.
inline bool has_destination_monitor(const nlohmann::json& monitors) {
    return monitors.is_array() && std::any_of(monitors.begin(),monitors.end(),[](const auto& monitor){return !outbound_parking_monitor(monitor);});
}
inline const nlohmann::json* initial_workspace_monitor(const nlohmann::json& monitors,int x,int y,int width,int height) {
    const nlohmann::json* chosen=nullptr;double best=-1e100;
    for(const auto& monitor:monitors) {
        if(outbound_parking_monitor(monitor))continue;
        const double scale=monitor.value("scale",1.0),mx=monitor.at("x"),my=monitor.at("y");
        const bool rotated=monitor.value("transform",0)%2!=0;
        const double mw=monitor.at(rotated?"height":"width").get<double>()/scale,mh=monitor.at(rotated?"width":"height").get<double>()/scale;
        const double area=std::max(0.,std::min(double(x+width),mx+mw)-std::max(double(x),mx))*std::max(0.,std::min(double(y+height),my+mh)-std::max(double(y),my));
        const double cx=x+width*.5,cy=y+height*.5,dx=cx-std::clamp(cx,mx,mx+mw),dy=cy-std::clamp(cy,my,my+mh);
        const double score=area>0?area:-(dx*dx+dy*dy);
        if(!chosen || score>best){chosen=&monitor;best=score;}
    }
    return chosen;
}
// Only known destination invisibility releases pixels. Unknown compositor
// metadata retains demand, and a visible spanning window keeps all monitors.
inline bool workspace_visible(const nlohmann::json& client, const nlohmann::json& monitors) {
    const auto hidden=client.find("hidden");
    if(hidden!=client.end() && hidden->is_boolean() && hidden->get<bool>())return false;
    const auto pinned=client.find("pinned");
    if(pinned==client.end() || !pinned->is_boolean() || pinned->get<bool>())return true;
    const auto workspace=client.find("workspace");
    if(workspace==client.end() || !workspace->is_object() || !workspace->contains("id") || !(*workspace)["id"].is_number_integer())return true;
    const int id=(*workspace)["id"];
    if(!id || !monitors.is_array() || monitors.empty())return true;
    bool unknown=false;
    for(const auto& monitor:monitors) {
        for(const char* field:{"activeWorkspace","specialWorkspace"}) {
            const auto active=monitor.find(field);
            if(active==monitor.end() || !active->is_object() || !active->contains("id") || !(*active)["id"].is_number_integer()) { unknown=true;continue; }
            if((*active)["id"].get<int>()==id)return true;
        }
    }
    return unknown;
}
}

#include "workspace_visibility.hpp"
#include <cassert>
using nlohmann::json;
int main() {
    auto destinations=json::array({json{{"name","DP-4"},{"x",0},{"y",0},{"width",3072},{"height",1728},{"scale",1}},json{{"name","HEADLESS-2"},{"x",3072},{"y",1590},{"width",3072},{"height",1728},{"scale",1},{"activeWorkspace",{{"name","viewflow-macos"}}}}});
    assert(viewflow::reverse::initial_workspace_monitor(destinations,2609,1730,1357,809)==&destinations[0]);
    assert(viewflow::reverse::initial_workspace_monitor(destinations,2900,1600,400,400)==&destinations[0]);
    assert(viewflow::reverse::has_destination_monitor(destinations));
    destinations.erase(destinations.begin());
    assert(!viewflow::reverse::has_destination_monitor(destinations));
    assert(!viewflow::reverse::has_destination_monitor(json::array()));
    assert(!viewflow::reverse::has_destination_monitor(nullptr));
    assert(viewflow::reverse::initial_workspace_monitor(destinations,2609,1730,1357,809)==nullptr);
    auto client=json{{"workspace",{{"id",2}}},{"pinned",false},{"hidden",false}};
    auto monitors=json::array({json{{"activeWorkspace",{{"id",1}}},{"specialWorkspace",{{"id",0}}}},json{{"activeWorkspace",{{"id",2}}},{"specialWorkspace",{{"id",-99}}}}});
    using viewflow::reverse::workspace_visible;
    assert(workspace_visible(client,monitors));
    auto parking=json{{"name","HEADLESS-2"},{"activeWorkspace",{{"id",-1338},{"name","viewflow-macos"}}}};
    assert(viewflow::reverse::outbound_parking_monitor(parking));
    parking["name"]="DP-4";assert(!viewflow::reverse::outbound_parking_monitor(parking));
    parking["name"]="HEADLESS-2";parking["activeWorkspace"]["name"]="testing";
    assert(!viewflow::reverse::outbound_parking_monitor(parking));
    monitors[0]["activeWorkspace"]["id"]=-1337;client["workspace"]["id"]=-1337;assert(workspace_visible(client,monitors));
    client["workspace"]["id"]=3;assert(!workspace_visible(client,monitors));
    client["pinned"]=true;assert(workspace_visible(client,monitors));
    client["hidden"]=true;assert(!workspace_visible(client,monitors));
    client["hidden"]=false;client["pinned"]=false;
    client["workspace"]["id"]=-99;assert(workspace_visible(client,monitors));
    client["workspace"]["id"]=-98;assert(!workspace_visible(client,monitors));
    monitors[0].erase("specialWorkspace");assert(workspace_visible(client,monitors));
    assert(workspace_visible(client,json::array()));
    client.erase("workspace");assert(workspace_visible(client,monitors));
    client["workspace"]={{"id",3}};client.erase("pinned");assert(workspace_visible(client,monitors));
}

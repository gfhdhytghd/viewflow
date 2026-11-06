#include "touchpad_routing.hpp"
#include <cassert>
using namespace viewflow::reverse;
int main() {
    for(auto source:{"linux","windows","macos",""})for(bool ready:{false,true}) {
        assert(raw_touchpad_supported(true,ready,source)==
            (ready && (std::string_view(source)=="macos" || std::string_view(source).empty())));
        assert(raw_touchpad_supported(false,ready,source)==(std::string_view(source)=="windows"));
    }
    // Linux/unknown peers always keep wheel fallback; Mac waits for flag 8.
    assert(!raw_touchpad_supported(false,true,"linux"));
    assert(!raw_touchpad_supported(true,false,"macos"));
}

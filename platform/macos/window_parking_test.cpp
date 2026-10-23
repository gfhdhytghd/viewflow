#include "../reverse-common/window_scope.hpp"
#include <cassert>
using namespace viewflow::reverse;
int main() {
    const ScopeRect linux{-3072,-1590,3072,1728}, windows{0,-1200,1920,1200};
    const ScopeRect source{-1398,-1215,920,436};
    for (const auto& order : std::vector<std::vector<ScopeRect>>{{linux,windows},{windows,linux}}) {
        const auto kept=parking_position(source,order);
        assert(kept.x==source.x && kept.y==source.y);
        const auto other=parking_position({100,-1100,800,600},order);
        assert(other.x==100 && other.y==-1100);
    }
}

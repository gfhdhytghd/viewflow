#include "work_area.hpp"
#include "work_area_math.hpp"
#include <cassert>
using namespace viewflow::reverse;
int main() {
    const auto insets=visibleInsets({-1920,0,1920,1200},{-1860,20,1860,1142},{38,0,0,0});
    assert((insets==std::array<double,4>{38,0,20,60}));
    const auto screen=projectScreen({-1920,-200,1920,1200},1200,-4992,-499,2);
    assert(screen.x==6144 && screen.y==1398 && screen.width==3840 && screen.height==2400);
    assert(overlap({3072,699,1920,1200},{screen.x/2,screen.y/2,screen.width/2,screen.height/2})==1920*1200);
    ConstraintGeometry geometry;
    std::array<int64_t,4> requested{0,0,800,600},actual{0,76,800,600};
    assert(geometry.observe(requested,actual,1));
    for(int i=0;i<10000;++i) {
        assert(geometry.suppress(requested,actual,1));
        assert(!geometry.observe(requested,actual,1));
    }
    assert(!geometry.suppress(requested,{100,76,800,600},1)); // proxy-first local drag
    assert(geometry.observe(requested,actual,2)); // changed work area permits one new correction
    assert(!geometry.observe(actual,actual,2)); // source accepts authoritative geometry
    assert(!geometry.suppress(requested,actual,2));
    WorkAreaUpdates updates;
    std::vector<WorkAreaDisplay> displays{{42,{6144,598,3840,2400,76,0,120,0}}};
    assert(updates.changed(displays,"dock=a"));
    updates.commit(displays,"dock=a");assert(updates.revision==1);
    assert(!updates.changed(displays,"dock=a"));
    assert(updates.changed(displays,"dock=b")); // auto-hide/magnification prefs change
    displays[0].values[6]=0;assert(updates.changed(displays,"dock=a"));
    updates.commit(displays,"dock=b");assert(updates.revision==2);
    const auto bytes=pack_work_areas(updates.revision,displays);assert(bytes.size()==96);
}

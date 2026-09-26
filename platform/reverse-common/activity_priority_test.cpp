#include "activity_input.hpp"
#include <cassert>
#include <cstdio>

using viewflow::activity::Priority;
int main() {
    Priority<unsigned> p;
    p.membership({{1,0},{2,0},{3,1}}); p.focus(1);
    assert(p.preferred(1) == 1);
    p.impulse(2, 10); // Scrolling an unfocused window must not change focus.
    assert(p.preferred(10) == 2 && p.last_focus() == 1);
    assert(p.rank(1,10) == 1 && p.rank(3,10) == 1);
    assert(p.preferred(500'010) == 1);
    p.hold(2, 1, 272, true, 600'000);
    assert(p.preferred(5'000'000) == 2); // Long drag outlives grace.
    p.hold(2, 1, 272, false, 5'000'000);
    assert(p.preferred(5'499'999) == 2 && p.preferred(5'500'000) == 1);
    p.impulse(3, 6'000'000); assert(p.interacting(6'000'000) == 1);
    p.focus(2); p.membership({{1,0},{3,1}}); assert(p.last_focus() == 1);
    Priority<unsigned> other; other.membership({{1,0},{2,0}}); other.focus(2);
    assert(other.last_focus() == 2 && p.last_focus() == 1);
    p.membership({{1,0},{2,0},{3,1}});
    p.hold(1,2,30,true,7'000'000); p.hold(2,2,31,true,7'000'001);
    assert(p.interacting(8'000'000) == 2);
    p.release(2,8'000'000); assert(p.interacting(8'500'000) == 1);
    p.release(0,8'500'000); assert(p.interacting(9'000'000) == 0);
    viewflow::activity::Congestion pressure;
    for (unsigned i=0;i<4;++i) pressure.observe(1+i*250'000,40'000,false,60);
    assert(pressure.background_fps(60) == 30);
    for (unsigned i=4;i<7;++i) pressure.observe(1+i*250'000,0,true,60);
    assert(pressure.background_fps(60) == 15);
    for (unsigned i=7;i<17;++i) pressure.observe(1+i*250'000,0,false,60);
    assert(pressure.background_fps(60) == 30);
    viewflow::activity::FairQueue<unsigned> q;
    p = Priority<unsigned>{}; p.membership({{1,0},{2,0}});
    q.submitted(1,1);q.submitted(2,1);p.focus(1);
    assert(q.next({1,2},p,10) == 1);q.submitted(1,200'001);
    assert(q.next({1,2},p,200'002) == 2);
    Priority<std::uint64_t> input; input.membership({{1,0},{2,0}}); input.focus(1);
    viewflow::activity::observe(input,{2,1,viewflow::reverse::InputKind::pointer,0,0,0,0},1);
    assert(input.preferred(1)==1 && input.interacting(1)==0);
    viewflow::activity::observe(input,{2,2,viewflow::reverse::InputKind::wheel,0,120,0,0},2);
    assert(input.preferred(2)==2 && input.last_focus()==1);
    struct Tile {std::uint64_t id,owner;};
    const std::vector<Tile> tiles{{9,0},{2,0},{3,1},{1,0}};
    const auto ordered=viewflow::activity::ordered_tiles(tiles,2,1);
    assert(ordered[0]->id==2 && ordered[1]->id==3 && ordered[2]->id==1 && ordered[3]->id==9);
    assert(tiles[0].id==9 && tiles[1].id==2);
    Priority<unsigned> nested;nested.membership({{1,0},{3,1},{4,3}});nested.focus(4);
    assert(nested.last_focus()==1 && nested.belongs(4,1) && nested.owner_root(4)==1);
    viewflow::activity::SingleLaneBudget single;
    assert(single.background_due(1,5));single.submitted_background(1);
    for(unsigned tick=1;tick<12;++tick)assert(!single.background_due(1+tick*16'666,5));
    assert(single.background_due(200'001,5));
    single.submitted_background(200'001);
    assert(!single.background_due(216'667,30));
    assert(single.background_due(233'334,30));
    puts("activity priority: focus, interaction, grace, ownership, fairness and congestion passed");
}

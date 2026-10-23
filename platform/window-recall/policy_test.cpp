#include "policy.hpp"
#include "evdev_shortcut.hpp"
#include <cassert>
using namespace viewflow::recall;
int main() {
    auto s=parse_shortcut(default_shortcut);assert(s.letter=='H' && s.modifiers==7);
    assert(parse_shortcut("Control+Option+Shift+h")==s);
    assert(format_shortcut(s)==default_shortcut);
    for (auto bad : {"", "H", "Ctrl+", "Ctrl+Alt+H+J", "Ctrl+Ctrl+H", "Ctrl+F12"}) {
        bool failed=false;try {(void)parse_shortcut(bad);}catch(const std::invalid_argument&){failed=true;}assert(failed);
    }
    KeyLatch latch;assert(!latch.key(true,true,3,s).consume);
    auto hit=latch.key(true,true,7,s);assert(hit.consume&&hit.trigger);
    assert(!latch.key(true,true,7,s).trigger);
    assert(latch.key(true,false,0,s).consume); // modifier-up before H-up
    assert(!latch.key(true,false,0,s).consume);
    assert(!latch.key(true,true,15,s).consume); // exact chord, not Ctrl+Alt+Shift+Super+H
    EvdevShortcut keys;
    assert(!keys.key(29,true,s).consume);assert(!keys.key(97,true,s).consume);
    keys.key(56,true,s);keys.key(42,true,s);keys.key(29,false,s);
    assert(keys.key(35,true,s).trigger);assert(!keys.key(35,true,s).trigger);
    keys.key(97,false,s);assert(keys.key(35,false,s).consume);
    assert(!keys.key(35,true,s).consume);
    keys.reset();assert(!keys.key(35,true,s).consume);
    EvdevShortcut detach;
    const Shortcut detachChord{control|alt|shift,'D'};
    detach.key(97,true,detachChord);detach.key(100,true,detachChord);detach.key(54,true,detachChord);
    auto detached=detach.key(32,true,detachChord);assert(detached.trigger&&detached.consume);
    assert(!detach.key(32,true,detachChord).trigger);
    detach.key(97,false,detachChord);detach.key(100,false,detachChord);detach.key(54,false,detachChord);
    assert(detach.key(32,false,detachChord).consume);
    assert(!detach.key(32,true,detachChord).consume);
    std::vector<Rect> physical{{0,0,1920,1200},{-1920,0,1920,1080}};
    assert(!needs_recall({200,300,800,600},physical));
    assert(!needs_recall({-1800,200,800,600},physical));
    assert(needs_recall({0,2400,800,600},physical));
    assert(needs_recall({50000,50000,800,600},physical));
    assert(!needs_recall({50000,0,800,600},{})); // never move without a physical destination
    for (std::size_t i=0;i<200;++i) {
        auto r=placement({50000,50000,4000,3000},{-1920,24,1920,1056},i);
        assert(r.x==-1920&&r.y==24&&r.width==1920&&r.height==1056);
        r=placement({0,5000,800,600},{0,40,1920,1160},i);
        assert(r.x>=0&&r.y>=40&&r.x+r.width<=1920&&r.y+r.height<=1200);
    }
}

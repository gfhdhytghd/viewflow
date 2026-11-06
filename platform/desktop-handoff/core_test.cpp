#include "core.hpp"
#include "windows_keys.hpp"
#include "scroll.hpp"
#include "../reverse-common/scroll_units.hpp"
#include "../macos/window_keys.hpp"
#include <cassert>
namespace h=viewflow::handoff;
int main() {
    h::self_test();
    viewflow::reverse::ScrollPointAccumulator points;
    int total=0;for(int i=0;i<8;++i)total+=points.take(0,125);assert(total==1);
    assert(points.phase(0,false)==1 && points.phase(0,false)==2 && points.phase(0,true)==4);
    assert(viewflow::reverse::scroll_from_windows(true,120)==-120);
    h::ScrollAccumulator mac,win;
    int pixels=0,units=0;
    for(int i=0;i<10;++i){pixels+=mac.convert(0,100,true,false);units+=win.convert(0,100,true,true);}
    assert(pixels==1 && units==3);
    assert(mac.convert(1,120,false,false)==1 && win.convert(1,120,false,true)==120);
    assert(mac.convert(0,0,true,false)==0 && win.convert(0,0,true,true)==0);
    // Physical modifiers survive every Windows/Mac mapping direction.
    for(unsigned code:{29,97,42,54,56,100,125,126,119,183,194}) {
        const auto key=h::windows_scan(code);assert(key);
        assert(h::evdev_key(key->virtual_key,key->scan,key->extended)==code);
    }
    for(unsigned code:{29,97,42,54,56,100,125,126}) {
        auto mac=viewflow::macos::mac_key(code);assert(mac);
        assert(viewflow::macos::evdev_key(*mac)==code);
    }
    struct Case {h::Rect peer;double px,py,dx,dy,backx,backy;};
    for(auto c:{Case{{100,0,100,80},99,40,1,0,-2,0},Case{{-100,0,100,80},0,40,-1,0,2,0},
                Case{{0,80,100,80},40,79,0,1,0,-2},Case{{0,-80,100,80},40,0,0,-1,0,2}}) {
        h::Core core({0,0,100,80},c.peer);std::vector<h::Input> sent,posted;bool captured=false;
        core.send=[&](h::Input e){sent.push_back(e);};core.inject=[&](h::Input e){posted.push_back(e);};
        core.capture=[&](bool value){captured=value;};core.command(h::message(h::capabilities,1,1));
        core.input(h::message(4,29,1));core.input(h::message(2,272,1));
        core.motion(c.px,c.py,c.dx,c.dy);assert(h::kind(sent.back())==h::request);
        core.command(h::message(h::captured));assert(captured);
        assert(posted.size()==2 && posted[0].b==0 && posted[1].b==0);
        assert(sent.back().a==272 && sent.back().b==1);
        core.motion(c.px,c.py,c.backx,c.backy);assert(!captured);
        assert(h::kind(sent.back())==h::returned);
        const auto count=sent.size();core.motion(c.px,c.py,c.dx,c.dy);assert(sent.size()==count); // no ping-pong
        core.motion(50,40,-c.dx,-c.dy);core.motion(c.px,c.py,c.dx,c.dy);assert(sent.size()==count+1);
        core.command(h::message(h::entered));core.command(h::message(4,29,1));core.command(h::message(4,42,1));
        bool attempted_shift=false;
        core.inject=[&](h::Input e){if(e.a==29)throw std::runtime_error("fixture injection failure");if(e.a==42)attempted_shift=true;};
        try{core.reset();assert(false);}catch(const std::runtime_error&){}
        assert(attempted_shift && !core.outgoing && !core.incoming);
    }
}

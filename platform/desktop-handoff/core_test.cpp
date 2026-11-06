#include "core.hpp"
#include "windows_keys.hpp"
#include "scroll.hpp"
#include "service_wire.hpp"
#include "../reverse-common/scroll_units.hpp"
#include "../macos/window_keys.hpp"
#include <cassert>
namespace h=viewflow::handoff;
int main() {
    h::self_test();
    auto word=[](const h::ServiceRequest& b,size_t offset) {
        uint64_t v=0;for(unsigned i=0;i<8;++i)v|=uint64_t(b[offset+i])<<(i*8);return v;
    };
    const h::Rect display{-100,20,100,80};
    auto position=h::service_input(h::message(1,27000,30000),display,1.5,1.5);
    assert(position[4]==1 && position[5]==0);
    assert(int64_t(word(position,8))==-109500 && word(position,16)==75000);
    for(auto [code,usage]:{std::pair{29,0xe0},std::pair{97,0xe4},std::pair{42,0xe1},
        std::pair{54,0xe5},std::pair{56,0xe2},std::pair{100,0xe6},std::pair{125,0xe3},std::pair{126,0xe7}}) {
        for(int down:{0,1,2}) {
            auto b=h::service_input(h::message(4,code,down),display,1,1);
            assert(b[4]==5 && word(b,8)==(7u|(uint64_t(usage)<<16)));
            assert(word(b,16)==uint64_t(down==2?3:down));
        }
    }
    for(auto [code,button]:{std::pair{272,0},std::pair{273,2},std::pair{274,1},std::pair{275,3},std::pair{276,4}}) {
        auto b=h::service_input(h::message(2,code,1),display,1,1);
        assert(b[4]==4 && word(b,8)==unsigned(button) && word(b,16)==1);
    }
    auto wheel=h::service_input(h::message(3,0,120),display,1,1);
    assert(std::bit_cast<double>(word(wheel,8))==1.0);
    wheel=h::service_input(h::message(3,1,1000,1),display,1,1);
    assert(std::bit_cast<double>(word(wheel,16))==-0.025);
    try {h::service_input(h::message(4,9999,1),display,1,1);assert(false);}
    catch(const std::runtime_error&) {}

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
        // A native interior placement followed by one accelerated edge event
        // must capture on every edge, without a physical interior sample.
        core.observe_position(50,40);core.reset();
        const auto accelerated=sent.size();
        core.motion(c.px,c.py,c.dx*50,c.dy*40);
        assert(sent.size()==accelerated+1 && h::kind(sent.back())==h::request);
        core.command(h::message(h::entered));core.command(h::message(4,29,1));core.command(h::message(4,42,1));
        bool attempted_shift=false;
        core.inject=[&](h::Input e){if(e.a==29)throw std::runtime_error("fixture injection failure");if(e.a==42)attempted_shift=true;};
        try{core.reset();assert(false);}catch(const std::runtime_error&){}
        assert(attempted_shift && !core.outgoing && !core.incoming);
        core.receivedKeys={29};core.receivedButtons={272};core.outgoing=true;
        core.capture=[](bool){throw std::runtime_error("fixture cursor restoration failure");};
        posted.clear();core.inject=[&](h::Input e){posted.push_back(e);};
        try{core.reset();assert(false);}catch(const std::runtime_error&){}
        assert(posted.size()==2 && core.receivedKeys.empty() && core.receivedButtons.empty());
        assert(!core.pending && !core.outgoing && !core.incoming);
    }
}

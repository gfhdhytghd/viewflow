#pragma once
#include "../reverse-common/pipe_io.hpp"
#include <cmath>
#include <functional>
#include <set>
#include <cstdio>
#include <exception>

namespace viewflow::handoff {
using reverse::Input;
using reverse::InputKind;
// Private native pipe messages. Network ownership lives in vf-handoff-peer.
constexpr uint32_t request=100, returned=101, capabilities=102, fault=103;
constexpr uint32_t captured=200, entered=201, released=202;
inline Input message(uint32_t kind, int a=0, int b=0, int c=0, int d=0) {
    return {1,1,static_cast<InputKind>(kind),a,b,c,d};
}
inline uint32_t kind(const Input& e) { return static_cast<uint32_t>(e.kind); }
inline Input decode(std::span<const uint8_t> bytes) {
    reverse::Reader r{bytes};
    if(r.u32()!=2) throw std::runtime_error("invalid handoff native record");
    Input e; e.id=r.u64(); e.sequence=r.u64(); e.kind=static_cast<InputKind>(r.u32());
    e.a=r.i32();e.b=r.i32();e.c=r.i32();e.d=r.i32();r.finish();return e;
}
struct Rect { double x{},y{},w{},h{}; };
enum class Edge { none, left, right, top, bottom };
inline Edge adjacent(Rect a, Rect b) {
    if(std::max(a.y,b.y)<std::min(a.y+a.h,b.y+b.h)) {
        if(a.x+a.w==b.x) return Edge::right;
        if(b.x+b.w==a.x) return Edge::left;
    }
    if(std::max(a.x,b.x)<std::min(a.x+a.w,b.x+b.w)) {
        if(a.y+a.h==b.y) return Edge::bottom;
        if(b.y+b.h==a.y) return Edge::top;
    }
    return Edge::none;
}
// All callbacks run on the native event thread. No timer or polling is needed.
struct Core {
    Rect local, remote;
    Edge edge;
    bool canSend=false;
    bool pending{}, outgoing{}, incoming{}, armed{true};
    double x{}, y{};
    double pointerX{}, pointerY{};
    bool havePointer{};
    std::set<int> physicalKeys, physicalButtons, receivedKeys, receivedButtons;
    std::function<void(Input)> send, inject;
    std::function<void(bool)> capture;
    Core(Rect l, Rect r):local(l),remote(r),edge(adjacent(l,r)) {
        if(l.w<2 || l.h<2 || r.w<2 || r.h<2 || edge==Edge::none)
            throw std::runtime_error("handoff requires adjacent logical display rectangles");
    }
    bool at_edge(double px,double py) const {
        if(edge==Edge::left || edge==Edge::right)
            return py>=std::max(local.y,remote.y) && py<std::min(local.y+local.h,remote.y+remote.h) &&
                (edge==Edge::left ? px<=local.x : px>=local.x+local.w-1);
        return px>=std::max(local.x,remote.x) && px<std::min(local.x+local.w,remote.x+remote.w) &&
            (edge==Edge::top ? py<=local.y : py>=local.y+local.h-1);
    }
    // Observation is never a capture request. Native warps and received
    // positions can rearm an interior cursor without waiting for another
    // physical sample there (acceleration can skip directly to the edge).
    void observe_position(double px,double py) {
        pointerX=px;pointerY=py;havePointer=true;
        if(!at_edge(px,py))armed=true;
    }
    void release_received() {
        std::exception_ptr failure;
        const auto release=[&](std::set<int>& held,uint32_t type) {
            for(auto i=held.begin();i!=held.end();) {
                try {inject(message(type,*i,0));i=held.erase(i);}
                catch(...) {failure=std::current_exception();++i;}
            }
        };
        release(receivedKeys,4);release(receivedButtons,2);
        if(failure)std::rethrow_exception(failure);
    }
    void reset() {
        std::exception_ptr failure;
        try {if(outgoing)capture(false);} catch(...) {failure=std::current_exception();}
        pending=outgoing=incoming=false;
        armed=havePointer && !at_edge(pointerX,pointerY);
        try {release_received();} catch(...) {failure=std::current_exception();}
        std::fprintf(stderr,"handoff released\n");
        if(failure)std::rethrow_exception(failure);
    }
    void command(Input e) {
        if(kind(e)==capabilities) {canSend=e.a!=0;return;}
        if(kind(e)==released) {reset();e.kind=static_cast<InputKind>(204);send(e);return;}
        if(kind(e)==captured) {
            pending=false;outgoing=true;incoming=false;capture(true);
            // Release local state before suppressing physical up events. Replay
            // held positions on the target, preserving modifiers and drag buttons.
            for(int k:physicalKeys) {inject(message(4,k,0));send(message(4,k,1));}
            for(int b:physicalButtons) {inject(message(2,b,0));send(message(2,b,1));}
            std::fprintf(stderr,"handoff captured\n");return;
        }
        if(kind(e)==entered) {
            reset();incoming=true;
            inject(message(1,e.a,e.b));
            observe_position(local.x+e.a/1000.0,local.y+e.b/1000.0);
            std::fprintf(stderr,"handoff entered\n");return;
        }
        if(!incoming) return;
        if(kind(e)==4) {if(e.b)receivedKeys.insert(e.a);else receivedKeys.erase(e.a);}
        if(kind(e)==2) {if(e.b)receivedButtons.insert(e.a);else receivedButtons.erase(e.a);}
        inject(e);
        if(kind(e)==1)observe_position(local.x+e.a/1000.0,local.y+e.b/1000.0);
    }
    bool motion(double px,double py,double dx,double dy,bool injected=false) {
        const bool moved=havePointer && (px!=pointerX || py!=pointerY);
        if(!outgoing) {
            observe_position(px,py);
            // A stationary sample at the return edge cannot recapture. A new
            // physical position can, even if no intermediate interior sample
            // was delivered. Injected movement only updates the observation.
            if(!injected && moved)armed=true;
        }
        if(injected || incoming || !canSend) return false;
        if(outgoing) {
            x+=dx;y+=dy;
            const bool back=(edge==Edge::right && x<0) || (edge==Edge::left && x>=remote.w) ||
                (edge==Edge::bottom && y<0) || (edge==Edge::top && y>=remote.h);
            if(back) {
                send(message(returned));reset();
                std::fprintf(stderr,"handoff returned\n");return true;
            }
            x=std::clamp(x,0.0,remote.w-1);y=std::clamp(y,0.0,remote.h-1);
            send(message(1,int(std::lround(x*1000)),int(std::lround(y*1000))));return true;
        }
        if(!at_edge(px,py)) {armed=true;return false;}
        const bool outward=(edge==Edge::right && dx>0) || (edge==Edge::left && dx<0) ||
            (edge==Edge::bottom && dy>0) || (edge==Edge::top && dy<0);
        if(!pending && armed && outward) {
            x=std::clamp(px-remote.x,0.0,remote.w-1);y=std::clamp(py-remote.y,0.0,remote.h-1);
            pending=true;armed=false;
            send(message(request,int(std::lround(x*1000)),int(std::lround(y*1000))));
        }
        return false;
    }
    bool input(Input e,bool injected=false) {
        if(injected) return false;
        auto* held=kind(e)==4?&physicalKeys:kind(e)==2?&physicalButtons:nullptr;
        if(held) {if(e.b)held->insert(e.a);else held->erase(e.a);}
        if(!outgoing) return false;
        send(e);return true;
    }
};
inline int self_test() {
    Core a({0,0,100,80},{100,20,120,60});
    std::vector<Input> sent, posted;bool grabbed=false;
    a.send=[&](Input e){sent.push_back(e);};a.inject=[&](Input e){posted.push_back(e);};
    a.capture=[&](bool value){grabbed=value;};
    auto require=[](bool ok){if(!ok)throw std::runtime_error("handoff self-test failed");};
    a.command(message(capabilities,1,1));
    require(!a.motion(99,30,1,0,true) && sent.empty());
    a.motion(99,30,1,0);require(kind(sent.back())==request && sent.back().b==10000);
    a.command(message(captured));require(grabbed);
    require(a.input(message(4,125,1)) && sent.back().a==125);
    a.motion(99,30,-2,0);require(!grabbed && kind(sent.back())==returned);
    a.command(message(entered,1000,2000));a.command(message(4,29,1));a.command(message(2,272,1));
    const auto before=sent.size();a.motion(99,30,1,0);require(sent.size()==before);
    a.command(message(released));require(posted.back().a==272 && posted.back().b==0);
    Core b({0,0,100,80},{-100,0,100,80});
    std::vector<Input> requests;
    b.send=[&](Input e){requests.push_back(e);};b.inject=[](Input){};b.capture=[](bool){};
    b.command(message(capabilities,1,1));
    b.command(message(entered,27000,30000));b.command(message(released));
    auto count=requests.size();b.motion(0,30,-27,0);
    require(requests.size()==count+1 && kind(requests.back())==request);
    b.observe_position(0,30);b.reset();count=requests.size();
    b.motion(0,30,-1,0,true);b.motion(0,30,-1,0);
    require(requests.size()==count); // no stationary/injected return-edge bounce
    b.motion(27,30,27,0,true);b.motion(0,30,-27,0);
    require(requests.size()==count+1);
    require(adjacent({0,0,100,80},{100,80,100,80})==Edge::none);
    std::puts("handoff self-test passed: captured entered returned released; no native input");return 0;
}
}

#pragma once
#include "geometry_sync.hpp"
#include <optional>
namespace viewflow::reverse {
inline bool windows_fullscreen_backing_enabled(bool mac,bool ivshmem,bool ime,bool shell,bool popup) {
    return !mac && ivshmem && !ime && !shell && !popup;
}
inline std::optional<Geometry> fullscreen_backing_extent(Geometry guest,int width,int height,int transform) {
    if(transform<0 || transform>7)return {};
    if(transform%2)std::swap(width,height);
    if(width<=0 || height<=0 || width>16384 || height>16384)return {};
    guest.width=width;guest.height=height;return guest;
}
struct FullscreenRouteRequest {
    int mode{},width{},height{};
    bool operator==(const FullscreenRouteRequest&) const=default;
};
// A successful ordered write owns retry handling on the Windows side. Never
// resend an accepted request every frame or advance its request epoch by time.
struct FullscreenRouteControl {
    std::optional<FullscreenRouteRequest> desired,succeeded;
    bool engaged{},attempted{};std::uint64_t last_attempt_ms{};
    std::optional<FullscreenRouteRequest> observe(bool fullscreen,std::optional<Geometry> extent,std::uint64_t now_ms) {
        if(fullscreen && !extent)return {};
        if(!fullscreen && !engaged)return {};
        FullscreenRouteRequest request{fullscreen?2:0,fullscreen?extent->width:0,fullscreen?extent->height:0};
        if(desired!=request){desired=request;attempted=false;}
        if(succeeded==desired)return {};
        if(attempted && now_ms-last_attempt_ms<500)return {};
        attempted=true;last_attempt_ms=now_ms;engaged=true;return request;
    }
    void sent(std::uint64_t sequence) {
        if(sequence)succeeded=desired;
    }
    bool exit_delivered() const {return !engaged || (succeeded && succeeded->mode==0 && succeeded==desired);}
};
struct FullscreenBackingDecision { bool consume{},send{};Geometry target{}; };
// Host geometry owns the backing during fullscreen and the exit receipt.
// Retry cadence is an operation retry, never a session/ownership deadline.
struct FullscreenBacking {
    bool active{},fullscreen{},attempted{};
    std::optional<Geometry> target;
    std::uint64_t pending{},last_attempt_ms{};
    FullscreenBackingDecision observe(bool now_fullscreen,std::optional<Geometry> desired,
                                       Geometry actual,std::uint64_t acknowledged,std::uint64_t now_ms) {
        if(!active && !now_fullscreen)return {};
        const bool transition=!active || fullscreen!=now_fullscreen;
        active=true;fullscreen=now_fullscreen;
        if(transition || desired!=target) {target=desired;pending=0;attempted=false;}
        if(!target)return {true,false,{}};
        const bool confirmed=pending && acknowledged>=pending && actual==*target;
        if(confirmed && !fullscreen) {
            active=false;pending=0;attempted=false;target.reset();return {true,false,{}};
        }
        const bool retry=!confirmed && (!attempted || now_ms-last_attempt_ms>=500);
        return {true,retry,*target};
    }
    void sent(std::uint64_t sequence,std::uint64_t now_ms) {
        attempted=true;last_attempt_ms=now_ms;
        // Retries request identical geometry: an earlier successful receipt
        // remains valid, even if capture latency exceeds the retry cadence.
        if(sequence && !pending)pending=sequence;
    }
};
}

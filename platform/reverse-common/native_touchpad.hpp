#pragma once
#include "wire.hpp"
#include <array>
#include <map>
#include <algorithm>

namespace viewflow::reverse {
using NativeTouchpadReport = std::array<std::uint8_t, 72>;
// VFTP ABI 2, little endian, matching the native DriverKit host.
inline NativeTouchpadReport native_report(std::uint32_t ticks) {
    NativeTouchpadReport out{};
    for (unsigned i=0;i<4;++i) out[4+i]=ticks>>(8*i);
    out[8]=16000&255; out[9]=16000>>8;
    out[10]=11490&255; out[11]=11490>>8;
    return out;
}
class NativeTouchpadEncoder {
    using Contact=std::array<std::uint8_t,12>;
    std::map<std::uint32_t,Contact> previous;
    unsigned next{};
    bool local_gesture{};
public:
    bool routes(unsigned count) const { return count==2 && !local_gesture; }
    template<class Snapshot, class Emit>
    void frame(const Snapshot& snapshot, std::uint32_t ticks, Emit emit) {
        std::map<std::uint32_t,Contact> current;
        // Three or more fingers belong to Linux until all fingers lift.
        // Release an in-progress Mac scroll when a third finger joins.
        if(snapshot.count>=3)local_gesture=true;
        if(snapshot.count==0)local_gesture=false;
        // Single-finger movement and buttons already follow the Wayland route.
        if(routes(snapshot.count) && snapshot.width && snapshot.height) {
            for(unsigned i=0;i<snapshot.count;++i) {
                const auto& c=snapshot.contacts[i]; Contact out{};
                if(previous.contains(c.id)) out[0]=previous.at(c.id)[0];
                else {
                    while(std::any_of(previous.begin(),previous.end(),[&](const auto& p){return p.second[0]==next;}) ||
                          std::any_of(current.begin(),current.end(),[&](const auto& p){return p.second[0]==next;})) next=(next+1)%15;
                    out[0]=next; next=(next+1)%15;
                }
                out[1]=1;
                const unsigned x=(std::uint64_t(std::min(c.x,snapshot.width))*32767+snapshot.width/2)/snapshot.width;
                const unsigned y=(std::uint64_t(std::min(c.y,snapshot.height))*32767+snapshot.height/2)/snapshot.height;
                out[2]=x&255; out[3]=x>>8; out[4]=y&255; out[5]=y>>8;
                out[6]=std::clamp(c.pressure,0,255);
                out[7]=std::clamp(c.major/4,0,255); out[8]=std::clamp(c.minor/4,0,255);
                out[9]=(unsigned(out[7])+out[8])/2;
                out[10]=std::clamp(4-c.orientation,0,7); out[11]=2;
                current[c.id]=out;
            }
        }
        auto pack=[&](const auto& contacts) {
            auto out=native_report(ticks); out[0]=contacts.size(); unsigned i=0;
            for(const auto& [_,c]:contacts) {std::copy(c.begin(),c.end(),out.begin()+12+12*i);++i;}
            emit(out);
        };
        auto retired=previous; bool any=false;
        for(auto& [id,c]:retired) if(!current.contains(id)){c[1]=0;any=true;}
        if(any)pack(retired);
        if(current!=previous)pack(current);
        previous=std::move(current);
    }
};
// Each chunk still uses the existing fixed-size ordered reverse input record.
class NativeTouchpadAssembler {
    NativeTouchpadReport report{};
    unsigned offset{};
    std::uint64_t window{};
public:
    void reset(){offset=0;window=0;}
    bool input(const Input& in, NativeTouchpadReport& out) {
        if(in.kind==InputKind::native_touchpad_chunk) {
            if(in.a==0){reset();window=in.id;}
            if(in.id!=window || in.a<0 || unsigned(in.a)!=offset || offset>60){reset();return false;}
            const std::array<std::uint32_t,3> words{std::uint32_t(in.b),std::uint32_t(in.c),std::uint32_t(in.d)};
            for(auto word:words) for(unsigned i=0;i<4;++i)report[offset++]=word>>(8*i);
        } else if(in.kind==InputKind::native_touchpad_commit) {
            const bool valid=in.id==window && offset==72 && in.a==72 && report[0]<=5 && report[1]==0;
            if(valid)out=report;
            reset();return valid;
        } else reset();
        return false;
    }
};
}

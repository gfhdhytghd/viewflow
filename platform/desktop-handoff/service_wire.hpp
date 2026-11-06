#pragma once
#include "core.hpp"
#include "windows_keys.hpp"
#include <array>
#include <bit>
namespace viewflow::handoff {
using ServiceRequest=std::array<uint8_t,140>;
inline ServiceRequest service_request(uint8_t tag) {
    ServiceRequest b{};b[0]='V';b[1]='F';b[2]='I';b[3]='2';b[4]=tag;return b;
}
inline void service_word(ServiceRequest& b,size_t offset,uint64_t word) {
    for(unsigned i=0;i<8;++i)b[offset+i]=uint8_t(word>>(i*8));
}
inline ServiceRequest service_input(Input e,Rect local,double sx,double sy) {
    auto b=service_request(0);uint64_t x=0,y=0;
    switch(kind(e)) {
    case 1:
        b[4]=1;
        // No display mapping: service resolves physical virtual-desktop pixels.
        x=uint64_t(int64_t(std::llround((e.a+local.x*1000)*sx)));
        y=uint64_t(int64_t(std::llround((e.b+local.y*1000)*sy)));break;
    case 2:
        b[4]=4;
        switch(e.a) {case 272:x=0;break;case 273:x=2;break;case 274:x=1;break;
            case 275:x=3;break;case 276:x=4;break;default:throw std::runtime_error("invalid service button");}
        y=e.b!=0;break;
    case 3: {
        b[4]=3;
        // Contract: detents use 120 units; precise events use milli-points,
        // with 40 points/detent. Service consumes fractional detents.
        const double detents=e.b/(e.c?40000.0:120.0);
        x=std::bit_cast<uint64_t>(e.a?0.0:detents);
        y=std::bit_cast<uint64_t>(e.a?-detents:0.0);break;
    }
    case 4: {
        b[4]=5;
        const auto key=windows_scan(e.a);
        if(!key || key->virtual_key)throw std::runtime_error("key unsupported by input service");
        struct Mapping {unsigned scan,page,usage;};
        static constexpr Mapping keys[]{
#include "service_keys.inc"
        };
        const unsigned scan=key->scan|(key->extended?0xe000:0);
        bool found=false;
        for(auto k:keys)if(k.scan==scan){x=k.page|(uint64_t(k.usage)<<16);found=true;break;}
        if(!found)throw std::runtime_error("key unsupported by input service");
        y=(e.b?1:0)|(e.b==2?2:0);break;
    }
    default:throw std::runtime_error("invalid service input");
    }
    service_word(b,8,x);service_word(b,16,y);return b;
}
}

#include "native_protocol.h"
#include <assert.h>
#include <vector>
#include <stdio.h>
using namespace vf_native;
static void contact(uint8_t *p,unsigned slot,unsigned id,unsigned down,unsigned x,unsigned y) {
    p[0]=slot+1;uint8_t *c=p+12+12*slot;c[0]=id;c[1]=down;put16(c+2,x);put16(c+4,y);
    c[6]=20;c[7]=40;c[8]=30;c[9]=35;c[10]=4;c[11]=2;
}
static int signed13(uint32_t v) {v&=8191;return (v&4096)?int(v)-8192:int(v);}
static uint32_t stamp(const std::vector<uint8_t>& p) {
    return (uint32_t(p[9])|(uint32_t(p[10])<<8)|(uint32_t(p[11])<<16))>>3;
}
static void natural_lift() {
    State s{};s.init();uint8_t p[wire_size];empty_wire(p,20000);
    for(unsigned i=0;i<4;++i)contact(p,i,i,1,10000+i*100,12000);
    std::vector<std::vector<uint8_t>> packets;
    auto send=[&](const uint8_t* b,size_t n){packets.emplace_back(b,b+n);return 0;};
    assert(!s.apply(p,sizeof(p),send));
    // Partial lift keeps surviving contacts active; it must not end the gesture.
    p[13]=0;assert(!s.apply(p,sizeof(p),send));assert(s.ids==14);
    assert(packets.size()==2 && ((u32(packets.back().data()+21)>>29)==4));
    for(unsigned i=0;i<4;++i)p[13+12*i]=0;
    size_t start=packets.size();assert(!s.apply(p,sizeof(p),send));
    assert(packets.size()==start+3 && !s.active());
    const auto &stop=packets[start], &inactive=packets[start+1], &empty=packets[start+2];
    for(unsigned i=0;i<4;++i) {
        const auto a=stop.data()+12+9*i,b=inactive.data()+12+9*i;
        assert((u32(a)>>29)==7 && (u32(b)>>26)==0);
        assert((u32(a)&0x3ffffff)==(u32(b)&0x3ffffff));
        assert((a[8]&15)==i+1 && a[8]==b[8]);
        for(unsigned j=4;j<8;++j)assert(a[j]==0 && b[j]==0);
    }
    assert(empty.size()==12 && empty[7]==2);
    uint32_t end_stamp=stamp(empty);
    for(size_t i=1;i<packets.size();++i)assert(((stamp(packets[i])-stamp(packets[i-1]))&0x1fffff)>0);
    empty_wire(p,20000);assert(!s.apply(p,sizeof(p),send));assert(packets.size()==start+3);
    // A next gesture sharing the evdev timestamp must not go backwards.
    contact(p,0,4,1,14000,15000);assert(!s.apply(p,sizeof(p),send));
    assert(stamp(packets.back())==end_stamp+1);
    // Direct empty snapshots use the previous contact coordinates. Failed
    // tails must finish before a later gesture can begin.
    empty_wire(p,21000);unsigned calls=0;
    auto fail=[&](const uint8_t*,size_t){return ++calls==2?7:0;};
    assert(s.apply(p,sizeof(p),fail)==7 && s.active() && s.ending_pending);
    contact(p,0,5,1,22000,23000);start=packets.size();
    assert(!s.apply(p,sizeof(p),send));assert(packets.size()==start+4);
    assert((packets[start][20]&15)==5 && packets[start+2].size()==12);
    assert((packets.back()[20]&15)==6 && s.ids==(1<<5));
    // The native 21-bit millisecond clock wraps without losing an end phase.
    s.emitted_stamp=0x1ffffe;s.have_stamp=true;
    empty_wire(p,0x1ffffe*10);assert(!s.apply(p,sizeof(p),send));
    assert(stamp(packets[packets.size()-3])==0x1fffff);
    assert(stamp(packets[packets.size()-2])==0 && stamp(packets.back())==1);
}
int main() {
    natural_lift();
    uint8_t wire[wire_size];empty_wire(wire,12000);
    for(unsigned i=0;i<5;++i)contact(wire,i,i,1,i*7000,i*7000);
    assert(valid(wire,sizeof(wire)));assert(down_count(wire)==5);
    State state{};state.init();std::vector<std::vector<uint8_t>> packets;
    auto send=[&](const uint8_t *p,size_t n){packets.emplace_back(p,p+n);return 0;};
    assert(state.apply(wire,sizeof(wire),send)==0);assert(state.peak==5 && state.ids==31);
    const auto &first=packets[0];assert(first.size()==57 && first[0]==2 && first[8]==0x31);
    for(unsigned i=0;i<5;++i) {
        const uint8_t *f=first.data()+12+i*9;
        assert((f[8]&15)==i+1);assert((u32(f)>>29)==3);
        // Independently decode fields using their packed signed widths.
        assert(signed13(u32(f))==int((i*7000u*8134u+16383)/32767)-4067);
        assert(signed13(u32(f)>>13)==2603-int((i*7000u*5206u+16383)/32767));
    }
    wire[1]=1;assert(state.apply(wire,sizeof(wire),send)==0);assert(state.clicks==1);
    assert((u32(packets.back().data()+12)>>29)==4);
    unsigned calls=0;
    auto fail_second=[&](const uint8_t *,size_t){return ++calls==2?123:0;};
    assert(state.release(fail_second)==123);assert(state.active());
    assert(state.release(send)==0);assert(!state.active() && state.clicks==2);
    assert(packets.back().size()==12 && packets.back()[1]==0 && packets.back()[7]==2);
    size_t count=packets.size();assert(state.release(send)==0 && packets.size()==count);
    // Failed submissions must not change contact state or counters.
    assert(state.apply(wire,sizeof(wire),[](const uint8_t *,size_t){return 5;})==5);
    assert(!state.active());
    contact(wire,1,0,1,10,10);assert(!valid(wire,sizeof(wire))); // duplicate ID
    empty_wire(wire);wire[71]=1;assert(!valid(wire,sizeof(wire))); // unused nonzero
    empty_wire(wire);wire[8]=0;assert(!valid(wire,sizeof(wire))); // calibration mismatch
    Features f{};uint8_t out[96],request[]={1,0xdb};
    assert(f.set(1,request,sizeof(request)));assert(f.get(1,out)==5 && u16(out+3)==73);
    assert(f.get(0xdb,out)==74 && out[2]==2 && out[4]==0xd1);
    assert(f.get(0xd9,out)==17 && u32(out+1)==width && u32(out+5)==height);
    assert(f.get(0xee,out)==0 && f.unknown==1);
    assert(f.get(0xc8,out)==2 && out[1]==8);
    uint8_t mode[]={0xc8,9};
    assert(f.set(0xc8,mode,sizeof(mode)));
    assert(f.get(0xc8,out)==2 && out[1]==9);
    assert(!f.set(0xc8,mode,1));
    mode[0]=0xc9;assert(!f.set(0xc8,mode,sizeof(mode)));
    assert(f.get(0xc8,out)==2 && out[1]==9);
    puts("native protocol: five contacts, state transitions, failed cleanup and feature dialogue passed");
}

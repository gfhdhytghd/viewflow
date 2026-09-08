#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

// Viewflow wire ABI 2. Protocol facts/references are documented in NATIVE.md.
// No compiler bitfields: byte layout must agree across Linux and DriverKit.
namespace vf_native {
constexpr size_t wire_size = 72, max_contacts = 5, max_hid_size = 57;
constexpr uint64_t abi_version = 2;
constexpr uint16_t width = 16000, height = 11490; // Magic Trackpad surface, 0.01 mm
inline uint16_t u16(const uint8_t *p) { return uint16_t(p[0] | (uint16_t(p[1]) << 8)); }
inline uint32_t u32(const uint8_t *p) { return uint32_t(u16(p)) | (uint32_t(u16(p+2)) << 16); }
inline void put16(uint8_t *p, uint16_t n) { p[0] = n; p[1] = n >> 8; }
inline void put32(uint8_t *p, uint32_t n) { put16(p, n); put16(p+2, n >> 16); }
inline unsigned down_count(const uint8_t *p) {
    unsigned count = 0;
    for (unsigned i=0; i<p[0]; ++i) count += p[12+12*i+1] != 0;
    return count;
}
inline uint16_t down_ids(const uint8_t *p) {
    uint16_t ids=0;
    for (unsigned i=0;i<p[0];++i) if (p[13+12*i]) ids |= uint16_t(1u << p[12+12*i]);
    return ids;
}
inline bool valid(const uint8_t *p, size_t n) {
    if (!p || n!=wire_size || p[0]>max_contacts || p[1]>1 || p[2] || p[3] ||
        u16(p+8)!=width || u16(p+10)!=height) return false;
    uint16_t ids=0;
    for (unsigned i=0; i<max_contacts; ++i) {
        const uint8_t *c=p+12+12*i;
        if (i>=p[0]) { for (unsigned j=0;j<12;++j) if(c[j]) return false; continue; }
        if (c[0]>14 || c[1]>1 || u16(c+2)>32767 || u16(c+4)>32767 || c[10]>7 || c[11]>6) return false;
        if (ids & (1u<<c[0])) return false;
        ids |= uint16_t(1u<<c[0]);
    }
    return true;
}
inline void empty_wire(uint8_t *p, uint32_t ticks=0) {
    memset(p,0,wire_size); put32(p+4,ticks); put16(p+8,width); put16(p+10,height);
}
// Mouse report 0x02 wraps the native 0x31 multitouch payload.
// A contact is signed 13-bit X/Y, 3-bit finger/state, area, size, pressure, ID/angle.
inline size_t encode(const uint8_t *p, uint16_t previous_ids, uint8_t *out, bool inactive=false) {
    memset(out,0,max_hid_size);
    out[0]=2; out[1]=p[1]; out[7]=(down_count(p) || p[1])?3:2; out[8]=0x31;
    uint32_t stamp=((u32(p+4)/10)<<3)|4; // milliseconds, low 21 bits on wire
    out[9]=stamp; out[10]=stamp>>8; out[11]=stamp>>16;
    for (unsigned i=0;i<p[0];++i) {
        const uint8_t *c=p+12+12*i; uint8_t *f=out+12+9*i;
        int x=int((uint32_t(u16(c+2))*8134+16383)/32767)-4067;
        int y=2603-int((uint32_t(u16(c+4))*5206+16383)/32767);
        unsigned state=inactive?0:(c[1]?((previous_ids&(1u<<c[0]))?4:3):7);
        // Finger classification is carried separately from stable contact ID.
        uint32_t bits=(uint32_t(x)&0x1fff)|((uint32_t(y)&0x1fff)<<13)|(uint32_t(inactive?0:c[11])<<26)|(state<<29);
        put32(f,bits);
        if(c[1] && !inactive) { f[4]=c[7];f[5]=c[8];f[6]=c[9];f[7]=c[6]; }
        f[8]=uint8_t((c[0]+1)|(c[10]<<5));
    }
    return 12+9*p[0];
}
struct State {
    uint8_t last[wire_size] = {};
    uint16_t ids=0;
    uint64_t peak=0, clicks=0, frames=0;
    void init() { empty_wire(last); }
    bool active() const { return ids || last[1]; }
    template<class Submit> int apply(const uint8_t *p,size_t n,Submit submit) {
        if(!valid(p,n)) return -1;
        uint8_t hid[max_hid_size];size_t len=encode(p,ids,hid);
        int r=submit(hid,len); if(r) return r;
        if(last[1]!=p[1]) ++clicks;
        memcpy(last,p,wire_size);ids=down_ids(p);++frames;
        unsigned count=down_count(p);if(count>peak)peak=count;
        return 0;
    }
    template<class Submit> int release(Submit submit) {
        if(!active())return 0;
        uint8_t lifted[wire_size],hid[max_hid_size];memcpy(lifted,last,wire_size);
        lifted[1]=0;
        for(unsigned i=0;i<lifted[0];++i)lifted[13+12*i]=0;
        // Finish contacts before the empty frame. Retain last state if any send
        // fails, so a later cleanup retries rather than pretending success.
        size_t n=encode(lifted,ids,hid);int r=submit(hid,n);if(r)return r;
        put32(lifted+4,u32(lifted+4)+10);
        n=encode(lifted,0,hid,true);r=submit(hid,n);if(r)return r;
        empty_wire(lifted,u32(lifted+4)+10);n=encode(lifted,0,hid);
        r=submit(hid,n);if(r)return r;
        if(last[1])++clicks;
        memcpy(last,lifted,wire_size);ids=0;return 0;
    }
};

// Feature-report dialogue used by Apple's MT initialization. Unknown requests
// fail visibly; they are not acknowledged as successful empty responses.
struct Features {
    uint8_t pending=0;
    uint64_t gets=0,sets=0,unknown=0,last_request=0;
    static size_t value(uint8_t id,uint8_t *out) {
        out[0]=id;
        switch(id) {
        case 0: out[1]=1; return 2;
        case 2: out[1]=1; return 2;
        case 0xd1: out[1]=0x81; return 2;
        case 0xd3: { const uint8_t v[]={1,22,30,3,149,0,20,30,98,5,0,0};memcpy(out+1,v,sizeof(v));return 13; }
        case 0xd0: { const uint8_t v[]={2,1,0,20,1,0,30,0,2,20,2,1,14,2,0};memcpy(out+1,v,sizeof(v));return 16; }
        case 0xa1: { const uint8_t v[]={0,0,5,0,252,1};memcpy(out+1,v,sizeof(v));return 7; }
        case 0xd9:
            put32(out+1,width);put32(out+5,height);
            put16(out+9,0xe344);put16(out+11,0xff52);put16(out+13,0x1ebd);put16(out+15,0x26e4);return 17;
        case 0x7f: memset(out+1,0,4);return 5;
        case 0xc8: out[1]=8;return 2;
        case 0xdb: {
            out[1]=1;size_t used=2;
            const uint8_t ids[]={0xd1,0xd3,0xd0,0xa1,0xd9,0x7f};
            for(uint8_t field:ids) { size_t n=value(field,out+used+2);put16(out+used,n);used+=2+n; }
            return used;
        }
        default:return 0;
        }
    }
    size_t get(uint8_t id,uint8_t *out) {
        ++gets;last_request=id;
        if(id==1) {
            if(!pending){++unknown;return 0;}
            uint8_t buf[96];size_t n=value(pending,buf);
            // Native query 1 returns the length excluding the report-ID byte.
            out[0]=1;out[1]=pending;out[2]=0;put16(out+3,n? n-1:0);return 5;
        }
        size_t n=value(id,out);if(!n)++unknown;return n;
    }
    bool set(uint8_t id,const uint8_t *p,size_t n) {
        ++sets;last_request=0x100|id;
        if(id==1 && n>=2 && p[0]==1) {
            uint8_t b[96];if(value(p[1],b)){pending=p[1];return true;}
        }
        if(id==2 && n>=2 && p[0]==2)return true;
        ++unknown;return false;
    }
};
}

#include "dma_bank_layout.hpp"
#include <cassert>
#include <cstdio>
#include <type_traits>
#include <initializer_list>
using namespace viewflow::reverse::shm;
DmaBankLayout valid() {
    DmaBankLayout l{};
    l.magic=dma_bank_magic;l.version=1;l.flags=1;l.generation=7;
    l.capacity=dma_bank_capacity;l.segment_bytes=static_cast<std::uint32_t>(dma_segment_bytes);
    l.segments_per_bank=dma_segments_per_bank;l.bus=0;l.first_slot=10;
    for(unsigned i=0;i<4;++i){l.bank_devices[i]=19;l.bank_inodes[i]=100+i;}
    return l;
}
int main() {
    static_assert(std::is_standard_layout_v<DmaBankLayout> && std::is_trivially_copyable_v<DmaBankLayout>);
    static_assert(sizeof(DmaBankLayout)==320 && alignof(DmaBankLayout)==64);
    static_assert(offsetof(DmaBankLayout,bank_devices)==48 && offsetof(DmaBankLayout,bank_inodes)==80);
    static_assert(offsetof(DmaBankLayout,requested)==128 && offsetof(DmaBankLayout,ready)==192 && offsetof(DmaBankLayout,failed)==256);
    static_assert(dma_bank_layout_offset==2048 && dma_bank_layout_offset+sizeof(DmaBankLayout)<=4096);
    assert(dma_segment_mask(0)==0);
    assert(dma_segment_mask(1)==1 && dma_segment_mask(dma_segment_bytes)==1);
    assert(dma_segment_mask(dma_segment_bytes+1)==3);
    assert(dma_segment_mask(84934656)==3);
    assert(dma_segment_mask(dma_bank_capacity)==0xffff);
    assert(dma_segment_mask(dma_bank_capacity+1)==0);
    assert(dma_segment_mask(UINT64_MAX)==0);
    for(unsigned bank=0;bank<4;++bank)for(unsigned seg=0;seg<16;++seg){
        const unsigned ordinal=bank*16+seg;
        assert(dma_segment_address(10,bank,seg)==(((10+ordinal/8)<<16)|(ordinal%8)));
    }
    auto l=valid();assert(valid_dma_bank_layout(l));
    assert(request_dma_segments(l,0,1)==DmaMappingStatus::pending && l.requested.masks[0]==1);
    std::atomic_ref(l.ready.masks[0]).store(1,std::memory_order_release);
    assert(request_dma_segments(l,0,1)==DmaMappingStatus::ready);
    assert(request_dma_segments(l,0,84934656)==DmaMappingStatus::pending && l.requested.masks[0]==3);
    std::atomic_ref(l.failed.masks[0]).store(2,std::memory_order_release);
    assert(request_dma_segments(l,0,84934656)==DmaMappingStatus::failed);
    // Successfully mapped segments override a stale failed indication.
    std::atomic_ref(l.ready.masks[0]).store(3,std::memory_order_release);
    assert(request_dma_segments(l,0,84934656)==DmaMappingStatus::ready);
    assert(request_dma_segments(l,1,1)==DmaMappingStatus::pending && l.requested.masks[1]==1);
    for(auto bytes:{UINT64_C(0),dma_bank_capacity+1,UINT64_MAX})
        assert(request_dma_segments(l,0,bytes)==DmaMappingStatus::invalid && l.requested.masks[0]==3);
    assert(request_dma_segments(l,4,1)==DmaMappingStatus::invalid);
    const auto invalid=[&](DmaBankLayout& bad){
        assert(!valid_dma_bank_layout(bad));
        assert(request_dma_segments(bad,0,1)==DmaMappingStatus::invalid && bad.requested.masks[0]==0);
    };
    auto bad=valid();bad.magic=0;invalid(bad);
    bad=valid();bad.version=2;invalid(bad);
    bad=valid();bad.flags=0;invalid(bad);
    bad=valid();bad.generation=0;invalid(bad);
    bad=valid();bad.capacity--;invalid(bad);
    bad=valid();bad.segment_bytes=4096;invalid(bad);
    bad=valid();bad.segments_per_bank=15;invalid(bad);
    bad=valid();bad.bus=256;invalid(bad);
    bad=valid();bad.first_slot=9;invalid(bad);
    bad=valid();bad.first_slot=25;invalid(bad);
    bad=valid();bad.bank_inodes[2]=0;invalid(bad);
    bad=valid();bad.bank_inodes[2]=bad.bank_inodes[0];invalid(bad);
    auto boundary=valid();boundary.first_slot=24;boundary.bus=255;assert(valid_dma_bank_layout(boundary));
    assert(dma_segment_address(24,3,15)==((31u<<16)|7u));
    std::puts("dma bank ABI320/control2048 mask64MiB pending-ready-failed bounds and identities passed");
}

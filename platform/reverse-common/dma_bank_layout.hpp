#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace viewflow::reverse::shm {
// Local x86-64 control-BAR extension. No pixels or session policy here.
// Existing SHM1 references and the four tight logical banks remain unchanged.
inline constexpr std::uint64_t dma_bank_magic=0x31414d4442465656ULL;
inline constexpr std::size_t dma_bank_layout_offset=2048;
inline constexpr std::uint32_t bank_memfd=2u, bank_gpu_segmented=4u;
inline constexpr unsigned dma_bank_count=4, dma_segments_per_bank=16;
inline constexpr std::uint64_t dma_segment_bytes=64ULL<<20;
inline constexpr std::uint64_t dma_bank_capacity=1ULL<<30;
inline constexpr std::uint64_t dma_all_segments=(1ULL<<dma_segments_per_bank)-1;
struct alignas(64) DmaMaskLine {
    std::uint64_t masks[dma_bank_count];
    std::uint64_t reserved[4];
};
struct alignas(64) DmaBankLayout {
    std::uint64_t magic;
    std::uint32_t version,flags;
    std::uint64_t generation,capacity;
    std::uint32_t segment_bytes,segments_per_bank,bus,first_slot;
    std::uint64_t bank_devices[dma_bank_count],bank_inodes[dma_bank_count];
    std::uint64_t reserved[2];
    DmaMaskLine requested,ready,failed;
};
static_assert(sizeof(DmaMaskLine)==64 && sizeof(DmaBankLayout)==320);
static_assert(offsetof(DmaBankLayout,requested)==128);
static_assert(offsetof(DmaBankLayout,ready)==192);
static_assert(offsetof(DmaBankLayout,failed)==256);
static_assert(dma_bank_layout_offset+sizeof(DmaBankLayout)<=4096);
inline bool valid_dma_bank_layout(const DmaBankLayout& l) noexcept {
    if(l.magic!=dma_bank_magic || l.version!=1 || l.flags!=1 || !l.generation ||
       l.capacity!=dma_bank_capacity || l.segment_bytes!=dma_segment_bytes ||
       l.segments_per_bank!=dma_segments_per_bank || l.bus>255 ||
       l.first_slot<10 || l.first_slot>24) return false;
    for(unsigned i=0;i<dma_bank_count;++i) {
        if(!l.bank_inodes[i])return false;
        for(unsigned j=0;j<i;++j)
            if(l.bank_devices[i]==l.bank_devices[j] && l.bank_inodes[i]==l.bank_inodes[j])return false;
    }
    return true;
}
inline constexpr std::uint64_t dma_segment_mask(std::uint64_t bytes) noexcept {
    if(!bytes || bytes>dma_bank_capacity)return 0;
    const auto n=(bytes+dma_segment_bytes-1)/dma_segment_bytes;
    return (1ULL<<n)-1;
}
inline constexpr std::uint32_t dma_segment_address(unsigned first_slot,unsigned bank,unsigned segment) noexcept {
    const auto ordinal=bank*dma_segments_per_bank+segment;
    return ((first_slot+ordinal/8)<<16)|(ordinal%8);
}
enum class DmaMappingStatus { pending,ready,failed,invalid };
inline DmaMappingStatus request_dma_segments(DmaBankLayout& l,unsigned bank,std::uint64_t bytes) noexcept {
    const auto mask=dma_segment_mask(bytes);
    if(bank>=dma_bank_count || !mask || !valid_dma_bank_layout(l))return DmaMappingStatus::invalid;
    std::atomic_ref(l.requested.masks[bank]).fetch_or(mask,std::memory_order_release);
    const auto ready=std::atomic_ref(l.ready.masks[bank]).load(std::memory_order_acquire);
    if((ready&mask)==mask)return DmaMappingStatus::ready;
    if(std::atomic_ref(l.failed.masks[bank]).load(std::memory_order_acquire)&mask&~ready)return DmaMappingStatus::failed;
    return DmaMappingStatus::pending;
}
}

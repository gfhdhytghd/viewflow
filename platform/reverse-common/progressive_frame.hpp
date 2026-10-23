#pragma once
#include "progressive_state.hpp"
#include "wire.hpp"
namespace viewflow::reverse::shm {
// Experimental SHM2 reference. It must not be sent until both endpoints
// negotiate support; SHM1 readers must never receive an early reference.
struct ProgressiveReference {
    std::uint64_t epoch{},sequence{},capacity{};
    std::uint32_t slot{},width{},height{};
    friend bool operator==(const ProgressiveReference&,const ProgressiveReference&)=default;
};
inline bool valid(const ProgressiveReference& r){return r.epoch && r.sequence && r.slot<4 && r.width && r.height && r.width<=shared_max_dimension && r.height<=shared_max_dimension && r.capacity>=4096 && r.capacity<=std::uint64_t(shared_max_pixels)*4 && r.capacity%64==0 && std::uint64_t(r.width)*r.height*4<=r.capacity;}
inline std::vector<std::uint8_t> pack_progressive(const ProgressiveReference& r){
    if(!valid(r))throw std::runtime_error("progressive reference bounds");
    Writer w;w.u32(0x324d4853);w.u32(r.slot);w.u64(r.epoch);w.u64(r.sequence);w.u32(r.width);w.u32(r.height);w.u64(r.capacity);return w.bytes;
}
inline ProgressiveReference unpack_progressive(std::span<const std::uint8_t> bytes){
    Reader in{bytes};if(in.u32()!=0x324d4853)throw std::runtime_error("progressive reference version");
    ProgressiveReference r;r.slot=in.u32();r.epoch=in.u64();r.sequence=in.u64();r.width=in.u32();r.height=in.u32();r.capacity=in.u64();in.finish();
    if(!valid(r))throw std::runtime_error("progressive reference bounds");
    return r;
}
struct alignas(64) ProgressiveFrame {
private:
    ProgressiveState ownership_;
    ProgressiveReference identity_;
public:
    bool begin(const ProgressiveReference& r){
        if(!valid(r))throw std::runtime_error("progressive frame bounds");
        if(!ownership_.begin())return false;
        identity_=r;ownership_.announce();return true;
    }
    bool acquire(const ProgressiveReference& r){
        if(!valid(r))throw std::runtime_error("progressive frame reference bounds");
        if(!ownership_.acquire())return false;
        if(identity_==r)return true;
        // Writer may have completed while we checked identity. Restore ready
        // rather than retiring a newer generation on an obsolete reference.
        ownership_.release_reader(true);return false;
    }
    void publish_prefix(std::uint64_t rows){
        if(rows>identity_.height)throw std::runtime_error("progressive prefix exceeds frame");
        ownership_.publish_prefix(rows);
    }
    void finish(){if(ownership_.available_rows()!=identity_.height)throw std::runtime_error("progressive incomplete frame");ownership_.finish_writer(true);}
    void abort(){ownership_.finish_writer(false);}
    bool discard_ready(){return ownership_.discard_ready();}
    bool unused(){return ownership_.unused();}
    void recover(bool writer){ownership_.recover(writer);}
    void release(){ownership_.release_reader();}
    std::uint64_t available_rows(){return ownership_.available_rows();}
    bool complete(){return ownership_.complete();}
    bool aborted(){return ownership_.aborted();}
};
static_assert(sizeof(ProgressiveFrame)==128);
}

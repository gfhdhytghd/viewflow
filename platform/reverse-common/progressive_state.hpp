#pragma once
#include <atomic>
#include <cstdint>
#include <stdexcept>

namespace viewflow::reverse::shm {
// Experimental ownership primitive, not yet advertised by the IVSHMEM ABI.
// One writer and one reader, with the existing exclusive process-side locks.
// Pixel data/metadata must outlive both owners. Prefix rows are immutable once
// published. Only complete() permits presentation; aborted prefixes are discarded.
struct alignas(64) ProgressiveState {
    enum : std::uint64_t { free=0,writing=1,ready=2,writing_reading=3,complete_reading=4,aborted_reading=5,initializing=6 };
    std::uint64_t state=free,rows=0;
    bool discard_ready(){
        auto expected=std::uint64_t(ready);
        return std::atomic_ref(state).compare_exchange_strong(expected,free,std::memory_order_acq_rel);
    }
    bool unused(){return std::atomic_ref(state).load(std::memory_order_acquire)==free;}
    bool begin(){
        std::atomic_ref s(state);auto expected=std::uint64_t(free);
        // Caller owns the slot metadata before exposing a reference. Do not
        // recycle a ready frame until its reference is retired by its owner.
        if(!s.compare_exchange_strong(expected,initializing,std::memory_order_acq_rel))return false;
        std::atomic_ref(rows).store(0,std::memory_order_relaxed);return true;
    }
    void announce(){
        std::atomic_ref s(state);auto expected=std::uint64_t(initializing);
        if(!s.compare_exchange_strong(expected,writing,std::memory_order_release,std::memory_order_relaxed))throw std::runtime_error("frame announcement ownership");
    }
    void publish_prefix(std::uint64_t completed_rows){
        const auto phase=std::atomic_ref(state).load(std::memory_order_acquire);
        if(phase!=writing && phase!=writing_reading)throw std::runtime_error("frame prefix ownership");
        auto r=std::atomic_ref(rows);
        if(completed_rows<=r.load(std::memory_order_relaxed))throw std::runtime_error("non-monotonic frame prefix");
        // Caller finishes CPU copies and streaming-store fences first.
        r.store(completed_rows,std::memory_order_release);
    }
    std::uint64_t available_rows(){return std::atomic_ref(rows).load(std::memory_order_acquire);}
    bool acquire(){
        std::atomic_ref s(state);auto old=s.load(std::memory_order_acquire);
        for(;;){
            const auto next=old==writing?writing_reading:old==ready?complete_reading:free;
            if(next==free)return false;
            if(s.compare_exchange_weak(old,next,std::memory_order_acq_rel))return true;
        }
    }
    void finish_writer(bool success){
        std::atomic_ref s(state);auto old=s.load(std::memory_order_acquire);
        for(;;){
            const auto next=old==initializing && !success?free:old==writing?(success?ready:free):old==writing_reading?(success?complete_reading:aborted_reading):old;
            if(next==old)throw std::runtime_error("frame writer ownership");
            if(s.compare_exchange_weak(old,next,std::memory_order_acq_rel))return;
        }
    }
    void release_reader(bool preserve_complete=false){
        std::atomic_ref s(state);auto old=s.load(std::memory_order_acquire);
        for(;;){
            const auto next=old==writing_reading?writing:old==complete_reading?(preserve_complete?ready:free):old==aborted_reading?free:old;
            if(next==old)throw std::runtime_error("frame reader ownership");
            if(s.compare_exchange_weak(old,next,std::memory_order_acq_rel))return;
        }
    }
    // Only after acquiring the same-side exclusive process lock and ensuring
    // any abandoned GPU DMA using that side has ended. Never run concurrently
    // with a live owner on the recovering side.
    void recover(bool writer){
        std::atomic_ref s(state);auto old=s.load(std::memory_order_acquire);
        for(;;){
            const auto next=writer
                ? (old==initializing || old==writing || old==ready?free:old==writing_reading?aborted_reading:old)
                : (old==writing_reading?writing:old==ready || old==complete_reading || old==aborted_reading?free:old);
            if(next==old)return;
            if(s.compare_exchange_weak(old,next,std::memory_order_acq_rel))return;
        }
    }
    bool complete(){return std::atomic_ref(state).load(std::memory_order_acquire)==complete_reading;}
    bool aborted(){return std::atomic_ref(state).load(std::memory_order_acquire)==aborted_reading;}
};
static_assert(sizeof(ProgressiveState)==64);
static_assert(std::atomic_ref<std::uint64_t>::is_always_lock_free);
}

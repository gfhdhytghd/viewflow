#pragma once
#include <cstdint>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <emmintrin.h>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>
#include <algorithm>
#include <cstdlib>
#include <immintrin.h>
#ifdef _MSC_VER
#include <intrin.h>
#endif
namespace viewflow::reverse::shm {
inline bool copy_avx2_available() {
#ifdef _MSC_VER
    int regs[4]{};__cpuid(regs,0);if(regs[0]<7)return false;
    __cpuid(regs,1);if((regs[2]&((1<<27)|(1<<28)))!=((1<<27)|(1<<28)) || (_xgetbv(0)&6)!=6)return false;
    __cpuidex(regs,7,0);return (regs[1]&(1<<5))!=0;
#else
    return __builtin_cpu_supports("avx2");
#endif
}
#ifdef _MSC_VER
__declspec(noinline)
#else
__attribute__((target("avx2"),noinline))
#endif
inline void streaming_rows_avx2(std::uint8_t* destination,const std::uint8_t* source,std::size_t row_bytes,std::size_t pitch,unsigned first,unsigned last,bool stream_load=false) {
    for(unsigned y=first;y<last;++y) {
        auto* dst=destination+std::size_t(y)*row_bytes;const auto* src=source+std::size_t(y)*pitch;std::size_t x=0;
        for(;x<row_bytes && (reinterpret_cast<std::uintptr_t>(dst+x)&31);++x)dst[x]=src[x];
        if(stream_load && !(reinterpret_cast<std::uintptr_t>(src+x)&31)) {
            for(;x+128<=row_bytes;x+=128)for(unsigned j=0;j<128;j+=32)
                _mm256_stream_si256(reinterpret_cast<__m256i*>(dst+x+j),_mm256_stream_load_si256(reinterpret_cast<const __m256i*>(src+x+j)));
        }else {
            for(;x+128<=row_bytes;x+=128)for(unsigned j=0;j<128;j+=32)
                _mm256_stream_si256(reinterpret_cast<__m256i*>(dst+x+j),_mm256_loadu_si256(reinterpret_cast<const __m256i*>(src+x+j)));
        }
        if(x<row_bytes)std::memcpy(dst+x,src+x,row_bytes-x);
    }
    _mm_sfence();_mm256_zeroupper();
}
inline void streaming_rows(std::uint8_t* destination,const std::uint8_t* source,std::size_t row_bytes,std::size_t pitch,unsigned first,unsigned last) {
    for(unsigned y=first;y<last;++y){
        auto* dst=destination+std::size_t(y)*row_bytes;const auto* src=source+std::size_t(y)*pitch;
        std::size_t x=0;
        for(;x<row_bytes && (reinterpret_cast<std::uintptr_t>(dst+x)&15);++x)dst[x]=src[x];
        for(;x+64<=row_bytes;x+=64)for(unsigned j=0;j<64;j+=16)
            _mm_stream_si128(reinterpret_cast<__m128i*>(dst+x+j),_mm_loadu_si128(reinterpret_cast<const __m128i*>(src+x+j)));
        if(x<row_bytes)std::memcpy(dst+x,src+x,row_bytes-x);
    }
    _mm_sfence(); // each publishing thread drains its own streaming stores
}
// Bounded persistent helpers sleep between frames. Each thread drains its own
// streaming writes before completion; the caller publishes only after all join.
class ParallelCopy {
    std::mutex mutex_;std::condition_variable work_,done_;
    bool stopping_{};std::uint64_t generation_{};unsigned remaining_{},threads_;bool avx2_;bool cached_;
    std::uint8_t* destination_{};const std::uint8_t* source_{};
    std::size_t row_bytes_{},pitch_{};unsigned height_{};
    std::vector<std::thread> workers_;
    using TraceClock=std::chrono::steady_clock;
    const bool stream_load_=[]{const auto* v=std::getenv("VIEWFLOW_SHM_STREAM_LOAD");return v && std::strcmp(v,"1")==0;}();
    const bool trace_=std::getenv("VIEWFLOW_SHM_COPY_TRACE")!=nullptr;
    TraceClock::time_point dispatched_{};
    const bool dynamic_=[]{const auto* v=std::getenv("VIEWFLOW_SHM_COPY_DYNAMIC");return v && std::strcmp(v,"1")==0;}();
    std::atomic<unsigned> next_row_{0};
    void assigned_rows(std::uint8_t* destination,const std::uint8_t* source,std::size_t row_bytes,std::size_t pitch,unsigned first,unsigned last) {
        if(!dynamic_){rows(destination,source,row_bytes,pitch,first,last);return;}
        // Exclusive whole-row chunks. Each chunk drains its streaming stores;
        // the existing completion barrier still precedes slot publication.
        for(;;){const unsigned start=next_row_.fetch_add(64,std::memory_order_relaxed);if(start>=height_)break;rows(destination,source,row_bytes,pitch,start,std::min(start+64,height_));}
    }
    struct WorkerTiming { double start_ms{},copy_ms{}; };
    std::array<WorkerTiming,8> timings_{};
    void timed_rows(unsigned index,std::uint8_t* destination,const std::uint8_t* source,std::size_t row_bytes,std::size_t pitch,unsigned first,unsigned last) {
        if(!trace_){assigned_rows(destination,source,row_bytes,pitch,first,last);return;}
        const auto begin=TraceClock::now();
        assigned_rows(destination,source,row_bytes,pitch,first,last);
        const auto end=TraceClock::now();
        timings_[index]={std::chrono::duration<double,std::milli>(begin-dispatched_).count(),std::chrono::duration<double,std::milli>(end-begin).count()};
    }
    void stop() {
        {std::lock_guard lock(mutex_);stopping_=true;}
        work_.notify_all();for(auto& worker:workers_)worker.join();
    }
    void run(unsigned index) {
        std::uint64_t seen=0;std::unique_lock lock(mutex_);
        for(;;){
            work_.wait(lock,[&]{return stopping_ || generation_!=seen;});if(stopping_)return;
            seen=generation_;
            auto* destination=destination_;const auto* source=source_;auto row_bytes=row_bytes_,pitch=pitch_;
            const auto first=unsigned(std::uint64_t(height_)*index/threads_),last=unsigned(std::uint64_t(height_)*(index+1)/threads_);
            lock.unlock();timed_rows(index,destination,source,row_bytes,pitch,first,last);lock.lock();
            if(--remaining_==0)done_.notify_one();
        }
    }
public:
    // Optional caller-owned scheduling policy; normal copies use OS defaults.
    template<class Configure> void configure_workers(Configure&& configure) {
        for(auto& worker:workers_)configure(worker.native_handle());
    }
    void rows(std::uint8_t* destination,const std::uint8_t* source,std::size_t row_bytes,std::size_t pitch,unsigned first,unsigned last) const {
        if(cached_) {
            if(pitch==row_bytes)std::memcpy(destination+std::size_t(first)*row_bytes,source+std::size_t(first)*pitch,std::size_t(last-first)*row_bytes);
            else for(unsigned y=first;y<last;++y)std::memcpy(destination+std::size_t(y)*row_bytes,source+std::size_t(y)*pitch,row_bytes);
        }
        else if(avx2_)streaming_rows_avx2(destination,source,row_bytes,pitch,first,last,stream_load_);
        else streaming_rows(destination,source,row_bytes,pitch,first,last);
    }
    static bool configured_avx2() {
        const auto* value=std::getenv("VIEWFLOW_SHM_COPY_AVX2");return value && std::strcmp(value,"1")==0;
    }
    static unsigned configured_threads() {
        const auto* value=std::getenv("VIEWFLOW_SHM_COPY_THREADS");
        return value && std::strcmp(value,"4")==0?4u:2u;
    }
    explicit ParallelCopy(unsigned threads=configured_threads(),bool avx2=configured_avx2(),bool cached=false):threads_(std::clamp(threads,1u,8u)),avx2_(avx2 && copy_avx2_available()),cached_(cached) {
        try {for(unsigned i=1;i<threads_;++i)workers_.emplace_back([this,i]{run(i);});}
        catch(...){stop();throw;}
    }
    ~ParallelCopy(){stop();}
    void copy(std::uint8_t* destination,const std::uint8_t* source,std::size_t row_bytes,std::size_t pitch,unsigned height) {
        {std::lock_guard lock(mutex_);destination_=destination;source_=source;row_bytes_=row_bytes;pitch_=pitch;height_=height;remaining_=threads_-1;if(dynamic_)next_row_.store(0,std::memory_order_relaxed);++generation_;if(trace_)dispatched_=TraceClock::now();}
        work_.notify_all();timed_rows(0,destination,source,row_bytes,pitch,0,height/threads_);
        std::unique_lock lock(mutex_);done_.wait(lock,[&]{return remaining_==0;});
        if(trace_ && generation_%120==1) {
            // All workers finished; timings are published under mutex_. No
            // per-row logging or clock reads when diagnostics are disabled.
            std::fprintf(stderr,"shared-copy-workers generation=%llu threads=%u bytes=%zu",static_cast<unsigned long long>(generation_),threads_,row_bytes*height);
            for(unsigned i=0;i<threads_;++i)std::fprintf(stderr," worker%u_start_ms=%.3f worker%u_copy_ms=%.3f",i,timings_[i].start_ms,i,timings_[i].copy_ms);
            std::fprintf(stderr," scope=CPU-wall-includes-descheduling\n");
        }
    }
};
}

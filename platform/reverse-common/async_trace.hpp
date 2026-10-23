#pragma once
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>

namespace vf_diag {
// Bounded, best-effort diagnostics. A slow sink never owns the producer lock.
// Producers serialize only the bounded in-memory copy; contention is not a drop.
// OS scheduling can still delay lock acquisition; this is not a wait-free queue.
// Dropped records invalidate complete-frame statistics and are reported explicitly.
class AsyncTrace {
public:
    using Sink=void(*)(const char*,void*);
    static constexpr size_t line_size=1024,capacity=4096;
private:
    std::array<std::array<char,line_size>,capacity> lines_{};
    std::mutex mutex_;
    std::condition_variable wake_;
    size_t head_{},count_{};
    bool stopping_{};
    std::atomic<unsigned long long> dropped_{};
    Sink sink_;void* context_;
    std::thread worker_;
    void run(){
        unsigned long long written=0;
        for(;;){
            std::array<char,line_size> line;
            {std::unique_lock lock(mutex_);wake_.wait(lock,[&]{return stopping_ || count_;});
             if(!count_ && stopping_)break;
             line=lines_[head_];head_=(head_+1)%capacity;--count_;}
            sink_(line.data(),context_);
            if(++written%256==0){char status[160];std::snprintf(status,sizeof(status),"profile_trace_status written=%llu dropped=%llu\n",written,dropped());sink_(status,context_);}
        }
        char summary[128];std::snprintf(summary,sizeof(summary),"profile_trace_summary dropped=%llu\n",dropped());sink_(summary,context_);
    }
public:
    AsyncTrace(Sink sink,void* context=nullptr):sink_(sink),context_(context),worker_([this]{run();}){}
    AsyncTrace(const AsyncTrace&)=delete;
    ~AsyncTrace(){ {std::lock_guard lock(mutex_);stopping_=true;}wake_.notify_one();worker_.join(); }
    bool push(const char* line){
        const auto length=std::strlen(line);
        if(length>=line_size){++dropped_;return false;}
        {std::lock_guard lock(mutex_);
         if(stopping_ || count_==capacity){++dropped_;return false;}
         std::memcpy(lines_[(head_+count_)%capacity].data(),line,length+1);++count_;}
        wake_.notify_one();return true;
    }
    unsigned long long dropped()const{return dropped_.load();}
};
}

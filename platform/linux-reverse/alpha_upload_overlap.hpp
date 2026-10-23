#pragma once
#include "bgra_alpha.hpp"
#include <condition_variable>
#include <exception>
#include <mutex>
#include <thread>

namespace viewflow::reverse {
// The caller retains both spans and the frame's shared-memory lease until run()
// returns, including on upload failure. Only the caller touches the GL context.
// One sleeping worker, one job, no queued frames or per-frame thread creation.
class AlphaUploadOverlap {
    std::mutex mutex_;
    std::condition_variable work_,done_;
    bool stop_{},pending_{};
    std::span<const std::uint8_t> source_;
    std::span<std::uint8_t> target_;
    std::exception_ptr error_;
    std::thread worker_;
    void loop() {
        std::unique_lock lock(mutex_);
        for(;;) {
            work_.wait(lock,[&]{return stop_ || pending_;});
            if(stop_)return;
            const auto source=source_;const auto target=target_;
            lock.unlock();
            std::exception_ptr error;
            try {extract_bgra_alpha(source,target);}catch(...){error=std::current_exception();}
            lock.lock();error_=error;pending_=false;done_.notify_one();
        }
    }
    void join_job() {
        std::unique_lock lock(mutex_);done_.wait(lock,[&]{return !pending_;});
    }
public:
    AlphaUploadOverlap():worker_([this]{loop();}){}
    ~AlphaUploadOverlap() {
        {std::lock_guard lock(mutex_);stop_=true;}
        work_.notify_one();worker_.join();
    }
    template<class Upload> void run(std::span<const std::uint8_t> source,std::span<std::uint8_t> target,Upload upload) {
        // Validate before starting either operation.
        if(source.size()%4 || source.size()/4!=target.size())throw std::runtime_error("BGRA alpha extent");
        {std::lock_guard lock(mutex_);source_=source;target_=target;error_=nullptr;pending_=true;}
        work_.notify_one();
        try {upload();}catch(...) {join_job();throw;}
        join_job();if(error_)std::rethrow_exception(error_);
    }
};
}

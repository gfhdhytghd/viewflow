#pragma once
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
#ifdef __APPLE__
#include <pthread/qos.h>
#endif

namespace viewflow::macos {
// A fixed thread keeps CoreVideo pools and Metal extraction resources local to
// one owner. A serial GCD queue can migrate across threads and duplicate them.
class SerialWorker {
    std::mutex mutex_;
    std::condition_variable changed_;
    std::function<void()> pending_;
    bool stopping_{};
    std::thread worker_;
public:
    SerialWorker() : worker_([this] {
#ifdef __APPLE__
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
        for (;;) {
            std::function<void()> work;
            {
                std::unique_lock lock(mutex_);
                changed_.wait(lock, [&] { return stopping_ || bool(pending_); });
                if (!pending_) return;
                work = std::move(pending_);
                pending_ = {};
                changed_.notify_all();
            }
            work();
        }
    }) {}
    SerialWorker(const SerialWorker&) = delete;
    SerialWorker& operator=(const SerialWorker&) = delete;
    ~SerialWorker() {
        { std::lock_guard lock(mutex_); stopping_ = true; }
        changed_.notify_all();
        worker_.join();
    }
    bool submit(std::function<void()> work) {
        std::lock_guard lock(mutex_);
        if (stopping_ || pending_ || !work) return false;
        pending_ = std::move(work);
        changed_.notify_all();
        return true;
    }
    bool submit_wait(std::function<void()> work) {
        std::unique_lock lock(mutex_);
        changed_.wait(lock, [&] { return stopping_ || !pending_; });
        if (stopping_ || !work) return false;
        pending_ = std::move(work);
        changed_.notify_all();
        return true;
    }
};
}

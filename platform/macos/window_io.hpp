#pragma once
#include "../reverse-common/pipe_io.hpp"
#include <atomic>
#include <condition_variable>
#include <deque>
#include <fcntl.h>
#include <functional>
#include <mutex>
#include <poll.h>
#include <thread>

namespace viewflow::macos {
// Polling here only makes pipe shutdown cancellable. It never expires a frame
// or an input event. The owner skips *unencoded* captures under backpressure.
class Output {
    std::atomic<bool> stopped_{false};
    std::mutex mutex_;
    std::condition_variable changed_;
    std::deque<std::vector<uint8_t>> queue_;
    std::size_t capacity_;
    std::thread worker_;
    int flags_{};
public:
    explicit Output(std::size_t capacity) : capacity_(capacity) {
        flags_ = fcntl(STDOUT_FILENO, F_GETFL);
        if (flags_ < 0 || fcntl(STDOUT_FILENO, F_SETFL, flags_ | O_NONBLOCK) < 0)
            throw std::runtime_error("configure window output pipe");
        worker_ = std::thread([this] {
            while (!stopped_) {
                std::vector<uint8_t> record;
                {
                    std::unique_lock lock(mutex_);
                    changed_.wait(lock, [&] { return stopped_ || !queue_.empty(); });
                    if (stopped_) break;
                    record = std::move(queue_.front()); queue_.pop_front();
                }
                std::span<const uint8_t> bytes(record);
                while (!bytes.empty() && !stopped_) {
                    const auto count = ::write(STDOUT_FILENO, bytes.data(), bytes.size());
                    if (count > 0) { bytes = bytes.subspan(static_cast<size_t>(count)); continue; }
                    if (count < 0 && errno == EINTR) continue;
                    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                        pollfd fd{STDOUT_FILENO, POLLOUT, 0}; poll(&fd, 1, 50); continue;
                    }
                    stopped_ = true;
                }
            }
        });
    }
    ~Output() {
        stopped_ = true; changed_.notify_all();
        if (worker_.joinable()) worker_.join();
        fcntl(STDOUT_FILENO, F_SETFL, flags_);
    }
    bool alive() const { return !stopped_; }
    bool ready() { std::lock_guard lock(mutex_); return !stopped_ && queue_.size() < capacity_; }
    bool push(std::vector<uint8_t> record) {
        reverse::Writer prefix; prefix.u32(static_cast<uint32_t>(record.size()));
        record.insert(record.begin(), prefix.bytes.begin(), prefix.bytes.end());
        std::lock_guard lock(mutex_);
        if (stopped_ || queue_.size() >= capacity_) return false;
        queue_.push_back(std::move(record)); changed_.notify_one(); return true;
    }
};
class Input {
    std::atomic<bool> stopped_{false};
    std::atomic<bool> finished_{false};
    std::thread worker_;
    bool read(void* data, size_t size) {
        auto* bytes = static_cast<uint8_t*>(data);
        while (size && !stopped_) {
            pollfd fd{STDIN_FILENO, POLLIN, 0};
            const int ready = poll(&fd, 1, 50);
            if (ready < 0 && errno == EINTR) continue;
            if (ready == 0) continue;
            if (ready < 0) return false;
            const auto count = ::read(STDIN_FILENO, bytes, size);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) return false;
            bytes += count; size -= count;
        }
        return size == 0;
    }
public:
    // The callback is synchronous and must bound its own UI queue, so a large
    // network burst cannot accumulate unbounded dispatch_async work.
    Input(std::function<void(std::vector<uint8_t>)> record, std::function<void()> ended) {
        worker_ = std::thread([this, record = std::move(record), ended = std::move(ended)] {
            try {
                while (!stopped_) {
                    uint8_t prefix[4]; if (!read(prefix, 4)) break;
                    reverse::Reader reader{prefix}; const auto count = reader.u32();
                    if (count < 4 || count > reverse::max_record) throw std::runtime_error("invalid window record length");
                    std::vector<uint8_t> bytes(count); if (!read(bytes.data(), bytes.size())) break;
                    record(std::move(bytes));
                }
            } catch (const std::exception& error) { std::fprintf(stderr, "window input pipe: %s\n", error.what()); }
            ended(); finished_ = true;
        });
    }
    ~Input() { stopped_ = true; if (worker_.joinable()) worker_.join(); }
    void stop() { stopped_ = true; }
    bool finished() const { return finished_; }
};
}

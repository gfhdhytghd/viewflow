#include "window_worker.hpp"
#include <cassert>
#include <future>
#include <vector>
int main() {
    std::vector<int> order;
    std::thread::id owner;
    std::promise<void> started, release;
    auto released = release.get_future();
    {
        viewflow::macos::SerialWorker worker;
        assert(worker.submit([&] {
            owner = std::this_thread::get_id();
            started.set_value();
            released.wait();
            order.push_back(1);
        }));
        started.get_future().wait();
        assert(worker.submit([&] {
            assert(owner == std::this_thread::get_id());
            order.push_back(2);
        }));
        assert(!worker.submit([] {}));
        release.set_value();
        // Destruction must finish both accepted tasks in order.
    }
    assert((order == std::vector<int>{1, 2}));
    order.clear();
    {
        viewflow::macos::SerialWorker worker;
        std::promise<void> running, unblock;
        auto gate = unblock.get_future();
        assert(worker.submit([&] { running.set_value(); gate.wait(); order.push_back(1); }));
        running.get_future().wait();
        assert(worker.submit([&] { order.push_back(2); }));
        auto producer = std::async(std::launch::async, [&] {
            return worker.submit_wait([&] { order.push_back(3); });
        });
        assert(producer.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout);
        unblock.set_value();
        assert(producer.get());
    }
    assert((order == std::vector<int>{1, 2, 3}));
}

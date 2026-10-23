#pragma once
#include <atomic>
#include <cstdint>
namespace viewflow::reverse {
// A short scheduling preference, never a session lifetime or input boundary.
class ImePriority {
public:
 void activity(std::int64_t now) {active_until_.store(now+500,std::memory_order_release);wake_.fetch_add(1,std::memory_order_release);}
 void first_frame() {urgent_.fetch_add(1,std::memory_order_release);}
 bool active(std::int64_t now)const{return now<active_until_.load(std::memory_order_acquire);}
 std::uint64_t wake()const{return wake_.load(std::memory_order_acquire);}
 std::uint64_t urgent()const{return urgent_.load(std::memory_order_acquire);}
 unsigned inventory_ms(std::int64_t now,bool moving)const{return active(now)||moving?8:50;}
 unsigned pending_limit(std::int64_t now,unsigned normal)const{return active(now)?1:normal;}
private:
 std::atomic<std::int64_t> active_until_{};
 std::atomic<std::uint64_t> wake_{},urgent_{};
};
}

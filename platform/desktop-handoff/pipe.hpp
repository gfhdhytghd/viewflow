#pragma once
#include "core.hpp"
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <cstring>
namespace viewflow::handoff {
// Hook callbacks never wait for network or pipe I/O.
class Output {
    std::mutex mutex;
    std::condition_variable ready;
    std::deque<Input> queue;
    bool stopping{};
    std::thread writer;
public:
    std::function<void()> failed;
    Output():writer([this] {
        try {
            uint64_t seq=0;
            for(;;) {
                Input e;
                {std::unique_lock lock(mutex);ready.wait(lock,[&]{return stopping || !queue.empty();});
                 if(queue.empty()) return;
                 e=queue.front();queue.pop_front();}
                e.sequence=++seq;reverse::write_record(1,reverse::pack_input(e));
            }
        } catch(...) {if(failed)failed();}
    }) {}
    void send(Input e) {
        std::unique_lock lock(mutex);
        if(queue.size()>=4096) {lock.unlock();if(failed)failed();throw std::runtime_error("handoff native queue exhausted");}
        // Coalesce adjacent positions only; never cross key/release boundaries.
        if(kind(e)==1 && !queue.empty() && kind(queue.back())==1) queue.back()=e;
        else queue.push_back(e);
        ready.notify_one();
    }
    ~Output() {{std::lock_guard lock(mutex);stopping=true;}ready.notify_one();writer.join();}
};
inline std::pair<Rect,Rect> geometry(int argc,char** argv) {
    if(argc!=9) throw std::runtime_error("usage: viewflow-desktop-handoff LX LY LW LH RX RY RW RH | --self-test");
    double v[8];for(int i=0;i<8;++i) {
        size_t n{};v[i]=std::stod(argv[i+1],&n);
        if(n!=std::strlen(argv[i+1]) || !std::isfinite(v[i]) || std::abs(v[i])>1000000)
            throw std::runtime_error("invalid handoff geometry");
    }
    return {{v[0],v[1],v[2],v[3]},{v[4],v[5],v[6],v[7]}};
}
}

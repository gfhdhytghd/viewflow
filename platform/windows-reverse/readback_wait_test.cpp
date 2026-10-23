#include "readback_wait.hpp"
#include "capture_wake.hpp"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <vector>
int main() {
    using viewflow::reverse::shm::CaptureWake;
    CaptureWake disabled(false);assert(disabled.wait(0)==WAIT_FAILED);
    CaptureWake wake(true);wake.notify();wake.notify();
    assert(wake.wait(0)==WAIT_OBJECT_0);assert(wake.wait(0)==WAIT_TIMEOUT);
    std::thread notifier([&]{std::this_thread::sleep_for(std::chrono::milliseconds(2));wake.notify();});
    assert(wake.wait(1000)==WAIT_OBJECT_0);notifier.join();assert(wake.wait(0)==WAIT_TIMEOUT);
    using viewflow::reverse::shm::ReadbackWait;
    ReadbackWait fallback(0);assert(!fallback.available());fallback.pause(true);
    ReadbackWait invalid(123);assert(!invalid.available());invalid.pause(false);
    for(unsigned us:{0u,250u,500u}) {
        ReadbackWait wait(us);std::vector<double> samples;
        for(unsigned i=0;i<100;++i) {
            const auto begin=std::chrono::steady_clock::now();wait.pause(true);
            samples.push_back(std::chrono::duration<double,std::micro>(std::chrono::steady_clock::now()-begin).count());
        }
        std::sort(samples.begin(),samples.end());
        std::printf("readback-wait request_us=%u available=%u p50_us=%.3f p95_us=%.3f\n",us,unsigned(wait.available()),samples[50],samples[95]);
        wait.pause(false); // Idle path must remain usable with an allocated timer.
    }
}

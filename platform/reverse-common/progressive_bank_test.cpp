#include "shared_frames.hpp"
#include <cassert>
#include <iostream>
#include <thread>
using namespace viewflow::reverse::shm;
int main(){
    constexpr std::size_t capacity=4096;
    auto* memory=static_cast<std::uint8_t*>(::operator new(header_bytes+slots*capacity,std::align_val_t(64)));
    std::memset(memory,0,header_bytes+slots*capacity);
    Frames writer(memory,header_bytes+slots*capacity),reader(memory,header_bytes+slots*capacity);
    std::vector<std::uint8_t> pixels(16*16*4,73);
    auto p=writer.begin_progressive(1,1,16,16);assert(p);auto ref=p->reference();
    auto r=reader.acquire_progressive(ref,16,16,{});assert(r);
    p->append(pixels,64,16);p->finish();p.reset();
    // Hold all remaining physical banks with legacy readers.
    std::vector<std::shared_ptr<viewflow::reverse::SharedPixels>> legacy;
    for(unsigned i=0;i<3;++i){auto bytes=writer.publish(1,i+2,16,16,pixels.data(),64);assert(!bytes.empty());auto lease=reader.acquire(bytes,16,16,{});assert(lease);legacy.push_back(lease);}
    assert(!writer.begin_write(1,9,16,16));assert(!writer.begin_progressive(1,9,16,16));
    writer.recover(true);assert(!writer.begin_write(1,9,16,16));
    assert(r->prefix()[0]==73);r.reset();
    auto old=writer.begin_write(1,9,16,16);assert(old);old.reset();
    // Ready references may be retired without waiting for their delivery.
    p=writer.begin_progressive(2,1,16,16);assert(p);ref=p->reference();p->append(pixels,64,16);p->finish();p.reset();
    old=writer.begin_write(2,2,16,16);assert(old);assert(!reader.acquire_progressive(ref,16,16,{}));old.reset();
    // Aborted producer keeps bank reserved until the active reader releases.
    p=writer.begin_progressive(3,1,16,16);assert(p);r=reader.acquire_progressive(p->reference(),16,16,{});assert(r);
    p->append(pixels,64,8);p.reset();assert(r->aborted());assert(!writer.begin_write(3,2,16,16));
    r.reset();old=writer.begin_write(3,2,16,16);assert(old);old.reset();
    for(unsigned turn=0;turn<200;++turn){
        p=writer.begin_progressive(4,turn+1,16,16);assert(p);ref=p->reference();
        p->append(pixels,64,16);p->finish();p.reset();
        std::atomic<bool> go=false;
        std::thread competing([&]{while(!go.load(std::memory_order_acquire))std::this_thread::yield();r=reader.acquire_progressive(ref,16,16,{});});
        go.store(true,std::memory_order_release);old=writer.begin_write(5,turn+1,16,16);competing.join();
        if(r){assert(!old);assert(r->prefix()[0]==73);r.reset();}
        else {assert(old);old.reset();}
    }
    legacy.clear();::operator delete(memory,std::align_val_t(64));
    std::cout<<"cross_protocol_ownership=passed stale_reference=passed abort_dma_lease=passed\n";
}

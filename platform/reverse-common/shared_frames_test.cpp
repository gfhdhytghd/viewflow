#include "shared_frames.hpp"
#include <cassert>
#include <thread>
#include <mutex>
#include <deque>
#include <iostream>
#include <cstdlib>
#ifndef _WIN32
#include <sys/mman.h>
#endif
using namespace viewflow::reverse;
int main(){
    {
        // Simulate external completion on CPU; this verifies slot publication,
        // not GPU synchronization or actual IVSHMEM visibility.
        alignas(64) std::array<std::uint8_t,shm::header_bytes+4*4096> memory{};
        shm::Frames frames(memory.data(),memory.size());
        auto write=frames.begin_write(8,1,64,2);assert(write);
        auto dest=write->external_destination();assert(dest.size()==512);
        const auto ref=shm::pack({8,1,write->slot_index(),64,2,4096});
        auto reject=[](auto fn){bool failed=false;try{fn();}catch(const std::runtime_error&){failed=true;}assert(failed);};
        reject([&]{write->finish();});
        reject([&]{write->append(dest.data(),256,2);});
        reject([&]{write->complete_external(512);});
        assert(!frames.acquire(ref,64,2));
        std::fill(dest.begin(),dest.end(),0x7b);
        write->complete_external(256);
        assert(!frames.acquire(ref,64,2)); // Completion alone does not publish.
        reject([&]{write->complete_external(256);});
        auto published=write->finish();auto read=frames.acquire(published,64,2);
        assert(read && read->data()[0]==0x7b && read->data()[511]==0x7b);
        reject([&]{write->external_destination();});
        auto cpu=frames.begin_write(8,2,64,2);assert(cpu);
        reject([&]{cpu->complete_external(256);});
        cpu->append(dest.data(),256,1);
        reject([&]{cpu->external_destination();});
        auto cancel=frames.begin_write(8,3,64,2);assert(cancel);
        cancel->external_destination();cancel.reset(); // No external work pending.
        assert(read->data()[0]==0x7b);
    }
    {
        alignas(64) std::array<std::uint8_t,shm::header_bytes+4*4096> memory{};
        shm::Frames bands(memory.data(),memory.size());
        std::array<std::uint8_t,48> source{};for(unsigned i=0;i<source.size();++i)source[i]=i;
        auto w=bands.begin_write(9,1,4,3);assert(w);
        const auto reference=shm::pack({9,1,0,4,3,4096});
        w->append(source.data(),16,1);assert(!bands.acquire(reference,4,3));
        bool rejected=false;try{w->finish();}catch(const std::runtime_error&){rejected=true;}assert(rejected);
        rejected=false;try{w->append(source.data(),16,3);}catch(const std::runtime_error&){rejected=true;}assert(rejected);
        w->append(source.data()+16,16,2);auto ready=w->finish();auto read=bands.acquire(ready,4,3);assert(read && !std::memcmp(read->data(),source.data(),48));
        rejected=false;try{w->finish();}catch(const std::runtime_error&){rejected=true;}assert(rejected);
        auto canceled=bands.begin_write(9,2,4,3);assert(canceled);canceled->append(source.data(),16,1);canceled.reset();
        // A held completed reader stays valid while another partial write aborts.
        assert(!std::memcmp(read->data(),source.data(),48));
        std::array<std::unique_ptr<shm::Frames::Write>,3> pending;
        for(auto& p:pending){p=bands.begin_write(9,3,4,3);assert(p);}
        assert(!bands.begin_write(9,4,4,3));
        pending[0].reset();assert(bands.begin_write(9,5,4,3));
    }

#ifndef _WIN32
    // Reserve the PCI-sized virtual aperture without committing 8 GiB of RAM.
    constexpr std::size_t aperture=std::size_t(8)<<30;
    auto* sparse=mmap(nullptr,aperture,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE,-1,0);
    assert(sparse!=MAP_FAILED);
    {
        shm::Frames big(sparse,aperture);
        assert(big.fits(16384,16384));assert(!big.fits(16385,1));assert(!big.fits(1,16385));
        std::vector<std::uint8_t> narrow(16384*2*4,0x71);
        for(unsigned i=0;i<4;++i){auto r=big.publish(100,i+1,16384,2,narrow.data(),16384*4);assert(shm::unpack(r).capacity==shm::max_slot_bytes);assert(*big.read(r,16384,2)==narrow);}
        Frame full;full.codec=3;full.width=full.height=16384;full.keyframe=true;
        full.color=shm::pack({100,5,0,16384,16384,shm::max_slot_bytes});
        assert(unpack_frame(pack_frame(full)).width==16384);
        full.width=16385;bool bad=false;try{pack_frame(full);}catch(...){bad=true;}assert(bad);
    }
    munmap(sparse,aperture);
#endif
    constexpr std::size_t size=shm::header_bytes+4*65536;
    alignas(4096) std::uint8_t storage[size];auto* memory=storage;std::memset(memory,0,size);
    shm::Frames producer(memory,size),consumer(memory,size);
    // Independent BARs must preserve slot rotation and never address pixel
    // bytes relative to the small metadata BAR.
    {
        alignas(64) std::uint8_t control[shm::header_bytes]{};
        alignas(64) std::uint8_t bank0[65536]{},bank1[65536]{},bank2[65536]{},bank3[65536]{};
        std::array<void*,4> banks{bank0,bank1,bank2,bank3};
        shm::Frames writer(control,sizeof(control),banks,65536),reader(control,sizeof(control),banks,65536);
        reader.reader_ready(true);assert(writer.reader_ready());
        for(unsigned i=0;i<4;++i){
            std::vector<std::uint8_t> input(64*64*4,0x40+i);
            auto reference=writer.publish(9,i+1,64,64,input.data(),256);
            assert(shm::unpack(reference).slot==i);
            assert(static_cast<std::uint8_t*>(banks[i])[0]==0x40+i);
            assert(*reader.read(reference,64,64)==input);
        }
        assert(control[shm::header_bytes-1]==0);
        bool bad=false;try{shm::Frames invalid(control,sizeof(control),banks,shm::max_slot_bytes+64);}catch(...){bad=true;}assert(bad);
    }
    std::vector<std::uint8_t> pixels(64*64*4,0x53);
    auto ref=producer.publish(1,1,64,64,pixels.data(),256);
    auto read=consumer.read(ref,64,64);assert(read && *read==pixels);assert(!consumer.read(ref,64,64));
    auto stale=producer.publish(1,2,64,64,pixels.data(),256);
    for(unsigned i=0;i<8;++i)producer.publish(1,3+i,64,64,pixels.data(),256);
    assert(!consumer.read(stale,64,64));
    bool rejected=false;try{consumer.read(ref,63,64);}catch(...){rejected=true;}assert(rejected);
    assert(!producer.fits(8192,8192));
    shm::Frames different_extent(memory,size/2);
    different_extent.reader_ready(true);assert(!producer.reader_ready());different_extent.reader_ready(false);
    rejected=false;try{different_extent.read(ref,64,64);}catch(...){rejected=true;}assert(rejected);
    producer.reader_ready(true);assert(consumer.reader_ready());producer.reader_ready(false);assert(!consumer.reader_ready());
    // No writer may steal a slot while a consumer copies it, including restarts.
    for(unsigned i=0;i<shm::slots;++i)std::atomic_ref(reinterpret_cast<shm::Slot*>(memory)[i].state).store(3);
    assert(producer.publish(2,1,64,64,pixels.data(),256).empty());producer.recover(true);
    assert(producer.publish(2,1,64,64,pixels.data(),256).empty());consumer.recover(false);
    auto recovered=producer.publish(2,1,64,64,pixels.data(),256);assert(!recovered.empty());
    // A zero-copy lease retains mapping ownership and excludes overwrite until
    // its last reference is dropped, including a displaced queued frame.
    {
        auto lifetime=std::make_shared<int>(7);std::weak_ptr<int> weak=lifetime;
        auto lease=consumer.acquire(recovered,64,64,lifetime);assert(lease);
        lifetime.reset();assert(!weak.expired());
        const auto index=shm::unpack(recovered).slot;
        assert(lease->data()==memory+shm::header_bytes+index*65536);
        for(unsigned i=0;i<20;++i){auto r=producer.publish(7,i+1,64,64,pixels.data(),256);assert(!r.empty());assert(shm::unpack(r).slot!=index);}
        for(auto b:lease->bytes)assert(b==0x53);
        assert(!consumer.acquire(recovered,64,64));
        auto alias=lease;lease.reset();assert(!weak.expired());alias.reset();assert(weak.expired());
        assert(std::atomic_ref(reinterpret_cast<shm::Slot*>(memory)[index].state).load()==0);
    }
    // Pitched rows must not copy padding into the next row.
    std::vector<std::uint8_t> pitched(320*64,0xcc);
    for(unsigned y=0;y<64;++y)std::memset(pitched.data()+y*320,y,256);
    ref=producer.publish(2,1,64,64,pitched.data(),320);read=consumer.read(ref,64,64);
    assert(read);for(unsigned y=0;y<64;++y)for(unsigned x=0;x<256;++x)assert((*read)[y*256+x]==y);
    // Streaming publication: odd row sizes/pitch exercise alignment and tails.
    {
        constexpr unsigned w=1025,h=257,pitch=w*4+13;
        constexpr std::size_t extent=shm::header_bytes+shm::slots*(std::size_t(2)<<20);
        std::vector<std::uint8_t> storage(extent+4095);auto* block=reinterpret_cast<std::uint8_t*>((reinterpret_cast<std::uintptr_t>(storage.data())+4095)&~std::uintptr_t(4095));std::memset(block,0,shm::header_bytes);
        shm::Frames writer(block,extent),reader(block,extent);writer.streaming_writes=true;
        std::vector<std::uint8_t> source(std::size_t(pitch)*h);
        for(std::size_t i=0;i<source.size();++i)source[i]=i%251;
        auto r=writer.publish(42,1,w,h,source.data(),pitch);auto v=reader.read(r,w,h);assert(v);
        for(unsigned y=0;y<h;++y)assert(std::memcmp(v->data()+std::size_t(y)*w*4,source.data()+std::size_t(y)*pitch,w*4)==0);

    }
    // Reusing the helper must not publish unfinished rows or copy row padding.
    for(bool avx2: {false,true})for(unsigned threads: {1u,2u,4u})for(unsigned h: {1u,3u,515u}) {
        shm::ParallelCopy copy(threads,avx2);constexpr unsigned w=513,pitch=w*4+7;
        std::vector<std::uint8_t> input(std::size_t(pitch)*h),output(std::size_t(w)*4*h);
        for(unsigned round=0;round<16;++round){
            for(std::size_t i=0;i<input.size();++i)input[i]=(i+round)%251;
            copy.copy(output.data(),input.data(),w*4,pitch,h);
            for(unsigned y=0;y<h;++y)assert(std::memcmp(output.data()+std::size_t(y)*w*4,input.data()+std::size_t(y)*pitch,w*4)==0);
        }
    }
    // Raw references are self-contained keyframes; no encoded alpha is sent.
    Frame frame;frame.codec=3;frame.width=64;frame.height=64;frame.keyframe=true;frame.color=ref;
    auto unpacked=unpack_frame(pack_frame(frame));assert(unpacked.color==ref && unpacked.alpha.empty());
    std::mutex mutex;std::deque<std::vector<std::uint8_t>> queue;std::atomic<bool> done=false;unsigned received=0;
    std::thread writer([&]{for(unsigned i=1;i<=12000;++i){std::fill(pixels.begin(),pixels.end(),i%251);auto r=producer.publish(3,i,64,64,pixels.data(),256);if(!r.empty()){std::lock_guard lock(mutex);queue.push_back(std::move(r));}}done=true;});
    for(;;){std::vector<std::uint8_t> r;{std::lock_guard lock(mutex);if(!queue.empty()){r=std::move(queue.front());queue.pop_front();}else if(done)break;}if(r.empty()){std::this_thread::yield();continue;}auto v=consumer.read(r,64,64);if(!v)continue;const auto expected=shm::unpack(r).sequence%251;for(auto b:*v)assert(b==expected);++received;}
    writer.join();assert(received>0);std::cout<<"shared_frames: ownership, overwrite, pitch, wire, concurrent integrity passed; received="<<received<<"\n";
}

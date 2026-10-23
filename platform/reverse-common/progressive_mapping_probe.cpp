// Standalone CPU visibility diagnostic. Never run beside normal endpoints.
#define VIEWFLOW_PROGRESSIVE_STORAGE_PROBE 1
#ifdef _WIN32
#include "../windows-reverse/shared_mapping.hpp"
#else
#include "../linux-reverse/shared_mapping.hpp"
#endif
#ifdef VIEWFLOW_PROGRESSIVE_GPU_PROBE
#include "../linux-reverse/progressive_cuda_probe.hpp"
#endif
#ifdef VIEWFLOW_PROGRESSIVE_TEXTURE_PROBE
#include "../linux-reverse/progressive_texture_probe.hpp"
#endif
#include <chrono>
#include <thread>
#include <iostream>
using namespace viewflow::reverse::shm;
int main(int argc,char** argv){try{
    if(argc!=3)throw std::runtime_error("usage: probe mapping-or-device epoch");
#ifdef _WIN32
    constexpr bool writer=true;
    auto mapping=std::make_shared<Mapping>(unsigned(std::stoul(argv[1])));
#else
    constexpr bool writer=false;
    auto mapping=std::make_shared<Mapping>(argv[1]);
#endif
    auto frames=mapping->frames();auto& header=frames.probe_header(0);
    header.recover(writer);
#ifdef VIEWFLOW_PROGRESSIVE_GPU_PROBE
    ProgressiveCudaProbe gpu(std::size_t(6144)*3456*4);
#endif
#ifdef VIEWFLOW_PROGRESSIVE_TEXTURE_PROBE
    ProgressiveTextureProbe texture;
#endif
    ProgressiveProbe handshake(&frames.progressive_negotiation(),writer);
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(30);
    auto wait=[&]{if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("diagnostic timeout");std::this_thread::sleep_for(std::chrono::milliseconds(1));};
    while(!handshake.poll())wait();
    auto storage=frames.probe_storage(0,mapping);
    ProgressiveReference ref{std::stoull(argv[2]),1,frames.probe_capacity(),0,6144,3456};
    constexpr std::size_t row=6144*4,total=row*3456;
    if(writer){
        auto lease=storage.begin(ref);if(!lease)throw std::runtime_error("bank busy");
        std::vector<std::uint8_t> band(row*128);
        for(unsigned y=0;y<3456;y+=128){
            const unsigned rows=std::min(128u,3456-y);
            for(std::size_t i=0;i<rows*row;++i){auto offset=y*row+i;band[i]=std::uint8_t((offset>>12)^offset^ref.epoch);}
            lease->append(band,row,rows);wait();
        }
        lease->finish();
        // Keep negotiation alive until the reader has verified/released its lease.
        auto& n=frames.progressive_negotiation();while(n.get(n.reader.nonce))wait();
        std::cout<<"writer bytes="<<total<<" completed=1\n";
    }else{
        auto packed=pack_progressive(ref);std::shared_ptr<ProgressiveStorage::Read> lease;
        while(!(lease=storage.acquire(packed)))wait();
#ifdef VIEWFLOW_PROGRESSIVE_GPU_PROBE
        gpu.retain(lease);
#endif
#ifdef VIEWFLOW_PROGRESSIVE_TEXTURE_PROBE
        texture.begin(lease);
#endif
        std::size_t checked=0;unsigned partial=0;
        for(;;){
            if(lease->aborted())throw std::runtime_error("writer aborted");
#ifdef VIEWFLOW_PROGRESSIVE_GPU_PROBE
            gpu.observe_early([&]{return lease->prefix().size()<total;});
#endif
#ifdef VIEWFLOW_PROGRESSIVE_TEXTURE_PROBE
            texture.poll();
#endif
            auto prefix=lease->prefix();
#ifdef VIEWFLOW_PROGRESSIVE_GPU_PROBE
            gpu.append(prefix);
#endif
            if(prefix.size()>checked && prefix.size()<total)++partial;
            for(;checked<prefix.size();++checked)if(prefix[checked]!=std::uint8_t((checked>>12)^checked^ref.epoch))throw std::runtime_error("pixel mismatch at "+std::to_string(checked));
            if(lease->complete() && checked==total)break;
            wait();
        }
#ifdef VIEWFLOW_PROGRESSIVE_GPU_PROBE
        auto result=gpu.readback();
        for(std::size_t i=0;i<result.size();++i)if(result[i]!=std::uint8_t((i>>12)^i^ref.epoch))throw std::runtime_error("GPU pixel mismatch at "+std::to_string(i));
        std::cout<<"gpu_bytes="<<result.size()<<" gpu_bands="<<gpu.bands()<<" first_dma_completed_before_full_prefix="<<gpu.early_completion()<<" gpu_mismatches=0 dma_drained=1\n";
#endif
#ifdef VIEWFLOW_PROGRESSIVE_TEXTURE_PROBE
        while(!texture.poll())wait();
        auto texture_bytes=texture.readback(ref.width,ref.height);
        for(std::size_t i=0;i<texture_bytes.size();++i)if(texture_bytes[i]!=std::uint8_t((i>>12)^i^ref.epoch))throw std::runtime_error("texture mismatch at "+std::to_string(i));
        std::cout<<"texture_bytes="<<texture_bytes.size()<<" texture_polls="<<texture.polls()<<" texture_mismatches=0 complete_before_visible=1\n";
#endif
        if(!partial)throw std::runtime_error("no partial prefix observed");
        std::cout<<"reader bytes="<<checked<<" partial_prefixes="<<partial<<" mismatches=0 completed=1\n";
    }
    return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}

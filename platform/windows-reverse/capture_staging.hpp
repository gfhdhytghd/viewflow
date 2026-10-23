#pragma once
#include <d3d11.h>
#include <wrl/client.h>
#include <array>
#include <chrono>
#include <memory>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

namespace viewflow::reverse::shm {
struct CapturedStaging {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    Microsoft::WRL::ComPtr<ID3D11Query> done,clock,first,last;
    bool sampled{};
    unsigned width{},height{};
    std::chrono::steady_clock::time_point enqueued;
};
// Caller serializes capture and selection with the source mutex. A readback
// retains a shared lease until CPU Unmap completes. Never overwrite that lease.
// The current slot can be reused if only the pool and source own it: all prior
// GPU atlas reads were queued under the same mutex on the same D3D context.
class CaptureStaging {
    std::array<std::shared_ptr<CapturedStaging>,3> slots_;
    bool gpu_timing_=[]{const auto* v=std::getenv("VIEWFLOW_SHM_GPU_TIMING");return v && std::strcmp(v,"1")==0;}();
    unsigned submitted_{};
public:
    struct Timing {double prepare_ms{},copy_ms{},end_ms{},flush_ms{};};
    std::shared_ptr<CapturedStaging> copy(ID3D11Device* device,ID3D11DeviceContext* context,ID3D11Texture2D* source,const D3D11_BOX& crop,const std::shared_ptr<CapturedStaging>& current,Timing* timing=nullptr) {
        using Clock=std::chrono::steady_clock;
        const auto begin=timing?Clock::now():Clock::time_point{};
        std::shared_ptr<CapturedStaging> slot;
        for(auto& candidate:slots_)if(candidate && (candidate.use_count()==1 || (candidate==current && candidate.use_count()==2))){slot=candidate;break;}
        if(!slot)for(auto& candidate:slots_)if(!candidate){candidate=std::make_shared<CapturedStaging>();slot=candidate;break;}
        if(!slot)return {}; // All slots are leased; retain the last snapshot.
        const auto width=crop.right-crop.left,height=crop.bottom-crop.top;
        D3D11_TEXTURE2D_DESC desc{};source->GetDesc(&desc);
        if(!width || !height || crop.right>desc.Width || crop.bottom>desc.Height || desc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM)throw std::runtime_error("capture staging extent");
        if(!slot->texture || slot->width!=width || slot->height!=height) {
            desc.Width=width;desc.Height=height;desc.MipLevels=1;desc.ArraySize=1;
            desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=desc.MiscFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
            Microsoft::WRL::ComPtr<ID3D11Texture2D> replacement;
            if(FAILED(device->CreateTexture2D(&desc,nullptr,&replacement)))throw std::runtime_error("capture staging allocation");
            slot->texture=std::move(replacement);slot->width=width;slot->height=height;
        }
        if(!slot->done){D3D11_QUERY_DESC q{D3D11_QUERY_EVENT,0};if(FAILED(device->CreateQuery(&q,&slot->done)))throw std::runtime_error("capture staging completion query");}
        slot->sampled=gpu_timing_ && (++submitted_%20==0);
        if(slot->sampled && !slot->clock) {
            D3D11_QUERY_DESC q{D3D11_QUERY_TIMESTAMP_DISJOINT,0};
            auto hr=device->CreateQuery(&q,&slot->clock);q.Query=D3D11_QUERY_TIMESTAMP;
            if(SUCCEEDED(hr))hr=device->CreateQuery(&q,&slot->first);
            if(SUCCEEDED(hr))hr=device->CreateQuery(&q,&slot->last);
            if(FAILED(hr)){slot->clock.Reset();slot->first.Reset();slot->last.Reset();slot->sampled=false;gpu_timing_=false;}
        }
        const auto prepared=timing?Clock::now():Clock::time_point{};
        if(slot->sampled){context->Begin(slot->clock.Get());context->End(slot->first.Get());}
        context->CopySubresourceRegion(slot->texture.Get(),0,0,0,0,source,0,&crop);
        if(slot->sampled){context->End(slot->last.Get());context->End(slot->clock.Get());}
        const auto copied=timing?Clock::now():Clock::time_point{};
        context->End(slot->done.Get());
        const auto ended=timing?Clock::now():Clock::time_point{};
        context->Flush();slot->enqueued=Clock::now();
        if(timing){const auto ms=[](auto a,auto b){return std::chrono::duration<double,std::milli>(b-a).count();};
            *timing={ms(begin,prepared),ms(prepared,copied),ms(copied,ended),ms(ended,slot->enqueued)};}
        return slot;
    }
};
}

#pragma once
#include <d3d11_4.h>
#include <wrl/client.h>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>
#include "readback_wait.hpp"

// Diagnostic fence observation. CPU observation is an upper bound on GPU
// completion, not a calibrated GPU timestamp or composition/presentation proof.
class FixtureGpuProbe {
    using Clock=std::chrono::steady_clock;
    struct Record {unsigned sequence;std::int64_t generated,submitted,observed;};
    Microsoft::WRL::ComPtr<ID3D11DeviceContext4> context_;
    Microsoft::WRL::ComPtr<ID3D11Fence> fence_;
    std::mutex mutex_;std::condition_variable wake_;
    std::deque<Record> pending_;std::vector<Record> records_;
    bool stopping_{};unsigned dropped_{};HRESULT status_=S_FALSE;
    std::thread worker_;
    static std::int64_t qpc(){LARGE_INTEGER q{},f{};QueryPerformanceCounter(&q);QueryPerformanceFrequency(&f);return q.QuadPart/f.QuadPart*10000000+(q.QuadPart%f.QuadPart)*10000000/f.QuadPart;}
    void run(){
        viewflow::reverse::shm::ReadbackWait wait(250);auto stop_deadline=Clock::time_point::max();
        for(;;){
            {std::unique_lock lock(mutex_);wake_.wait(lock,[&]{return stopping_ || !pending_.empty();});
             if(stopping_ && stop_deadline==Clock::time_point::max())stop_deadline=Clock::now()+std::chrono::milliseconds(100);
             if(pending_.empty() || Clock::now()>=stop_deadline)break;}
            const auto completed=fence_->GetCompletedValue();const auto observed=qpc();
            {std::lock_guard lock(mutex_);
             if(completed==~UINT64(0)){status_=DXGI_ERROR_DEVICE_REMOVED;break;}
             while(!pending_.empty() && UINT64(pending_.front().sequence)+1<=completed){auto r=pending_.front();pending_.pop_front();r.observed=observed;records_.push_back(r);}}
            wait.pause(true);
        }
    }
public:
    FixtureGpuProbe(ID3D11Device* device,ID3D11DeviceContext* context,bool enabled){
        if(!enabled)return;
        Microsoft::WRL::ComPtr<ID3D11Device5> d;
        status_=device->QueryInterface(IID_PPV_ARGS(&d));if(FAILED(status_))return;
        status_=context->QueryInterface(IID_PPV_ARGS(&context_));if(FAILED(status_))return;
        status_=d->CreateFence(0,D3D11_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence_));if(FAILED(status_))return;
        records_.reserve(8192);worker_=std::thread([this]{run();});
    }
    ~FixtureGpuProbe(){finish();}
    void submit(unsigned sequence,std::int64_t generated){
        if(!worker_.joinable())return;
        std::lock_guard lock(mutex_);
        if(FAILED(status_))return;
        if(pending_.size()>=128 || records_.size()+pending_.size()>=8192){++dropped_;return;}
        const auto hr=context_->Signal(fence_.Get(),UINT64(sequence)+1);
        if(FAILED(hr)){status_=hr;return;}
        pending_.push_back({sequence,generated,qpc(),0});wake_.notify_one();
    }
    void finish(){if(worker_.joinable()){{std::lock_guard lock(mutex_);stopping_=true;}wake_.notify_one();worker_.join();}}
    void report(){finish();std::fprintf(stderr,"motion-gpu-summary hr=0x%08lx observed=%zu pending=%zu dropped=%u scope=cpu-observed-fence-upper-bound\n",static_cast<unsigned long>(status_),records_.size(),pending_.size(),dropped_);
        for(const auto& r:records_)std::fprintf(stderr,"motion-gpu sequence=%u generated=%lld submitted=%lld observed=%lld\n",r.sequence,static_cast<long long>(r.generated),static_cast<long long>(r.submitted),static_cast<long long>(r.observed));}
};

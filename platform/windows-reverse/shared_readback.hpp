#pragma once
#include "diagnostics.hpp"
#include "../reverse-common/fixture_stamp.hpp"
#include "shared_mapping.hpp"
#include "capture_staging.hpp"
#include "banded_staging.hpp"
#include "readback_supersession.hpp"
#include <d3d11.h>
#include <wrl/client.h>
#include <array>
#include <optional>
#include <random>
#include <chrono>
#include <cstdlib>
#include <cstdio>

namespace viewflow::reverse::shm {
class Readback {
    using Texture=Microsoft::WRL::ComPtr<ID3D11Texture2D>;
    struct Pending {bool early_sent{};std::unique_ptr<BandPublication> band_publication;Texture texture;std::shared_ptr<CapturedStaging> external;Microsoft::WRL::ComPtr<ID3D11Query> done,clock,first,last;bool sampled{};std::optional<Frame> frame;std::chrono::steady_clock::time_point enqueued;};
    std::array<Pending,2> pending_;
    Frames& frames_;std::uint64_t epoch_,sequence_{},submitted_{};
public:
    struct Timing {double map_ms{},publish_ms{},ready_ms{},gpu_copy_ms=-1;};
    Timing last_timing;
    // Enable only after both endpoints negotiated SHM2. Default remains SHM1.
    bool progressive=false;
    bool measure=false;bool single_pending=false;bool measure_gpu=false;bool latest_ready=false;
    std::uint64_t superseded_frames{};
    explicit Readback(Frames& frames):frames_(frames) {
        std::random_device random;epoch_=(std::uint64_t(random())<<32)|random();if(!epoch_)epoch_=1;
    }
    bool idle() const {for(const auto& p:pending_)if(p.frame)return false;return true;}
    bool available() const {if(single_pending)return idle();for(const auto& p:pending_)if(!p.frame)return true;return false;}
    bool enqueue(ID3D11Device* device,ID3D11DeviceContext* context,ID3D11Texture2D* texture,Frame frame) {
        if(!available())return false;
        if(!frames_.fits(frame.width,frame.height))throw std::runtime_error("IVSHMEM slot too small for atlas");
        for(auto& p:pending_)if(!p.frame) {
            D3D11_TEXTURE2D_DESC desc{};texture->GetDesc(&desc);
            if(desc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM || desc.Width!=frame.width || desc.Height!=frame.height)throw std::runtime_error("IVSHMEM BGRA texture layout");
            D3D11_TEXTURE2D_DESC old{};if(p.texture)p.texture->GetDesc(&old);
            if(!p.texture || old.Width!=desc.Width || old.Height!=desc.Height) {
                p.texture.Reset();desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;desc.MiscFlags=0;
                if(FAILED(device->CreateTexture2D(&desc,nullptr,&p.texture)))throw std::runtime_error("IVSHMEM staging allocation");
            }
            if(!p.done){D3D11_QUERY_DESC query{D3D11_QUERY_EVENT,0};if(FAILED(device->CreateQuery(&query,&p.done)))throw std::runtime_error("IVSHMEM completion query");}
            p.sampled=measure_gpu && (++submitted_%20==0);
            if(p.sampled && !p.clock) {
                D3D11_QUERY_DESC q{D3D11_QUERY_TIMESTAMP_DISJOINT,0};
                auto hr=device->CreateQuery(&q,&p.clock);q.Query=D3D11_QUERY_TIMESTAMP;
                if(SUCCEEDED(hr))hr=device->CreateQuery(&q,&p.first);
                if(SUCCEEDED(hr))hr=device->CreateQuery(&q,&p.last);
                if(FAILED(hr)){p.clock.Reset();p.first.Reset();p.last.Reset();p.sampled=false;}
            }
            if(p.sampled){context->Begin(p.clock.Get());context->End(p.first.Get());}
            context->CopyResource(p.texture.Get(),texture);
            if(p.sampled){context->End(p.last.Get());context->End(p.clock.Get());}
            context->End(p.done.Get());context->Flush();
            frame.codec=codec;frame.keyframe=true;frame.alpha.clear();p.frame=std::move(frame);if(measure)p.enqueued=std::chrono::steady_clock::now();return true;
        }
        return false;
    }
    bool adopt(std::shared_ptr<CapturedStaging> captured,Frame frame) {
        if(!available())return false;
        if(!captured || !captured->texture || !captured->done || captured->width!=frame.width || captured->height!=frame.height || !frames_.fits(frame.width,frame.height))throw std::runtime_error("capture staging adoption extent");
        for(auto& p:pending_)if(!p.frame) {
            p.external=std::move(captured);p.sampled=false;p.enqueued=p.external->enqueued;
            frame.codec=codec;frame.keyframe=true;frame.alpha.clear();p.frame=std::move(frame);return true;
        }
        return false;
    }
    bool adopt_bands(std::shared_ptr<CapturedBands> captured,Frame frame) {
        if(!available())return false;
        if(!captured || captured->width!=frame.width || captured->height!=frame.height || !frames_.fits(frame.width,frame.height))throw std::runtime_error("band adoption extent");
        for(auto& p:pending_)if(!p.frame){
            if(progressive){
                auto write=frames_.begin_progressive(epoch_,++sequence_,frame.width,frame.height);if(!write)return false;
                p.band_publication=std::make_unique<BandPublication>(std::move(captured),std::move(write));
            }else{
                auto write=frames_.begin_write(epoch_,++sequence_,frame.width,frame.height);if(!write)return false;
                p.band_publication=std::make_unique<BandPublication>(std::move(captured),std::move(write));
            }
            p.early_sent=false;
            p.enqueued=std::chrono::steady_clock::now();frame.codec=codec;frame.keyframe=true;frame.alpha.clear();p.frame=std::move(frame);return true;
        }
        return false;
    }
    template<class Publish> void poll(ID3D11DeviceContext* context,Publish publish) {
        // Drain in timestamp order even when staging buffers are reused.
        for(;;){
            Pending* p=nullptr;for(auto& candidate:pending_)if(candidate.frame && (!p || candidate.frame->pts<p->frame->pts))p=&candidate;
            if(!p)return;
            if(p->band_publication){
                if(!p->early_sent)if(auto early=p->band_publication->early_reference()){
                    auto announced=*p->frame;announced.color=std::move(*early);
                    last_timing={-1,-1,-1,-1};publish(announced);p->early_sent=true;
                }
                auto reference=p->band_publication->poll(context);if(!reference)return;
                auto frame=std::move(*p->frame);frame.color=std::move(*reference);
                last_timing={p->band_publication->map_ms,p->band_publication->publish_ms,-1,-1};
                const auto stamp=p->band_publication->pixel_stamp;
                const bool trace=std::getenv("VIEWFLOW_SHM_BAND_TRACE")!=nullptr;
                const bool deferred=std::getenv("VIEWFLOW_SHM_DEFER_BAND_TRACE")!=nullptr;
                const auto diagnostic_begin=std::chrono::steady_clock::now();
                const auto overlap=p->band_publication->first_copy_before_last_ready;
                const auto query=p->band_publication->query_max_ms,gap=p->band_publication->poll_gap_max_ms,first=p->band_publication->first_poll_ms,unmap=p->band_publication->unmap_max_ms;
                const auto band_times=p->band_publication->band_times;
                const auto band_count=p->band_publication->band_time_count;
                const auto diagnostics=[&]{
                    for(unsigned i=0;i<band_count;++i){const auto& b=band_times[i];vf_diag::trace("profile_band_publish pts=%lld row_begin=%u row_end=%u copy_begin_qpc=%lld published_qpc=%lld scope=CPU-prefix-published\n",frame.pts,b.row_begin,b.row_end,static_cast<long long>(b.copy_begin),static_cast<long long>(b.published));}
                    if(overlap)vf_diag::trace("profile_band_overlap pts=%lld first_copy_before_last_ready=%u query_max_ms=%.3f poll_gap_max_ms=%.3f first_poll_ms=%.3f unmap_max_ms=%.3f\n",frame.pts,unsigned(*overlap),query,gap,first,unmap);
                    if(stamp)vf_diag::trace("profile_pixel_stamp pts=%lld sequence=%llu generated_qpc_100ns=%llu\n",frame.pts,static_cast<unsigned long long>(stamp->sequence),static_cast<unsigned long long>(stamp->qpc100ns));
                };
                if(!deferred)diagnostics();
                const bool early_sent=p->early_sent;
                p->frame.reset();p->band_publication.reset();p->early_sent=false;
                const auto diagnostic_ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-diagnostic_begin).count();
                if(!early_sent)publish(frame);
                else vf_diag::trace("profile_shared_completed pts=%lld map_ms=%.3f publish_ms=%.3f payload=shm2\n",frame.pts,last_timing.map_ms,last_timing.publish_ms);
                const auto deferred_begin=std::chrono::steady_clock::now();
                if(deferred)diagnostics();
                const auto deferred_ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-deferred_begin).count();
                if(trace)vf_diag::trace("profile_band_diagnostic pts=%lld pre_publish_ms=%.3f deferred_ms=%.3f\n",frame.pts,diagnostic_ms,deferred_ms);
                continue;
            }
            auto* texture=p->external?p->external->texture.Get():p->texture.Get();
            auto* completion=p->external?p->external->done.Get():p->done.Get();
            BOOL done=FALSE;const auto ready=context->GetData(completion,&done,sizeof(done),D3D11_ASYNC_GETDATA_DONOTFLUSH);
            if(FAILED(ready))throw std::runtime_error("IVSHMEM GPU completion failed");
            if(ready==S_FALSE || !done)return;
            if(latest_ready)for(auto& newer:pending_) {
                if(&newer==p || !newer.frame || newer.band_publication || !supersedes_readback(*newer.frame,*p->frame))continue;
                auto* newer_completion=newer.external?newer.external->done.Get():newer.done.Get();
                BOOL newer_done=FALSE;
                const auto newer_ready=context->GetData(newer_completion,&newer_done,sizeof(newer_done),D3D11_ASYNC_GETDATA_DONOTFLUSH);
                if(FAILED(newer_ready))throw std::runtime_error("IVSHMEM GPU completion failed");
                if(newer_ready!=S_OK || !newer_done)continue;
                // Both GPU operations completed. Releasing the old lease cannot
                // expose an in-flight surface to pool reuse. Metadata is equal.
                p->frame.reset();p->external.reset();++superseded_frames;p=&newer;
                texture=p->external?p->external->texture.Get():p->texture.Get();
            }
            const auto map_begin=measure?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};
            D3D11_MAPPED_SUBRESOURCE mapped{};const auto status=context->Map(texture,0,D3D11_MAP_READ,D3D11_MAP_FLAG_DO_NOT_WAIT,&mapped);
            if(status==DXGI_ERROR_WAS_STILL_DRAWING)return;
            if(FAILED(status))throw std::runtime_error("IVSHMEM staging map failed");
            const auto map_end=measure?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};
            struct Unmap {
                ID3D11DeviceContext* c;ID3D11Texture2D* t;Pending* p;
                void release(){if(t){c->Unmap(t,0);t=nullptr;p->external.reset();}}
                ~Unmap(){release();}
            } unmap{context,texture,p};
            auto frame=std::move(*p->frame);p->frame.reset();
            const auto publish_begin=measure?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};
            frame.color=frames_.publish(epoch_,++sequence_,frame.width,frame.height,mapped.pData,mapped.RowPitch);
            if(measure){const auto end=std::chrono::steady_clock::now();last_timing={std::chrono::duration<double,std::milli>(map_end-map_begin).count(),std::chrono::duration<double,std::milli>(end-publish_begin).count(),std::chrono::duration<double,std::milli>(map_begin-p->enqueued).count()};}
            const bool sampled=p->external?p->external->sampled:p->sampled;
            if(measure && sampled) {
                auto* clock_query=p->external?p->external->clock.Get():p->clock.Get();
                auto* first_query=p->external?p->external->first.Get():p->first.Get();
                auto* last_query=p->external?p->external->last.Get():p->last.Get();
                D3D11_QUERY_DATA_TIMESTAMP_DISJOINT clock{};UINT64 first{},last{};
                const auto flags=D3D11_ASYNC_GETDATA_DONOTFLUSH;
                if(context->GetData(clock_query,&clock,sizeof(clock),flags)==S_OK && !clock.Disjoint && clock.Frequency &&
                   context->GetData(first_query,&first,sizeof(first),flags)==S_OK && context->GetData(last_query,&last,sizeof(last),flags)==S_OK && last>=first)
                    last_timing.gpu_copy_ms=double(last-first)*1000./clock.Frequency;
            }
            std::optional<fixture_stamp::Stamp> pixel_stamp;
            if(std::getenv("VIEWFLOW_FIXTURE_PIXEL_STAMP") && frame.width>=fixture_stamp::width)
                pixel_stamp=fixture_stamp::decode({static_cast<const std::uint8_t*>(mapped.pData),fixture_stamp::width*4});
            // The shared-memory slot now owns an independent pixel snapshot.
            // Transport backpressure must not retain a mapped capture surface.
            unmap.release();
            if(pixel_stamp)vf_diag::trace("profile_pixel_stamp pts=%lld sequence=%llu generated_qpc_100ns=%llu\n",frame.pts,static_cast<unsigned long long>(pixel_stamp->sequence),static_cast<unsigned long long>(pixel_stamp->qpc100ns));
            if(!frame.color.empty())publish(frame);
        }
    }
};
}

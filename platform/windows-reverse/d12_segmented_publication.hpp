#pragma once
#include "d12_segmented_copy.hpp"
#include "shared_mapping.hpp"
#include <chrono>
#include "diagnostics.hpp"

namespace viewflow::reverse::d12 {
// A single SHM1 transaction spans asynchronous host segment mapping and GPU copy.
// The source snapshot and writing slot remain owned while the host is pending.
class PendingSegmentedPublication final {
public:
    enum class Status { idle, pending, published, error };
private:
    std::shared_ptr<shm::Mapping> mapping_;
    std::shared_ptr<shm::Frames> frames_;
    Microsoft::WRL::ComPtr<ID3D12Device3> device_;
    std::array<std::array<std::shared_ptr<ExternalHeap>,shm::dma_segments_per_bank>,shm::slots> heaps_{};
    std::array<std::array<std::shared_ptr<ExternalBuffer>,shm::dma_segments_per_bank>,shm::slots> buffers_{};
    std::shared_ptr<void> source_lease_;
    Microsoft::WRL::ComPtr<ID3D12Resource> source_;
    Microsoft::WRL::ComPtr<ID3D12Fence> producer_fence_;
    UINT64 producer_value_ = 0, bytes_ = 0;
    std::size_t pitch_ = 0;
    std::unique_ptr<shm::Frames::Write> write_;
    bool submitted_ = false;
    using Clock=std::chrono::steady_clock;
    Clock::time_point host_wait_started_{};
    Clock::time_point host_ready_{}, import_done_{}, submit_begin_{}, submit_end_{}, producer_seen_{}, last_poll_{};
    std::uint64_t trace_sequence_=0, poll_count_=0;
    double max_poll_gap_ms_=0;
    static double milliseconds(Clock::time_point a,Clock::time_point b) noexcept {
        return std::chrono::duration<double,std::milli>(b-a).count();
    }
    void observe_producer() noexcept {
        if(!vf_diag::metrics() || producer_seen_!=Clock::time_point{})return;
        if(!producer_fence_){producer_seen_=Clock::now();return;}
        const auto completed=producer_fence_->GetCompletedValue();
        if(completed!=(std::numeric_limits<UINT64>::max)() && completed>=producer_value_)producer_seen_=Clock::now();
    }
    // Keeper/host mapping operation watchdog, NOT a frame latency target.
    // Applies exclusively before any GPU command is submitted for this slot.
    static constexpr auto host_mapping_watchdog=std::chrono::seconds(5);
    HRESULT error_ = S_OK;
    const char* diagnostic_ = "not initialized";
    SegmentedCopy copy_; // destroys/drains before any transaction/source owner.
    HRESULT fail(HRESULT hr,const char* text) noexcept {error_=hr;diagnostic_=text;return hr;}
    void release() noexcept {
        write_.reset(); source_.Reset(); producer_fence_.Reset();source_lease_.reset();
        producer_value_=0;bytes_=0;pitch_=0;submitted_=false;host_wait_started_={};
    }
    HRESULT advance() noexcept {
        observe_producer();
        if(submitted_)return S_OK;
        const auto slot=write_->slot_index();
        const auto ready=mapping_->request_segments(slot,bytes_);
        if(ready==shm::DmaMappingStatus::pending) {
            if(Clock::now()-host_wait_started_>=host_mapping_watchdog) {
                // No DMA exists yet: release only this local writer reservation.
                // Keep host request bits: a late successful mapping is reusable.
                release();return fail(HRESULT_FROM_WIN32(ERROR_TIMEOUT),"host mapping 5s operation watchdog; no GPU submitted; CPU fallback");
            }
            return fail(S_FALSE,"host segment mapping pending; source and slot retained");
        }
        if(ready!=shm::DmaMappingStatus::ready) {
            release();return fail(ready==shm::DmaMappingStatus::failed?E_FAIL:E_INVALIDARG,"host segment mapping failed/identity changed; local fallback");
        }
        if(vf_diag::metrics())host_ready_=Clock::now();
        try {
            const unsigned count=static_cast<unsigned>((bytes_+shm::dma_segment_bytes-1)/shm::dma_segment_bytes);
            std::vector<std::shared_ptr<ExternalBuffer>> destination;destination.reserve(count);
            for(unsigned i=0;i<count;++i) {
                auto& heap=heaps_[slot][i];auto& buffer=buffers_[slot][i];
                const auto view=shm::Mapping::segment(mapping_,slot,i);
                const char* stage=nullptr;
                if(!heap) {
                    const HRESULT hr=ExternalHeap::open(device_.Get(),view.base,view.bytes,view.owner,heap,stage);
                    if(FAILED(hr)){release();return fail(hr,stage);}
                }
                if(heap->address()!=view.base || heap->mapped_bytes()!=shm::dma_segment_bytes) {
                    release();return fail(E_INVALIDARG,"segment cached heap address/extent mismatch");
                }
                if(!buffer) {
                    D3D12_RESOURCE_DESC desc{};desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;
                    desc.Alignment=D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;desc.Width=shm::dma_segment_bytes;
                    desc.Height=1;desc.DepthOrArraySize=1;desc.MipLevels=1;desc.SampleDesc.Count=1;
                    desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_CROSS_ADAPTER;
                    const HRESULT hr=ExternalBuffer::create(heap,0,desc,D3D12_RESOURCE_STATE_COPY_DEST,buffer,stage);
                    if(FAILED(hr)){release();return fail(hr,stage);}
                }
                destination.push_back(buffer);
            }
            if(vf_diag::metrics()){import_done_=Clock::now();observe_producer();submit_begin_=Clock::now();}
            const HRESULT hr=copy_.submit(source_.Get(),destination,producer_fence_.Get(),producer_value_,source_lease_);
            if(vf_diag::metrics())submit_end_=Clock::now();
            submitted_=copy_.in_flight();
            if(FAILED(hr) && !submitted_)release();
            return fail(hr,copy_.diagnostic());
        }catch(const std::bad_alloc&){release();return fail(E_OUTOFMEMORY,"segment owner allocation");}
         catch(const std::exception&){release();return fail(E_FAIL,"segment device map unavailable");}
    }
public:
    PendingSegmentedPublication(std::shared_ptr<shm::Frames> frames,std::shared_ptr<shm::Mapping> mapping)
        :mapping_(std::move(mapping)),frames_(std::move(frames)){}
    PendingSegmentedPublication(const PendingSegmentedPublication&)=delete;
    PendingSegmentedPublication& operator=(const PendingSegmentedPublication&)=delete;
    ~PendingSegmentedPublication(){cancel();}
    HRESULT initialize(ID3D12Device3* device) noexcept {
        if(!frames_ || !mapping_ || !mapping_->supports_segmented_dma() || !device || device_)
            return fail(E_INVALIDARG,"segmented publication initialize/host descriptor");
        const HRESULT hr=copy_.initialize(device);
        if(FAILED(hr))return fail(hr,copy_.diagnostic());
        device_=device;return fail(S_OK,"segmented publication ready");
    }
    bool active() const noexcept{return bool(write_);}
    HRESULT last_error() const noexcept{return error_;}
    const char* diagnostic() const noexcept{return diagnostic_;}
    HRESULT begin(ID3D12Resource* source,std::uint64_t epoch,std::uint64_t sequence,
                  std::shared_ptr<void> source_lease,ID3D12Fence* producer_fence=nullptr,UINT64 producer_value=0) noexcept {
        if(write_)return fail(S_FALSE,"segmented publication busy");
        if(!device_ || !source || !source_lease)return fail(E_INVALIDARG,"segmented source/lease/device");
        const auto desc=source->GetDesc();
        if(desc.Dimension!=D3D12_RESOURCE_DIMENSION_TEXTURE2D || desc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM ||
            desc.Width>16384 || desc.Width%128 || desc.Height>16384 || desc.MipLevels!=1 ||
            desc.DepthOrArraySize!=1 || desc.SampleDesc.Count!=1 || !frames_->fits(static_cast<unsigned>(desc.Width),desc.Height))
            return fail(E_INVALIDARG,"unsupported tight segmented BGRA source");
        try {
            write_=frames_->begin_write(epoch,sequence,static_cast<unsigned>(desc.Width),desc.Height);
            if(!write_)return fail(S_FALSE,"no free logical SHM slot");
            bytes_=desc.Width*desc.Height*4;pitch_=static_cast<std::size_t>(desc.Width*4);
            host_wait_started_=Clock::now();
            host_ready_={};import_done_={};submit_begin_={};submit_end_={};producer_seen_={};last_poll_={};
            trace_sequence_=sequence;poll_count_=0;max_poll_gap_ms_=0;
            const auto cpu_span=write_->external_destination();
            if(cpu_span.size()!=bytes_) {release();return fail(E_INVALIDARG,"logical image extent mismatch");}
            // No CPU-vs-segment pointer equality: host identity declares aliases.
            source_=source;source_lease_=std::move(source_lease);producer_fence_=producer_fence;producer_value_=producer_value;
            const HRESULT hr=advance();
            // Host pending is an accepted transaction, unlike no free slot.
            return hr==S_FALSE?S_OK:hr;
        }catch(const std::bad_alloc&){release();return fail(E_OUTOFMEMORY,"segmented transaction allocation");}
         catch(const std::exception&){release();return fail(E_INVALIDARG,"segmented Frames reservation rejected");}
    }
    Status poll(std::vector<std::uint8_t>& reference,DWORD wait_ms=0) noexcept {
        if(!reference.empty()){fail(E_INVALIDARG,"reference output must be empty");return Status::error;}
        if(!write_)return Status::idle;
        if(vf_diag::metrics()) {
            const auto now=Clock::now();++poll_count_;
            if(last_poll_!=Clock::time_point{})max_poll_gap_ms_=(std::max)(max_poll_gap_ms_,milliseconds(last_poll_,now));
            last_poll_=now;observe_producer();
        }
        if(!submitted_) {
            const HRESULT hr=advance();
            if(hr==S_FALSE)return Status::pending;
            if(FAILED(hr) && !submitted_)return Status::error;
        }
        const bool gpu_timing=copy_.completion_timing().frequency>0;
        LARGE_INTEGER poll_begin{},poll_end{};
        if(gpu_timing)QueryPerformanceCounter(&poll_begin);
        const auto status=wait_ms?copy_.wait(wait_ms):copy_.poll();
        if(gpu_timing)QueryPerformanceCounter(&poll_end);
        if(status==SegmentedCopy::Status::pending)return Status::pending;
        if(status==SegmentedCopy::Status::device_lost){release();fail(copy_.last_error(),copy_.diagnostic());return Status::error;}
        if(gpu_timing) {
            const auto& t=copy_.completion_timing();LARGE_INTEGER publication_observed{};QueryPerformanceCounter(&publication_observed);
            vf_diag::trace("profile_d12_publication_observation sequence=%llu slot=%u frequency=%lld poll_begin_qpc=%lld poll_end_qpc=%lld fence_observed_qpc=%lld timing_report_end_qpc=%lld lease_release_end_qpc=%lld publication_observed_qpc=%lld scope=CPU-observation-includes-copy-diagnostics-before-SHM-publication\n",
                static_cast<unsigned long long>(trace_sequence_),write_->slot_index(),static_cast<long long>(t.frequency),poll_begin.QuadPart,poll_end.QuadPart,
                static_cast<long long>(t.fence_observed),static_cast<long long>(t.report_end),static_cast<long long>(t.release_end),publication_observed.QuadPart);
        }
        if(vf_diag::metrics()) {
            const auto done=Clock::now();observe_producer();
            vf_diag::trace("profile_d12_stages sequence=%llu slot=%u bytes=%llu host_wait_ms=%.3f import_ms=%.3f submit_cpu_ms=%.3f producer_observed_ms=%.3f consumer_observed_ms=%.3f polls=%llu max_poll_gap_ms=%.3f scope=CPU-fence-observation-upper-bounds-not-GPU-timestamps\n",
                static_cast<unsigned long long>(trace_sequence_),write_->slot_index(),static_cast<unsigned long long>(bytes_),
                milliseconds(host_wait_started_,host_ready_),milliseconds(host_ready_,import_done_),milliseconds(submit_begin_,submit_end_),
                producer_seen_==Clock::time_point{}?-1:milliseconds(host_wait_started_,producer_seen_),milliseconds(submit_end_,done),
                static_cast<unsigned long long>(poll_count_),max_poll_gap_ms_);
        }
        try {
            write_->complete_external(pitch_);reference=write_->finish();release();
            fail(S_OK,"segmented GPU completed; SHM1 reference published");return Status::published;
        }catch(const std::bad_alloc&){release();fail(E_OUTOFMEMORY,"segmented reference allocation");return Status::error;}
         catch(const std::exception&){release();fail(E_INVALIDARG,"segmented completion rejected");return Status::error;}
    }
    void cancel() noexcept {
        while(copy_.in_flight() && copy_.wait(100)==SegmentedCopy::Status::pending){}
        release();
    }
};
} // namespace viewflow::reverse::d12

#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "d12_external_heap.hpp"
#include "../reverse-common/segmented_bgra_copy.hpp"
#include <span>
#include <vector>
#include "diagnostics.hpp"

namespace viewflow::reverse::d12 {
// Single-threaded, one in-flight tight BGRA texture copy into 64 MiB segments. The caller must complete
// source production/synchronization or supply its producer fence. Source must be
// COPY_SOURCE (or COMMON, eligible for implicit promotion) when that fence signals;
// destination must be COPY_DEST and exclusively owned until completion.
// Segment order must match contiguous bank offsets i*64MiB in the host backing.
// Widths not divisible by 128 pixels are explicitly unsupported, so the caller
// can retain the old readback path. No pixel padding changes SHM wire layout.
// This helper neither captures a desktop nor performs D3D11 interop.
class SegmentedCopy final {
public:
    enum class Status { pending, complete, device_lost };
    struct CompletionTiming {
        std::int64_t frequency=0, fence_read_begin=0, fence_observed=0;
        std::int64_t map_begin=0,map_end=0,unmap_end=0,report_end=0,release_end=0;
    };
private:
    Microsoft::WRL::ComPtr<ID3D12Device> device_;
    Microsoft::WRL::ComPtr<ID3D12CommandQueue> queue_;
    Microsoft::WRL::ComPtr<ID3D12CommandAllocator> allocator_;
    Microsoft::WRL::ComPtr<ID3D12GraphicsCommandList> list_;
    Microsoft::WRL::ComPtr<ID3D12Fence> fence_;
    Microsoft::WRL::ComPtr<ID3D12Resource> source_;
    Microsoft::WRL::ComPtr<ID3D12Fence> producer_fence_;
    // Imported COM resources alone do not hold a DD frame or prevent a shared
    // capture pool from overwriting its snapshot. Retain the source lease too.
    std::shared_ptr<void> source_lease_;
    std::vector<std::shared_ptr<ExternalBuffer>> destinations_;
    Microsoft::WRL::ComPtr<ID3D12QueryHeap> timing_heap_;
    Microsoft::WRL::ComPtr<ID3D12Resource> timing_readback_;
    UINT64 timing_frequency_=0;
    bool timing_diagnostics_=false;
    CompletionTiming completion_timing_{};
    static std::int64_t diagnostic_qpc() noexcept {LARGE_INTEGER stamp{};QueryPerformanceCounter(&stamp);return stamp.QuadPart;}
    LARGE_INTEGER submit_qpc_begin_{},submit_qpc_end_{},qpc_frequency_{};
    void initialize_timing() noexcept {
        const auto* enabled=std::getenv("VIEWFLOW_SHM_D12_GPU_TIMING");
        if(!enabled || std::strcmp(enabled,"1")!=0)return;
        timing_diagnostics_=true;
        QueryPerformanceFrequency(&qpc_frequency_);
        D3D12_FEATURE_DATA_D3D12_OPTIONS3 options{};
        HRESULT hr=device_->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS3,&options,sizeof(options));
        if(SUCCEEDED(hr) && !options.CopyQueueTimestampQueriesSupported)hr=E_NOTIMPL;
        if(SUCCEEDED(hr))hr=queue_->GetTimestampFrequency(&timing_frequency_);
        if(SUCCEEDED(hr) && !timing_frequency_)hr=E_FAIL;
        D3D12_QUERY_HEAP_DESC query{};query.Type=D3D12_QUERY_HEAP_TYPE_COPY_QUEUE_TIMESTAMP;query.Count=2;
        if(SUCCEEDED(hr))hr=device_->CreateQueryHeap(&query,IID_PPV_ARGS(timing_heap_.GetAddressOf()));
        D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_READBACK;
        D3D12_RESOURCE_DESC buffer{};buffer.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;buffer.Width=16;buffer.Height=1;
        buffer.DepthOrArraySize=1;buffer.MipLevels=1;buffer.SampleDesc.Count=1;buffer.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        if(SUCCEEDED(hr))hr=device_->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&buffer,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_PPV_ARGS(timing_readback_.GetAddressOf()));
        if(FAILED(hr)){timing_heap_.Reset();timing_readback_.Reset();}
        vf_diag::trace("profile_d12_gpu_timing initialized=%u hr=0x%08lx frequency=%llu scope=copy-queue-supported-query-only\n",unsigned(SUCCEEDED(hr)),static_cast<unsigned long>(hr),static_cast<unsigned long long>(timing_frequency_));
    }
    void report_timing() noexcept {
        if(!timing_readback_)return;
        // Calibration is diagnostic only. Record the CPU call bracket rather
        // than implying exact cross-clock accuracy or subtracting raw GPU/QPC ticks.
        LARGE_INTEGER calibration_begin{},calibration_end{};UINT64 calibration_gpu{},calibration_cpu{};
        QueryPerformanceCounter(&calibration_begin);
        const HRESULT calibration_hr=queue_->GetClockCalibration(&calibration_gpu,&calibration_cpu);
        QueryPerformanceCounter(&calibration_end);
        // Called only after the queue's completion fence, including ResolveQueryData.
        void* data=nullptr;const D3D12_RANGE read{0,16};
        completion_timing_.map_begin=diagnostic_qpc();
        const auto hr=timing_readback_->Map(0,&read,&data);
        completion_timing_.map_end=diagnostic_qpc();
        if(FAILED(hr)) {
            vf_diag::trace("profile_d12_gpu_copy sequence=%llu unavailable_hr=0x%08lx\n",static_cast<unsigned long long>(active_value_),static_cast<unsigned long>(hr));
            timing_heap_.Reset();timing_readback_.Reset();return;
        }
        UINT64 ticks[2]{};std::memcpy(ticks,data,sizeof(ticks));const D3D12_RANGE written{0,0};timing_readback_->Unmap(0,&written);
        completion_timing_.unmap_end=diagnostic_qpc();
        const bool valid=ticks[1]>=ticks[0] && timing_frequency_;
        vf_diag::trace("profile_d12_gpu_copy sequence=%llu queue=%p valid=%u begin=%llu end=%llu frequency=%llu gpu_ms=%.6f commands=%u segments=%u scope=GPU-copy-only-excludes-producer-wait\n",
            static_cast<unsigned long long>(active_value_),queue_.Get(),unsigned(valid),static_cast<unsigned long long>(ticks[0]),static_cast<unsigned long long>(ticks[1]),static_cast<unsigned long long>(timing_frequency_),
            valid?double(ticks[1]-ticks[0])*1000.0/double(timing_frequency_):-1.0,last_commands_,last_segments_);
        const bool calibrated=valid && SUCCEEDED(calibration_hr) && qpc_frequency_.QuadPart>0;
        const auto estimate=[&](UINT64 gpu) {return double(calibration_cpu)+(double(gpu)-double(calibration_gpu))*double(qpc_frequency_.QuadPart)/double(timing_frequency_);};
        const double start_qpc=calibrated?estimate(ticks[0]):-1,end_qpc=calibrated?estimate(ticks[1]):-1;
        vf_diag::trace("profile_d12_clock sequence=%llu queue=%p valid=%u hr=0x%08lx gpu_anchor=%llu qpc_anchor=%llu gpu_frequency=%llu qpc_frequency=%lld calibration_begin_qpc=%lld calibration_end_qpc=%lld submit_begin_qpc=%lld submit_end_qpc=%lld estimated_start_qpc=%.0f estimated_end_qpc=%.0f submit_end_to_gpu_start_ms=%.6f scope=calibrated-estimate-includes-producer-wait-and-queue-scheduling-not-exact-latency\n",
            static_cast<unsigned long long>(active_value_),queue_.Get(),unsigned(calibrated),static_cast<unsigned long>(calibration_hr),static_cast<unsigned long long>(calibration_gpu),static_cast<unsigned long long>(calibration_cpu),static_cast<unsigned long long>(timing_frequency_),qpc_frequency_.QuadPart,
            calibration_begin.QuadPart,calibration_end.QuadPart,submit_qpc_begin_.QuadPart,submit_qpc_end_.QuadPart,start_qpc,end_qpc,
            calibrated?(start_qpc-double(submit_qpc_end_.QuadPart))*1000.0/double(qpc_frequency_.QuadPart):-1.0);
    }
    unsigned last_commands_ = 0, last_segments_ = 0;
    UINT64 next_value_ = 0, active_value_ = 0;
    HANDLE completion_event_ = nullptr;
    UINT64 armed_value_ = 0;
    bool active_ = false, signaled_ = false, poisoned_ = false;
    HRESULT last_error_ = S_OK;
    const char* diagnostic_ = "not initialized";
    void release_active() noexcept {
        source_.Reset(); destinations_.clear(); producer_fence_.Reset();
        source_lease_.reset(); active_ = false;
    }
    HRESULT fail(HRESULT hr, const char* stage) noexcept {
        last_error_ = hr; diagnostic_ = stage; return hr;
    }
public:
    SegmentedCopy() = default;
    SegmentedCopy(const SegmentedCopy&) = delete;
    SegmentedCopy& operator=(const SegmentedCopy&) = delete;
    // No time-based failure cutoff. Never release resources while work may run.
    // On failed Signal, poll retries queue Signal to establish a reliable fence.
    // A permanently stuck device may therefore block destruction until removal.
    ~SegmentedCopy() {
        while (active_ && wait(100) == Status::pending) {}
        if (completion_event_) CloseHandle(completion_event_);
    }
    const CompletionTiming& completion_timing() const noexcept {return completion_timing_;}
    const char* diagnostic() const noexcept { return diagnostic_; }
    HRESULT last_error() const noexcept { return last_error_; }
    bool in_flight() const noexcept { return active_; }
    unsigned command_count() const noexcept { return last_commands_; }
    unsigned segment_count() const noexcept { return last_segments_; }

    HRESULT initialize(ID3D12Device* device) noexcept {
        if (!device || device_) return fail(E_INVALIDARG, "initialize arguments/already initialized");
        device_ = device;
        D3D12_COMMAND_QUEUE_DESC desc{}; desc.Type = D3D12_COMMAND_LIST_TYPE_COPY;
        HRESULT hr=S_OK;
        const auto* high=std::getenv("VIEWFLOW_SHM_D12_HIGH_PRIORITY");
        const bool high_requested=high && std::strcmp(high,"1")==0;
        HRESULT priority_hr=S_OK,high_create_hr=S_FALSE;bool high_supported=false;
        if(high_requested) {
            D3D12_FEATURE_DATA_COMMAND_QUEUE_PRIORITY priority{};
            priority.CommandListType=D3D12_COMMAND_LIST_TYPE_COPY;priority.Priority=D3D12_COMMAND_QUEUE_PRIORITY_HIGH;
            priority_hr=device_->CheckFeatureSupport(D3D12_FEATURE_COMMAND_QUEUE_PRIORITY,&priority,sizeof(priority));
            high_supported=SUCCEEDED(priority_hr) && priority.PriorityForTypeIsSupported;
            if(high_supported) {
                desc.Priority=D3D12_COMMAND_QUEUE_PRIORITY_HIGH;
                high_create_hr=device_->CreateCommandQueue(&desc,IID_PPV_ARGS(queue_.GetAddressOf()));
                if(FAILED(high_create_hr)){queue_.Reset();desc.Priority=D3D12_COMMAND_QUEUE_PRIORITY_NORMAL;}
            }
        }
        if(!queue_)hr=device_->CreateCommandQueue(&desc, IID_PPV_ARGS(queue_.GetAddressOf()));
        vf_diag::trace("reverse-d12 copy-priority requested=%s selected=%s supported=%u feature_hr=0x%08lx high_create_hr=0x%08lx normal_or_selected_hr=0x%08lx\n",
            high_requested?"HIGH":"NORMAL",desc.Priority==D3D12_COMMAND_QUEUE_PRIORITY_HIGH?"HIGH":"NORMAL",unsigned(high_supported),static_cast<unsigned long>(priority_hr),static_cast<unsigned long>(high_create_hr),static_cast<unsigned long>(hr));
        if (FAILED(hr)) return fail(hr, "CreateCommandQueue");
        hr = device_->CreateCommandAllocator(desc.Type, IID_PPV_ARGS(allocator_.GetAddressOf()));
        if (FAILED(hr)) return fail(hr, "CreateCommandAllocator");
        hr = device_->CreateCommandList(0, desc.Type, allocator_.Get(), nullptr,
                                       IID_PPV_ARGS(list_.GetAddressOf()));
        if (FAILED(hr)) return fail(hr, "CreateCommandList");
        hr = list_->Close();
        if (FAILED(hr)) return fail(hr, "Close(initial command list)");
        hr = device_->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(fence_.GetAddressOf()));
        if (FAILED(hr)) return fail(hr, "CreateFence");
        completion_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!completion_event_) return fail(HRESULT_FROM_WIN32(GetLastError()), "CreateEvent(completion)");
        initialize_timing();
        return fail(S_OK, "ready");
    }

    HRESULT submit(ID3D12Resource* source, std::span<const std::shared_ptr<ExternalBuffer>> destinations,
                   ID3D12Fence* producer_fence = nullptr, UINT64 producer_value = 0,
                   std::shared_ptr<void> source_lease = {}) noexcept {
        if (!fence_ || !source || destinations.empty() || active_ || poisoned_)
            return fail(E_INVALIDARG, "submit arguments/busy/unavailable");
        if (next_value_ >= (std::numeric_limits<UINT64>::max)() - 1)
            return fail(E_FAIL, "fence sequence exhausted");
        if ((!producer_fence && producer_value != 0) || producer_value == (std::numeric_limits<UINT64>::max)())
            return fail(E_INVALIDARG, "producer fence/value arguments");
        if (producer_fence) {
            Microsoft::WRL::ComPtr<ID3D12Device> producer_device;
            const HRESULT hr = producer_fence->GetDevice(IID_PPV_ARGS(producer_device.GetAddressOf()));
            if (FAILED(hr)) return fail(hr, "producer fence GetDevice");
            if (producer_device.Get() != device_.Get()) return fail(E_INVALIDARG, "producer fence device mismatch");
        }
        const auto td = source->GetDesc();
        if (td.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D || td.DepthOrArraySize != 1 ||
            td.MipLevels != 1 || td.SampleDesc.Count != 1 || td.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
            !td.Width || td.Width > 16384 || !td.Height || td.Height > 16384 || td.Width % 128)
            return fail(E_INVALIDARG, "submit requires single-subresource BGRA8 texture and 128-pixel aligned width");
        constexpr UINT64 segment_bytes = UINT64(64) << 20;
        const UINT64 image_bytes = td.Width * td.Height * 4;
        const unsigned needed = static_cast<unsigned>((image_bytes + segment_bytes - 1) / segment_bytes);
        if (destinations.size() != needed) return fail(E_INVALIDARG, "exact used-segment count required");
        Microsoft::WRL::ComPtr<ID3D12Device> source_device;
        HRESULT hr = source->GetDevice(IID_PPV_ARGS(source_device.GetAddressOf()));
        if (FAILED(hr)) return fail(hr, "source GetDevice");
        if (source_device.Get() != device_.Get()) return fail(E_INVALIDARG, "source device mismatch");
        for (unsigned i = 0; i < needed; ++i) {
            const auto& buffer = destinations[i];
            const UINT64 used = (std::min)(segment_bytes, image_bytes - UINT64(i) * segment_bytes);
            if (!buffer || buffer->offset() || buffer->heap()->mapped_bytes() != segment_bytes ||
                buffer->heap()->description().SizeInBytes != segment_bytes || buffer->get()->GetDesc().Width < used)
                return fail(E_INVALIDARG, "segment must be independent 64MiB zero-offset heap with sufficient buffer extent");
            Microsoft::WRL::ComPtr<ID3D12Device> destination_device;
            hr = buffer->get()->GetDevice(IID_PPV_ARGS(destination_device.GetAddressOf()));
            if (FAILED(hr)) return fail(hr, "segment GetDevice");
            if (destination_device.Get() != device_.Get()) return fail(E_INVALIDARG, "segment device mismatch");
            for (unsigned previous = 0; previous < i; ++previous)
                if (destinations[previous]->heap()->address() == buffer->heap()->address() ||
                    destinations[previous]->get() == buffer->get())
                    return fail(E_INVALIDARG, "aliased segment resource/address");
        }
        std::vector<SegmentedBgraCopy> plan;
        try {
            plan = plan_segmented_bgra(static_cast<unsigned>(td.Width), td.Height, segment_bytes);
            destinations_.assign(destinations.begin(), destinations.end());
        } catch (const std::bad_alloc&) { destinations_.clear(); return fail(E_OUTOFMEMORY, "segmented copy plan/owner allocation"); }
          catch (const std::invalid_argument&) { return fail(E_INVALIDARG, "unsupported tight segmented footprint"); }
        last_commands_ = static_cast<unsigned>(plan.size()); last_segments_ = needed;
        hr = allocator_->Reset();
        if (FAILED(hr)) { poisoned_ = true; release_active(); return fail(hr, "Reset(allocator)"); }
        hr = list_->Reset(allocator_.Get(), nullptr);
        if (FAILED(hr)) { poisoned_ = true; release_active(); return fail(hr, "Reset(command list)"); }
        if(timing_heap_)list_->EndQuery(timing_heap_.Get(),D3D12_QUERY_TYPE_TIMESTAMP,0);
        D3D12_TEXTURE_COPY_LOCATION from{};
        from.pResource = source; from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        for (const auto& region : plan) {
            D3D12_TEXTURE_COPY_LOCATION to{};
            to.pResource = destinations_[region.segment]->get();
            to.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
            to.PlacedFootprint.Offset = region.destination_offset;
            to.PlacedFootprint.Footprint = {DXGI_FORMAT_B8G8R8A8_UNORM, region.width, region.height, 1, region.row_pitch};
            const D3D12_BOX box{region.source_x, region.source_y, 0,
                               region.source_x + region.width, region.source_y + region.height, 1};
            list_->CopyTextureRegion(&to, 0, 0, 0, &from, &box);
        }
        if(timing_heap_) {
            list_->EndQuery(timing_heap_.Get(),D3D12_QUERY_TYPE_TIMESTAMP,1);
            list_->ResolveQueryData(timing_heap_.Get(),D3D12_QUERY_TYPE_TIMESTAMP,0,2,timing_readback_.Get(),0);
        }
        hr = list_->Close();
        if (FAILED(hr)) { poisoned_ = true; release_active(); return fail(hr, "Close(copy command list)"); }
        // Retain both ends before ExecuteCommandLists can start GPU work.
        source_ = source; producer_fence_ = producer_fence;
        source_lease_ = std::move(source_lease);
        if (producer_fence_) {
            hr = queue_->Wait(producer_fence_.Get(), producer_value);
            if (FAILED(hr)) {
                release_active(); // No copy was executed; caller still owns producer work.
                return fail(hr, "Wait(producer fence)");
            }
        }
        completion_timing_={};
        if(timing_diagnostics_)completion_timing_.frequency=qpc_frequency_.QuadPart;
        active_value_ = ++next_value_;
        active_ = true; signaled_ = false;
        ID3D12CommandList* commands[] = {list_.Get()};
        if(timing_heap_)QueryPerformanceCounter(&submit_qpc_begin_);
        queue_->ExecuteCommandLists(1, commands);
        if(timing_heap_)QueryPerformanceCounter(&submit_qpc_end_);
        hr = queue_->Signal(fence_.Get(), active_value_);
        signaled_ = SUCCEEDED(hr);
        // A failure here still owns in-flight resources. Caller must poll/drain.
        return fail(hr, signaled_ ? "submitted" : "Signal failed; retaining in-flight resources");
    }

    Status poll() noexcept {
        if (!device_) { fail(E_UNEXPECTED, "poll before initialization"); return Status::device_lost; }
        HRESULT removed = device_->GetDeviceRemovedReason();
        const auto fence_read_begin=timing_diagnostics_?diagnostic_qpc():0;
        const UINT64 completed = fence_ ? fence_->GetCompletedValue() : 0;
        const auto fence_read_end=timing_diagnostics_?diagnostic_qpc():0;
        if (FAILED(removed) || completed == (std::numeric_limits<UINT64>::max)()) {
            poisoned_ = true;
            fail(FAILED(removed) ? removed : DXGI_ERROR_DEVICE_REMOVED, "device removed");
            release_active();
            return Status::device_lost;
        }
        if (!active_) return Status::complete;
        if (!signaled_) {
            const HRESULT hr = queue_->Signal(fence_.Get(), active_value_);
            signaled_ = SUCCEEDED(hr);
            fail(hr, signaled_ ? "recovery Signal submitted" : "recovery Signal pending");
            return Status::pending;
        }
        if (completed < active_value_) return Status::pending;
        if(timing_diagnostics_){completion_timing_.fence_read_begin=fence_read_begin;completion_timing_.fence_observed=fence_read_end;}
        report_timing();
        if(timing_diagnostics_)completion_timing_.report_end=diagnostic_qpc();
        release_active();
        if(timing_diagnostics_) {
            completion_timing_.release_end=diagnostic_qpc();
            const auto& t=completion_timing_;
            vf_diag::trace("profile_d12_completion sequence=%llu queue=%p frequency=%lld fence_read_begin_qpc=%lld fence_observed_qpc=%lld map_begin_qpc=%lld map_end_qpc=%lld unmap_end_qpc=%lld timing_report_end_qpc=%lld lease_release_end_qpc=%lld scope=CPU-stages-after-first-completed-fence-observation-zero-means-not-run\n",
                static_cast<unsigned long long>(active_value_),queue_.Get(),static_cast<long long>(t.frequency),static_cast<long long>(t.fence_read_begin),static_cast<long long>(t.fence_observed),
                static_cast<long long>(t.map_begin),static_cast<long long>(t.map_end),static_cast<long long>(t.unmap_end),static_cast<long long>(t.report_end),static_cast<long long>(t.release_end));
        }
        fail(S_OK, "completed");
        return Status::complete;
    }

    // Optional event-driven completion for a capture worker. An observation
    // timeout leaves the copy and its leases alive; it is not a frame deadline.
    // Always check the fence after waking, including stale/spurious event wakes.
    Status wait(DWORD timeout_ms) noexcept {
        auto status = poll();
        if (status != Status::pending || timeout_ms == 0) return status;
        if (completion_event_ && signaled_) {
            if (armed_value_ != active_value_) {
                const HRESULT hr = fence_->SetEventOnCompletion(active_value_, completion_event_);
                if (FAILED(hr)) {
                    fail(hr, "SetEventOnCompletion; copy retained");
                    Sleep(timeout_ms == INFINITE ? 100 : timeout_ms);
                    return poll();
                }
                armed_value_ = active_value_;
            }
            const DWORD result = WaitForSingleObject(completion_event_, timeout_ms);
            if (result == WAIT_FAILED) {
                fail(HRESULT_FROM_WIN32(GetLastError()), "WaitForSingleObject; copy retained");
                Sleep(timeout_ms == INFINITE ? 100 : timeout_ms);
            }
        } else {
            // Failed queue Signal has no reliable completion event yet. Keep
            // retrying via poll without spinning or abandoning submitted work.
            Sleep(timeout_ms == INFINITE ? 100 : timeout_ms);
        }
        return poll();
    }
};
} // namespace viewflow::reverse::d12

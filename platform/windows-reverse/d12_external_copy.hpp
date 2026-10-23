#pragma once
#include "d12_external_heap.hpp"

namespace viewflow::reverse::d12 {
// Single-threaded, one in-flight BGRA texture copy. The caller must complete
// source production/synchronization or supply its producer fence. Source must be
// COPY_SOURCE (or COMMON, eligible for implicit promotion) when that fence signals;
// destination must be COPY_DEST and exclusively owned until completion.
// This helper neither captures a desktop nor performs D3D11 interop.
class ExternalCopy final {
public:
    enum class Status { pending, complete, device_lost };
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
    std::shared_ptr<ExternalBuffer> destination_;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint_{};
    UINT64 next_value_ = 0, active_value_ = 0;
    HANDLE completion_event_ = nullptr;
    UINT64 armed_value_ = 0;
    bool active_ = false, signaled_ = false, poisoned_ = false;
    HRESULT last_error_ = S_OK;
    const char* diagnostic_ = "not initialized";
    void release_active() noexcept {
        source_.Reset(); destination_.reset(); producer_fence_.Reset();
        source_lease_.reset(); active_ = false;
    }
    HRESULT fail(HRESULT hr, const char* stage) noexcept {
        last_error_ = hr; diagnostic_ = stage; return hr;
    }
public:
    ExternalCopy() = default;
    ExternalCopy(const ExternalCopy&) = delete;
    ExternalCopy& operator=(const ExternalCopy&) = delete;
    // No time-based failure cutoff. Never release resources while work may run.
    // On failed Signal, poll retries queue Signal to establish a reliable fence.
    // A permanently stuck device may therefore block destruction until removal.
    ~ExternalCopy() {
        while (active_ && wait(100) == Status::pending) {}
        if (completion_event_) CloseHandle(completion_event_);
    }
    const char* diagnostic() const noexcept { return diagnostic_; }
    HRESULT last_error() const noexcept { return last_error_; }
    bool in_flight() const noexcept { return active_; }
    const D3D12_PLACED_SUBRESOURCE_FOOTPRINT& footprint() const noexcept { return footprint_; }

    HRESULT initialize(ID3D12Device* device) noexcept {
        if (!device || device_) return fail(E_INVALIDARG, "initialize arguments/already initialized");
        device_ = device;
        D3D12_COMMAND_QUEUE_DESC desc{}; desc.Type = D3D12_COMMAND_LIST_TYPE_COPY;
        HRESULT hr = device_->CreateCommandQueue(&desc, IID_PPV_ARGS(queue_.GetAddressOf()));
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
        return fail(S_OK, "ready");
    }

    HRESULT submit(ID3D12Resource* source, std::shared_ptr<ExternalBuffer> destination,
                   ID3D12Fence* producer_fence = nullptr, UINT64 producer_value = 0,
                   std::shared_ptr<void> source_lease = {}) noexcept {
        if (!fence_ || !source || !destination || active_ || poisoned_)
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
            td.MipLevels != 1 || td.SampleDesc.Count != 1 || td.Format != DXGI_FORMAT_B8G8R8A8_UNORM)
            return fail(E_INVALIDARG, "submit requires single-subresource BGRA8 texture");
        Microsoft::WRL::ComPtr<ID3D12Device> source_device, destination_device;
        HRESULT hr = source->GetDevice(IID_PPV_ARGS(source_device.GetAddressOf()));
        if (FAILED(hr)) return fail(hr, "source GetDevice");
        hr = destination->get()->GetDevice(IID_PPV_ARGS(destination_device.GetAddressOf()));
        if (FAILED(hr)) return fail(hr, "destination GetDevice");
        if (source_device.Get() != device_.Get() || destination_device.Get() != device_.Get())
            return fail(E_INVALIDARG, "resource device mismatch");
        UINT rows = 0; UINT64 row_bytes = 0, required = 0;
        device_->GetCopyableFootprints(&td, 0, 1, 0, &footprint_, &rows, &row_bytes, &required);
        if (!required || required == (std::numeric_limits<UINT64>::max)() ||
            rows != td.Height || row_bytes != td.Width * 4 ||
            required > destination->get()->GetDesc().Width)
            return fail(E_INVALIDARG, "destination footprint bounds");
        hr = allocator_->Reset();
        if (FAILED(hr)) { poisoned_ = true; return fail(hr, "Reset(allocator)"); }
        hr = list_->Reset(allocator_.Get(), nullptr);
        if (FAILED(hr)) { poisoned_ = true; return fail(hr, "Reset(command list)"); }
        D3D12_TEXTURE_COPY_LOCATION from{}, to{};
        from.pResource = source;
        from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        to.pResource = destination->get();
        to.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        to.PlacedFootprint = footprint_;
        list_->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
        hr = list_->Close();
        if (FAILED(hr)) { poisoned_ = true; return fail(hr, "Close(copy command list)"); }
        // Retain both ends before ExecuteCommandLists can start GPU work.
        source_ = source; destination_ = std::move(destination); producer_fence_ = producer_fence;
        source_lease_ = std::move(source_lease);
        if (producer_fence_) {
            hr = queue_->Wait(producer_fence_.Get(), producer_value);
            if (FAILED(hr)) {
                release_active(); // No copy was executed; caller still owns producer work.
                return fail(hr, "Wait(producer fence)");
            }
        }
        active_value_ = ++next_value_;
        active_ = true; signaled_ = false;
        ID3D12CommandList* commands[] = {list_.Get()};
        queue_->ExecuteCommandLists(1, commands);
        hr = queue_->Signal(fence_.Get(), active_value_);
        signaled_ = SUCCEEDED(hr);
        // A failure here still owns in-flight resources. Caller must poll/drain.
        return fail(hr, signaled_ ? "submitted" : "Signal failed; retaining in-flight resources");
    }

    Status poll() noexcept {
        if (!device_) { fail(E_UNEXPECTED, "poll before initialization"); return Status::device_lost; }
        HRESULT removed = device_->GetDeviceRemovedReason();
        const UINT64 completed = fence_ ? fence_->GetCompletedValue() : 0;
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
        release_active();
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

#pragma once
#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <array>
#include <memory>
#include <new>
#include <limits>
#include "diagnostics.hpp"

namespace viewflow::reverse::d12 {
// Single-threaded callback bridge. The immediate context must be serialized by
// the caller with all other D3D11 work. No borrowed source survives capture().
class SharedCapture final {
public:
    enum class Role { bridge, wgc_source, dd_source };
    struct Snapshot final {
        Role role=Role::bridge;
        Microsoft::WRL::ComPtr<ID3D11Device> device11;
        Microsoft::WRL::ComPtr<ID3D11DeviceContext4> context11;
        Microsoft::WRL::ComPtr<ID3D11Texture2D> owned11;
        Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> view11;
        Microsoft::WRL::ComPtr<ID3D11Fence> fence11;
        Microsoft::WRL::ComPtr<ID3D12Resource> resource;
        Microsoft::WRL::ComPtr<ID3D12Fence> fence;
        Microsoft::WRL::ComPtr<ID3D11Query> timing_disjoint,timing_begin,timing_end;
        bool timing_pending=false;
        void report_gpu_timing() noexcept {
            if(!timing_pending || !signaled)return;
            const auto completed=fence11->GetCompletedValue();
            if(completed==(std::numeric_limits<UINT64>::max)() || completed<value)return;
            D3D11_QUERY_DATA_TIMESTAMP_DISJOINT disjoint{};UINT64 begin{},end{};
            const auto a=context11->GetData(timing_disjoint.Get(),&disjoint,sizeof(disjoint),D3D11_ASYNC_GETDATA_DONOTFLUSH);
            const auto b=context11->GetData(timing_begin.Get(),&begin,sizeof(begin),D3D11_ASYNC_GETDATA_DONOTFLUSH);
            const auto c=context11->GetData(timing_end.Get(),&end,sizeof(end),D3D11_ASYNC_GETDATA_DONOTFLUSH);
            const bool valid=a==S_OK && b==S_OK && c==S_OK && !disjoint.Disjoint && disjoint.Frequency && end>=begin;
            vf_diag::trace("profile_d11_gpu_copy snapshot=%p sequence=%llu valid=%u disjoint_hr=0x%08lx begin_hr=0x%08lx end_hr=0x%08lx disjoint=%u begin=%llu end=%llu frequency=%llu gpu_ms=%.6f scope=%s\n",
                this,static_cast<unsigned long long>(value),unsigned(valid),static_cast<unsigned long>(a),static_cast<unsigned long>(b),static_cast<unsigned long>(c),unsigned(disjoint.Disjoint),
                static_cast<unsigned long long>(begin),static_cast<unsigned long long>(end),static_cast<unsigned long long>(disjoint.Frequency),valid?double(end-begin)*1000.0/double(disjoint.Frequency):-1.0,
                role==Role::wgc_source?"WGC-to-owned-source-GPU-copy":role==Role::dd_source?"DD-to-owned-source-GPU-copy":"owned-bridge-GPU-copy-not-WGC-source-copy");
            // S_FALSE is unavailable evidence, never a reason to stall/retry work.
            timing_pending=false;
        }
        UINT64 value = 0;
        HANDLE texture_handle = nullptr, fence_handle = nullptr;
        bool submitted = false, signaled = false;
        ~Snapshot() {
            // If callback submission failed after copying, retain storage until
            // a reliable producer completion or device removal, without timeout.
            while (submitted && SUCCEEDED(device11->GetDeviceRemovedReason())) {
                if (signaled && fence11->GetCompletedValue() >= value) break;
                if (!signaled) {
                    signaled = SUCCEEDED(context11->Signal(fence11.Get(), value));
                    context11->Flush();
                }
                Sleep(1);
            }
            report_gpu_timing();
            resource.Reset(); fence.Reset(); view11.Reset(); owned11.Reset(); fence11.Reset();
            if (texture_handle) CloseHandle(texture_handle);
            if (fence_handle) CloseHandle(fence_handle);
        }
        Snapshot() = default;
        Snapshot(const Snapshot&) = delete;
        Snapshot& operator=(const Snapshot&) = delete;
        bool producer_complete() noexcept {
            if (submitted && !signaled && SUCCEEDED(device11->GetDeviceRemovedReason())) {
                signaled = SUCCEEDED(context11->Signal(fence11.Get(), value));
                context11->Flush();
            }
            report_gpu_timing();
            return !submitted || (signaled && fence11->GetCompletedValue() >= value) ||
                   FAILED(device11->GetDeviceRemovedReason());
        }
    };
    enum class Status { ready, busy, error };
private:
    Microsoft::WRL::ComPtr<ID3D11Device> device11_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext4> context11_;
    Microsoft::WRL::ComPtr<ID3D11Device5> device115_;
    Microsoft::WRL::ComPtr<ID3D12Device> device12_;
    std::array<std::shared_ptr<Snapshot>, 4> pool_{}; // Lazy: latest + two consumers + producer.
    Role role_=Role::bridge;
    HRESULT error_ = S_OK;
    const char* diagnostic_ = "not initialized";
    HRESULT fail(HRESULT hr, const char* text) noexcept { error_ = hr; diagnostic_ = text; return hr; }
public:
    SharedCapture() = default;
    SharedCapture(const SharedCapture&) = delete;
    SharedCapture& operator=(const SharedCapture&) = delete;
    HRESULT last_error() const noexcept { return error_; }
    const char* diagnostic() const noexcept { return diagnostic_; }
    HRESULT initialize(ID3D11Device* device11, ID3D11DeviceContext* context11,
                       ID3D12Device* device12,Role role=Role::bridge) noexcept {
        if (!device11 || !context11 || !device12 || device11_)
            return fail(E_INVALIDARG, "initialize arguments/already initialized");
        Microsoft::WRL::ComPtr<ID3D11Device> context_device;
        context11->GetDevice(context_device.GetAddressOf());
        if (context_device.Get() != device11 || context11->GetType() != D3D11_DEVICE_CONTEXT_IMMEDIATE)
            return fail(E_INVALIDARG, "immediate context device mismatch");
        Microsoft::WRL::ComPtr<IDXGIDevice> dxgi;
        Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
        HRESULT hr = device11->QueryInterface(IID_PPV_ARGS(dxgi.GetAddressOf()));
        if (FAILED(hr)) return fail(hr, "D3D11 IDXGIDevice");
        hr = dxgi->GetAdapter(adapter.GetAddressOf());
        if (FAILED(hr)) return fail(hr, "D3D11 GetAdapter");
        DXGI_ADAPTER_DESC desc{};
        hr = adapter->GetDesc(&desc); if (FAILED(hr)) return fail(hr, "D3D11 adapter description");
        const LUID luid = device12->GetAdapterLuid();
        if (luid.HighPart != desc.AdapterLuid.HighPart || luid.LowPart != desc.AdapterLuid.LowPart)
            return fail(E_INVALIDARG, "D3D11/D3D12 adapter mismatch");
        hr = device11->QueryInterface(IID_PPV_ARGS(device115_.GetAddressOf()));
        if (FAILED(hr)) return fail(hr, "QueryInterface(Device5)");
        hr = context11->QueryInterface(IID_PPV_ARGS(context11_.GetAddressOf()));
        if (FAILED(hr)) return fail(hr, "QueryInterface(Context4)");
        device11_ = device11; device12_ = device12;role_=role;
        return fail(S_OK, "ready");
    }
    // Caller MUST keep returned Snapshot alive until the downstream GPU copy
    // fence completes; holding only Snapshot::resource is not sufficient to
    // stop pool reuse. Optional crop is validated and copied into a tight texture.
    Status capture(ID3D11Texture2D* borrowed, std::shared_ptr<Snapshot>& output,
                   const D3D11_BOX* crop = nullptr) noexcept {
        if (!device11_ || !borrowed || output) { fail(E_INVALIDARG, "capture arguments"); return Status::error; }
        HRESULT hr = device11_->GetDeviceRemovedReason();
        if (FAILED(hr)) { fail(hr, "D3D11 device removed"); return Status::error; }
        hr = device12_->GetDeviceRemovedReason();
        if (FAILED(hr)) { fail(hr, "D3D12 device removed"); return Status::error; }
        Microsoft::WRL::ComPtr<ID3D11Device> source_device;
        borrowed->GetDevice(source_device.GetAddressOf());
        if (source_device.Get() != device11_.Get()) { fail(E_INVALIDARG, "source device mismatch"); return Status::error; }
        D3D11_TEXTURE2D_DESC td{}; borrowed->GetDesc(&td);
        if (td.Format != DXGI_FORMAT_B8G8R8A8_UNORM || td.MipLevels != 1 || td.ArraySize != 1 || td.SampleDesc.Count != 1) {
            fail(E_INVALIDARG, "capture requires single-subresource BGRA8 texture"); return Status::error;
        }
        if (crop) {
            if (crop->left >= crop->right || crop->top >= crop->bottom || crop->right > td.Width ||
                crop->bottom > td.Height || crop->front != 0 || crop->back != 1) {
                fail(E_INVALIDARG, "capture crop bounds"); return Status::error;
            }
            td.Width = crop->right - crop->left; td.Height = crop->bottom - crop->top;
        }
        std::shared_ptr<Snapshot>* entry = nullptr;
        for (auto& item : pool_) {
            if (!item || (item.use_count() == 1 && item->producer_complete())) { entry = &item; break; }
        }
        if (!entry) { fail(S_FALSE, "capture pool busy; keep previous frame"); return Status::busy; }
        if (*entry) {
            D3D11_TEXTURE2D_DESC old{}; (*entry)->owned11->GetDesc(&old);
            if (old.Width != td.Width || old.Height != td.Height || (*entry)->value >= (std::numeric_limits<UINT64>::max)() - 1)
                entry->reset();
        }
        if (!*entry) {
            try { *entry = std::make_shared<Snapshot>(); }
            catch (const std::bad_alloc&) { fail(E_OUTOFMEMORY, "snapshot allocation"); return Status::error; }
            auto& fresh = **entry;
            fresh.device11 = device11_; fresh.context11 = context11_;fresh.role=role_;
            td.Usage = D3D11_USAGE_DEFAULT; td.CPUAccessFlags = 0;
            td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
            td.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED;
            hr = device11_->CreateTexture2D(&td, nullptr, fresh.owned11.GetAddressOf());
            const char* stage = "CreateTexture2D(shared owned)";
            if (SUCCEEDED(hr)) { stage = "CreateShaderResourceView(shared owned)"; hr = device11_->CreateShaderResourceView(fresh.owned11.Get(), nullptr, fresh.view11.GetAddressOf()); }
            Microsoft::WRL::ComPtr<IDXGIResource1> shared;
            if (SUCCEEDED(hr)) { stage = "IDXGIResource1"; hr = fresh.owned11.As(&shared); }
            if (SUCCEEDED(hr)) { stage = "CreateSharedHandle(texture)"; hr = shared->CreateSharedHandle(nullptr,
                DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE, nullptr, &fresh.texture_handle); }
            if (SUCCEEDED(hr)) { stage = "CreateFence(shared)"; hr = device115_->CreateFence(0, D3D11_FENCE_FLAG_SHARED,
                IID_PPV_ARGS(fresh.fence11.GetAddressOf())); }
            if (SUCCEEDED(hr)) { stage = "CreateSharedHandle(fence)"; hr = fresh.fence11->CreateSharedHandle(
                nullptr, GENERIC_ALL, nullptr, &fresh.fence_handle); }
            if (SUCCEEDED(hr)) { stage = "OpenSharedHandle(texture)"; hr = device12_->OpenSharedHandle(
                fresh.texture_handle, IID_PPV_ARGS(fresh.resource.GetAddressOf())); }
            if (SUCCEEDED(hr)) { stage = "OpenSharedHandle(fence)"; hr = device12_->OpenSharedHandle(
                fresh.fence_handle, IID_PPV_ARGS(fresh.fence.GetAddressOf())); }
            if (FAILED(hr)) { entry->reset(); fail(hr, stage); return Status::error; }
            const auto* gpu_timing=std::getenv("VIEWFLOW_SHM_D12_GPU_TIMING");
            if(gpu_timing && std::strcmp(gpu_timing,"1")==0) {
                D3D11_QUERY_DESC query{D3D11_QUERY_TIMESTAMP_DISJOINT,0};
                HRESULT timing_hr=device11_->CreateQuery(&query,fresh.timing_disjoint.GetAddressOf());
                query.Query=D3D11_QUERY_TIMESTAMP;
                if(SUCCEEDED(timing_hr))timing_hr=device11_->CreateQuery(&query,fresh.timing_begin.GetAddressOf());
                if(SUCCEEDED(timing_hr))timing_hr=device11_->CreateQuery(&query,fresh.timing_end.GetAddressOf());
                if(FAILED(timing_hr)){fresh.timing_disjoint.Reset();fresh.timing_begin.Reset();fresh.timing_end.Reset();}
                vf_diag::trace("profile_d11_gpu_timing snapshot=%p initialized=%u hr=0x%08lx\n",&fresh,unsigned(SUCCEEDED(timing_hr)),static_cast<unsigned long>(timing_hr));
            }
        }
        auto& snapshot = **entry;
        ++snapshot.value;
        snapshot.submitted = true; snapshot.signaled = false;
        if(snapshot.timing_disjoint) {
            context11_->Begin(snapshot.timing_disjoint.Get());context11_->End(snapshot.timing_begin.Get());snapshot.timing_pending=true;
        }
        if (crop) context11_->CopySubresourceRegion(snapshot.owned11.Get(), 0, 0, 0, 0, borrowed, 0, crop);
        else context11_->CopyResource(snapshot.owned11.Get(), borrowed);
        if(snapshot.timing_disjoint) {context11_->End(snapshot.timing_end.Get());context11_->End(snapshot.timing_disjoint.Get());}
        hr = context11_->Signal(snapshot.fence11.Get(), snapshot.value);
        snapshot.signaled = SUCCEEDED(hr);
        context11_->Flush();
        if (FAILED(hr)) { fail(hr, "Signal(owned capture); retained producer work"); return Status::error; }
        output = *entry;
        fail(S_OK, "owned capture submitted");
        return Status::ready;
    }
};
} // namespace viewflow::reverse::d12

#pragma once
#include "d12_shared_capture.hpp"
#include "d12_publication.hpp"
#include "d12_segmented_publication.hpp"
#include "shared_mapping.hpp"
#include <optional>
#include <random>
#include <chrono>

namespace viewflow::reverse::d12 {
// Opt-in SHM1 lane. Existing readback remains available as a local fallback.
// enqueue is called with ownership/locking of the exact color texture intact.
class SingleTransport final {
public:
    enum class Enqueue { accepted, busy, fallback };
private:
    std::shared_ptr<shm::Mapping> mapping_;
    std::shared_ptr<shm::Frames> frames_;
    Microsoft::WRL::ComPtr<ID3D12Device3> device_;
    SharedCapture capture_;
    PendingPublication::Banks banks_{};
    std::optional<Frame> pending_;
    std::uint64_t epoch_ = 0, sequence_ = 0;
    bool disabled_ = false, failed_frame_ = false, segmented_ = false, retry_cpu_once_ = false;
    using RetryClock=std::chrono::steady_clock;
    RetryClock::time_point segment_retry_at_{};
    static constexpr auto segment_retry_backoff=std::chrono::seconds(2);
    HRESULT error_ = S_OK;
    const char* diagnostic_ = "not initialized";
    PendingPublication publication_; // drains before all source/mapping members.
    std::unique_ptr<PendingSegmentedPublication> segmented_publication_;
    Enqueue fallback(HRESULT hr, const char* stage, bool disable) noexcept {
        error_ = hr; diagnostic_ = stage; disabled_ |= disable; pending_.reset();
        // Failed keeper/import attempts get bounded retry frequency while normal
        // CPU readback continues. This never cancels an in-flight GPU operation.
        if(segmented_ && FAILED(hr) && !disable)segment_retry_at_=RetryClock::now()+segment_retry_backoff;
        return Enqueue::fallback;
    }
public:
    std::uint64_t submitted = 0, published = 0, fallbacks = 0, busy = 0;
    SingleTransport(std::shared_ptr<shm::Frames> frames, std::shared_ptr<shm::Mapping> mapping)
        : mapping_(std::move(mapping)), frames_(std::move(frames)), publication_(frames_, mapping_) {}
    ID3D12Device3* device() const noexcept {return device_.Get();}
    HRESULT initialize(ID3D11Device* device, ID3D11DeviceContext* context, ID3D12Device3* shared_device=nullptr) noexcept {
        if(!mapping_ || (!mapping_->gpu_dma_mapped() && !mapping_->supports_segmented_dma())) {
            const auto hr=HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
            fallback(hr,"host pixel banks are CPU-only/not declared GPU DMA mapped",true);
            return hr;
        }
        Microsoft::WRL::ComPtr<IDXGIDevice> dxgi;
        Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
        HRESULT hr = device->QueryInterface(IID_PPV_ARGS(dxgi.GetAddressOf()));
        if (SUCCEEDED(hr)) hr = dxgi->GetAdapter(adapter.GetAddressOf());
        if (SUCCEEDED(hr)) {
            if(shared_device)device_=shared_device;
            else hr = D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(device_.GetAddressOf()));
        }
        if (FAILED(hr)) { fallback(hr, "same-adapter D3D12 device", true); return hr; }
        hr = capture_.initialize(device, context, device_.Get());
        if (FAILED(hr)) { fallback(hr, capture_.diagnostic(), true); return hr; }
        segmented_=mapping_->supports_segmented_dma();
        if(segmented_) {
            try {segmented_publication_=std::make_unique<PendingSegmentedPublication>(frames_,mapping_);}
            catch(const std::bad_alloc&){fallback(E_OUTOFMEMORY,"segmented publication allocation",true);return E_OUTOFMEMORY;}
            hr=segmented_publication_->initialize(device_.Get());
            if(FAILED(hr)){fallback(hr,segmented_publication_->diagnostic(),true);return hr;}
        }else {
            hr = publication_.initialize(device_.Get());
            if (FAILED(hr)) { fallback(hr, publication_.diagnostic(), true); return hr; }
        }
        // Unique writer epoch; no use of capture timing as a resource cutoff.
        LARGE_INTEGER stamp{}; QueryPerformanceCounter(&stamp);
        epoch_ = static_cast<std::uint64_t>(stamp.QuadPart) ^ (std::uint64_t(GetCurrentProcessId()) << 32) ^
                 static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(this));
        if (!epoch_) epoch_ = 1;
        diagnostic_ = segmented_?"ready; segmented host mapping requested only after slot reservation":"ready; banks imported only when selected"; error_ = S_OK;
        return S_OK;
    }
    bool active() const noexcept { return segmented_publication_?segmented_publication_->active():publication_.active(); }
    bool disabled() const noexcept { return disabled_; }
    HRESULT last_error() const noexcept { return error_; }
    const char* diagnostic() const noexcept { return diagnostic_; }
    bool take_failed_frame() noexcept { const bool value = failed_frame_; failed_frame_ = false; return value; }
    Enqueue enqueue(ID3D11Texture2D* surface, const Frame& metadata) noexcept {
        return enqueue_impl(surface,metadata,{});
    }
    // Immutable producer snapshot. Publication retains its pool lease through
    // consumer GPU completion; queue Wait handles producer readiness on GPU.
    Enqueue enqueue_owned(const std::shared_ptr<SharedCapture::Snapshot>& snapshot,const Frame& metadata) noexcept {
        return enqueue_impl(snapshot?snapshot->owned11.Get():nullptr,metadata,snapshot);
    }
private:
    bool same_device(ID3D12DeviceChild* child) const noexcept {
        if(!child || !device_)return false;
        Microsoft::WRL::ComPtr<IUnknown> expected,actual;
        if(FAILED(device_.As(&expected)))return false;
        Microsoft::WRL::ComPtr<ID3D12Device> owner;
        if(FAILED(child->GetDevice(IID_PPV_ARGS(owner.GetAddressOf()))) || FAILED(owner.As(&actual)))return false;
        return expected.Get()==actual.Get();
    }
    Enqueue enqueue_impl(ID3D11Texture2D* surface, const Frame& metadata,
                         std::shared_ptr<SharedCapture::Snapshot> snapshot) noexcept {
        if (active()) { ++busy; return Enqueue::busy; }
        if(segmented_ && RetryClock::now()<segment_retry_at_) {
            ++fallbacks;return Enqueue::fallback; // preserve original failure diagnostic; do not extend backoff
        }
        if(retry_cpu_once_){retry_cpu_once_=false;++fallbacks;return fallback(S_FALSE,"local segment failure; one CPU frame before retry",false);}
        if (disabled_ || !surface) { ++fallbacks; return Enqueue::fallback; }
        D3D11_TEXTURE2D_DESC desc{}; surface->GetDesc(&desc);
        // Preserve SHM1 tight layout; unsupported/padded widths stay on readback.
        if (desc.Usage != D3D11_USAGE_DEFAULT || desc.Width != metadata.width || desc.Height != metadata.height ||
            desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM || (UINT64(desc.Width) * 4) % (segmented_?512u:D3D12_TEXTURE_DATA_PITCH_ALIGNMENT)) {
            ++fallbacks; return fallback(S_FALSE, "source is not tight DEFAULT BGRA; CPU readback", false);
        }
        if(snapshot) {
            if(!snapshot->submitted || !snapshot->signaled || !snapshot->value ||
               !same_device(snapshot->resource.Get()) || !same_device(snapshot->fence.Get())) {
                ++fallbacks;return fallback(E_INVALIDARG,"owned snapshot producer fence/device mismatch; original path retained",false);
            }
            const auto resource_desc=snapshot->resource->GetDesc();
            if(resource_desc.Dimension!=D3D12_RESOURCE_DIMENSION_TEXTURE2D ||
               resource_desc.Width!=metadata.width || resource_desc.Height!=metadata.height ||
               resource_desc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM || resource_desc.MipLevels!=1 ||
               resource_desc.DepthOrArraySize!=1 || resource_desc.SampleDesc.Count!=1) {
                ++fallbacks;return fallback(E_INVALIDARG,"owned snapshot resource extent/format mismatch",false);
            }
        }
        try {
            pending_ = metadata; // Allocation happens before any DMA submission.
            pending_->codec = shm::codec; pending_->keyframe = true; pending_->alpha.clear();
            if(!snapshot) {
                const auto bridge_begin=RetryClock::now();
                const auto status = capture_.capture(surface, snapshot);
                if(vf_diag::metrics())vf_diag::trace("profile_d12_bridge pts=%lld cpu_ms=%.3f status=%u scope=owned-copy-signal-flush-CPU-wall\n",
                    static_cast<long long>(metadata.pts),std::chrono::duration<double,std::milli>(RetryClock::now()-bridge_begin).count(),unsigned(status));
                if (status == SharedCapture::Status::busy) { pending_.reset(); ++busy; return Enqueue::busy; }
                if (status != SharedCapture::Status::ready) { ++fallbacks; return fallback(capture_.last_error(), capture_.diagnostic(), true); }
            }else if(vf_diag::metrics())vf_diag::trace("profile_d12_adopt pts=%lld producer_value=%llu scope=owned-snapshot-no-bridge-copy\n",
                static_cast<long long>(metadata.pts),static_cast<unsigned long long>(snapshot->value));
            const auto bank = [&](unsigned index) {
                if (!banks_[index]) {
                    const auto view = shm::Mapping::pixel_bank(mapping_, index);
                    const char* stage = nullptr;
                    const HRESULT hr = ExternalHeap::open(device_.Get(), view.base, view.bytes, view.owner, banks_[index], stage);
                    if (FAILED(hr)) { error_ = hr; diagnostic_ = stage; }
                }
                return banks_[index];
            };
            const HRESULT hr = segmented_?
                segmented_publication_->begin(snapshot->resource.Get(),epoch_,++sequence_,snapshot,snapshot->fence.Get(),snapshot->value):
                publication_.begin_with_bank(snapshot->resource.Get(), bank, epoch_, ++sequence_, snapshot,
                                            snapshot->fence.Get(), snapshot->value);
            const char* publication_diagnostic=segmented_?segmented_publication_->diagnostic():publication_.diagnostic();
            if (hr == S_FALSE) { pending_.reset(); ++busy; return Enqueue::busy; }
            if (FAILED(hr) && !active()) {
                ++fallbacks;
                // Preserve import's exact HRESULT if it failed before placement.
                return !segmented_ && FAILED(error_) ? fallback(error_, diagnostic_, true) : fallback(hr, publication_diagnostic, !segmented_);
            }
            error_ = hr; diagnostic_ = publication_diagnostic; ++submitted;
            // Failed Signal can still own DMA; retain metadata and poll recovery.
            return Enqueue::accepted;
        } catch (const std::bad_alloc&) {
            ++fallbacks; return fallback(E_OUTOFMEMORY, "D12 lane metadata allocation", false);
        } catch (const std::exception&) {
            ++fallbacks; return fallback(E_FAIL, "D12 bank mapping unavailable", true);
        }
    }
public:
    bool poll(Frame& output) noexcept {
        if (!pending_) return false;
        std::vector<std::uint8_t> reference;
        if(segmented_) {
            const auto status=segmented_publication_->poll(reference);
            if(status==PendingSegmentedPublication::Status::pending)return false;
            if(status!=PendingSegmentedPublication::Status::published) {
                failed_frame_=true;retry_cpu_once_=true;
                fallback(segmented_publication_->last_error(),segmented_publication_->diagnostic(),false);return false;
            }
        }else {
            const auto status = publication_.poll(reference);
            if (status == PendingPublication::Status::pending) return false;
            if (status != PendingPublication::Status::published) {
                failed_frame_ = true; fallback(publication_.last_error(), publication_.diagnostic(), true); return false;
            }
        }
        pending_->color = std::move(reference);
        output = std::move(*pending_); pending_.reset(); ++published;
        error_ = S_OK; diagnostic_ = segmented_?"published segmented GPU-to-IVSHMEM SHM1":"published GPU-to-IVSHMEM SHM1";
        return true;
    }
};
// Ordered, bounded producer pipeline. Default depth remains one for A/B tests.
// active() covers every outstanding lease; available() is admission capacity only.
// A later completed transaction is never published before the oldest transaction.
class Transport final {
public:
    using Enqueue=SingleTransport::Enqueue;
private:
    std::shared_ptr<shm::Frames> frames_;
    std::shared_ptr<shm::Mapping> mapping_;
    std::array<std::unique_ptr<SingleTransport>,2> lanes_{};
    std::array<unsigned,2> order_{};
    unsigned depth_=1,head_=0,count_=0;
    std::uint64_t admission_busy_=0;
    HRESULT error_=S_OK;
    const char* diagnostic_="not initialized";
    bool failed_frame_=false;
    void refresh_counts() noexcept {
        submitted=published=fallbacks=0;busy=admission_busy_;
        for(const auto& lane:lanes_)if(lane) {
            submitted+=lane->submitted;published+=lane->published;
            fallbacks+=lane->fallbacks;busy+=lane->busy;
        }
    }
    void remember(const SingleTransport& lane) noexcept {error_=lane.last_error();diagnostic_=lane.diagnostic();}
public:
    std::uint64_t submitted=0,published=0,fallbacks=0,busy=0;
    Transport(std::shared_ptr<shm::Frames> frames,std::shared_ptr<shm::Mapping> mapping)
        :frames_(std::move(frames)),mapping_(std::move(mapping)){}
    HRESULT initialize(ID3D11Device* device,ID3D11DeviceContext* context) noexcept {
        if(lanes_[0])return E_INVALIDARG;
        try {
            lanes_[0]=std::make_unique<SingleTransport>(frames_,mapping_);
            const auto hr=lanes_[0]->initialize(device,context);remember(*lanes_[0]);
            if(FAILED(hr))return hr;
            const auto* setting=std::getenv("VIEWFLOW_SHM_D12_IN_FLIGHT");
            if(setting && std::strcmp(setting,"2")==0) {
                lanes_[1]=std::make_unique<SingleTransport>(frames_,mapping_);
                const auto second=lanes_[1]->initialize(device,context,lanes_[0]->device());
                if(SUCCEEDED(second))depth_=2;
                else {vf_diag::trace("reverse-d12 pipeline-depth=1 requested=2 secondary_hr=0x%08lx reason=%s\n",static_cast<unsigned long>(second),lanes_[1]->diagnostic());lanes_[1].reset();}
            }
            vf_diag::trace("reverse-d12 pipeline-depth=%u default=1 publication-order=FIFO\n",depth_);
            return S_OK;
        }catch(const std::bad_alloc&) {
            // Initializing the optional second lane must not discard a working first.
            if(lanes_[0] && lanes_[0]->device() && !lanes_[0]->disabled()) {lanes_[1].reset();return S_OK;}
            error_=E_OUTOFMEMORY;diagnostic_="D12 pipeline allocation";return error_;
        }
    }
    bool active() const noexcept {return count_!=0;}
    bool available() const noexcept {return count_<depth_;}
    bool disabled() const noexcept {
        if(active())return false; // Never let the caller enqueue CPU over older DMA.
        for(const auto& lane:lanes_)if(lane && !lane->disabled())return false;
        return true;
    }
    HRESULT last_error() const noexcept {return error_;}
    const char* diagnostic() const noexcept {return diagnostic_;}
    bool take_failed_frame() noexcept {const bool value=failed_frame_;failed_frame_=false;return value;}
    ID3D12Device3* device() const noexcept {return lanes_[0]?lanes_[0]->device():nullptr;}
    Enqueue enqueue(ID3D11Texture2D* surface,const Frame& metadata) noexcept {
        return enqueue_impl(surface,metadata,{});
    }
    Enqueue enqueue_owned(const std::shared_ptr<SharedCapture::Snapshot>& snapshot,const Frame& metadata) noexcept {
        return enqueue_impl(snapshot?snapshot->owned11.Get():nullptr,metadata,snapshot);
    }
private:
    Enqueue enqueue_impl(ID3D11Texture2D* surface,const Frame& metadata,
                         const std::shared_ptr<SharedCapture::Snapshot>& snapshot) noexcept {
        if(!available()){++admission_busy_;refresh_counts();return Enqueue::busy;}
        unsigned index=0;
        for(;index<depth_;++index)if(lanes_[index] && !lanes_[index]->active() && !lanes_[index]->disabled())break;
        if(index==depth_) {
            if(active()){++admission_busy_;refresh_counts();return Enqueue::busy;}
            return Enqueue::fallback;
        }
        const auto result=snapshot?lanes_[index]->enqueue_owned(snapshot,metadata):lanes_[index]->enqueue(surface,metadata);remember(*lanes_[index]);
        if(result==Enqueue::accepted) {order_[(head_+count_)%2]=index;++count_;}
        refresh_counts();
        // A newer unsupported frame must wait until older GPU transactions drain
        // before the caller may enter its CPU fallback lane.
        if(result==Enqueue::fallback && active()){++admission_busy_;refresh_counts();return Enqueue::busy;}
        return result;
    }
public:
    bool poll(Frame& output) noexcept {
        if(!count_)return false;
        auto& lane=*lanes_[order_[head_]];
        const bool ready=lane.poll(output);
        remember(lane);
        if(lane.take_failed_frame())failed_frame_=true;
        if(!lane.active()){head_=(head_+1)%2;--count_;}
        refresh_counts();return ready;
    }
};
} // namespace viewflow::reverse::d12

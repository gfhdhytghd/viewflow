#pragma once
#include <windows.h>
#include <d3d12.h>
#include <wrl/client.h>
#include <cstdint>
#include <limits>
#include <memory>
#include <new>

namespace viewflow::reverse::d12 {
// No queue synchronization is hidden here. Callers must drain submitted work
// before releasing the last Buffer reference. The mapping owner must cover the
// entire imported address range and release it only from its final destructor.
class ExternalHeap final {
    // Reverse destruction: heap, device, then mapping owner.
    std::shared_ptr<void> backing_;
    Microsoft::WRL::ComPtr<ID3D12Device3> device_;
    Microsoft::WRL::ComPtr<ID3D12Heap> heap_;
    D3D12_HEAP_DESC desc_{};
    std::uint64_t mapped_bytes_ = 0;
    void* address_ = nullptr;
    ExternalHeap() = default;
public:
    ExternalHeap(const ExternalHeap&) = delete;
    ExternalHeap& operator=(const ExternalHeap&) = delete;
    static HRESULT open(ID3D12Device3* device, void* address, std::uint64_t bytes,
                        std::shared_ptr<void> owner, std::shared_ptr<ExternalHeap>& out,
                        const char*& diagnostic) noexcept {
        diagnostic = "external heap arguments";
        if (out || !device || !address || !bytes || !owner) return E_INVALIDARG;
        try {
            auto candidate = std::shared_ptr<ExternalHeap>(new ExternalHeap);
            candidate->backing_ = std::move(owner);
            candidate->device_ = device;
            candidate->mapped_bytes_ = bytes;
            candidate->address_ = address;
            diagnostic = "OpenExistingHeapFromAddress";
            HRESULT hr = device->OpenExistingHeapFromAddress(address,
                IID_PPV_ARGS(candidate->heap_.GetAddressOf()));
            if (FAILED(hr)) return hr;
            candidate->desc_ = candidate->heap_->GetDesc();
            const auto& desc = candidate->desc_;
            diagnostic = "external heap returned extent/alignment";
            if (!desc.Alignment || !desc.SizeInBytes || desc.SizeInBytes > bytes ||
                reinterpret_cast<std::uintptr_t>(address) % desc.Alignment != 0)
                return E_INVALIDARG;
            diagnostic = "GetDeviceRemovedReason(external heap)";
            hr = device->GetDeviceRemovedReason();
            if (FAILED(hr)) return hr;
            out = std::move(candidate);
            diagnostic = "external heap ready";
            return S_OK;
        } catch (const std::bad_alloc&) {
            diagnostic = "external heap owner allocation";
            return E_OUTOFMEMORY;
        }
    }
    ID3D12Device3* device() const noexcept { return device_.Get(); }
    ID3D12Heap* get() const noexcept { return heap_.Get(); }
    const D3D12_HEAP_DESC& description() const noexcept { return desc_; }
    std::uint64_t mapped_bytes() const noexcept { return mapped_bytes_; }
    void* address() const noexcept { return address_; }
};

class ExternalBuffer final {
    // Reverse destruction releases resource before its heap/mapping owner.
    std::shared_ptr<ExternalHeap> heap_;
    Microsoft::WRL::ComPtr<ID3D12Resource> resource_;
    D3D12_RESOURCE_ALLOCATION_INFO allocation_{};
    std::uint64_t offset_ = 0;
    ExternalBuffer() = default;
public:
    ExternalBuffer(const ExternalBuffer&) = delete;
    ExternalBuffer& operator=(const ExternalBuffer&) = delete;
    static HRESULT create(std::shared_ptr<ExternalHeap> heap, std::uint64_t offset,
                          const D3D12_RESOURCE_DESC& desc, D3D12_RESOURCE_STATES state,
                          std::shared_ptr<ExternalBuffer>& out,
                          const char*& diagnostic) noexcept {
        diagnostic = "external buffer arguments";
        if (out || !heap || desc.Dimension != D3D12_RESOURCE_DIMENSION_BUFFER)
            return E_INVALIDARG;
        const auto allocation = heap->device()->GetResourceAllocationInfo(0, 1, &desc);
        const auto& heap_desc = heap->description();
        diagnostic = "external buffer allocation extent/alignment";
        if (!allocation.Alignment || !allocation.SizeInBytes ||
            allocation.SizeInBytes == (std::numeric_limits<UINT64>::max)() ||
            offset % allocation.Alignment != 0 ||
            heap_desc.Alignment % allocation.Alignment != 0 ||
            offset > heap_desc.SizeInBytes || allocation.SizeInBytes > heap_desc.SizeInBytes - offset ||
            offset > heap->mapped_bytes() || allocation.SizeInBytes > heap->mapped_bytes() - offset)
            return E_INVALIDARG;
        try {
            auto candidate = std::shared_ptr<ExternalBuffer>(new ExternalBuffer);
            candidate->heap_ = std::move(heap);
            candidate->allocation_ = allocation;
            candidate->offset_ = offset;
            diagnostic = "CreatePlacedResource(external buffer)";
            HRESULT hr = candidate->heap_->device()->CreatePlacedResource(
                candidate->heap_->get(), offset, &desc, state, nullptr,
                IID_PPV_ARGS(candidate->resource_.GetAddressOf()));
            if (FAILED(hr)) return hr;
            diagnostic = "GetDeviceRemovedReason(external buffer)";
            hr = candidate->heap_->device()->GetDeviceRemovedReason();
            if (FAILED(hr)) return hr;
            out = std::move(candidate);
            diagnostic = "external buffer ready";
            return S_OK;
        } catch (const std::bad_alloc&) {
            diagnostic = "external buffer owner allocation";
            return E_OUTOFMEMORY;
        }
    }
    ID3D12Resource* get() const noexcept { return resource_.Get(); }
    const D3D12_RESOURCE_ALLOCATION_INFO& allocation() const noexcept { return allocation_; }
    const std::shared_ptr<ExternalHeap>& heap() const noexcept { return heap_; }
    std::uint64_t offset() const noexcept { return offset_; }
};
} // namespace viewflow::reverse::d12

#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "d12_external_copy.hpp"
#include "../reverse-common/shared_frames.hpp"
#include <array>
#include <memory>
#include <vector>
#include <exception>

namespace viewflow::reverse::d12 {
// Single-threaded SHM1 publication transaction. Owners must cover Frames'
// control mapping and pixel banks. Source lease must represent DD acquisition or
// an owned capture snapshot, not merely an imported texture COM reference.
class PendingPublication final {
public:
    enum class Status { idle, pending, published, error };
    using Banks = std::array<std::shared_ptr<ExternalHeap>, shm::slots>;
private:
    // Reverse member destruction is safe even if initialize/begin fails: copy
    // drains first, then Write releases its reservation, then mappings disappear.
    std::shared_ptr<void> mapping_;
    std::shared_ptr<shm::Frames> frames_;
    Microsoft::WRL::ComPtr<ID3D12Device> device_;
    std::array<std::shared_ptr<ExternalBuffer>, shm::slots> cache_{};
    std::shared_ptr<ExternalBuffer> destination_;
    std::shared_ptr<void> source_lease_;
    std::unique_ptr<shm::Frames::Write> write_;
    std::size_t tight_pitch_ = 0;
    HRESULT error_ = S_OK;
    const char* diagnostic_ = "not initialized";
    ExternalCopy copy_;
    HRESULT fail(HRESULT hr, const char* text) noexcept { error_ = hr; diagnostic_ = text; return hr; }
    void release_transaction() noexcept {
        write_.reset(); source_lease_.reset(); destination_.reset(); tight_pitch_ = 0;
    }
public:
    PendingPublication(std::shared_ptr<shm::Frames> frames, std::shared_ptr<void> mapping) noexcept
        : mapping_(std::move(mapping)), frames_(std::move(frames)) {}
    PendingPublication(const PendingPublication&) = delete;
    PendingPublication& operator=(const PendingPublication&) = delete;
    ~PendingPublication() { cancel(); }
    HRESULT initialize(ID3D12Device* device) noexcept {
        if (!frames_ || !mapping_ || !device || device_) return fail(E_INVALIDARG, "publication initialize arguments");
        const HRESULT hr = copy_.initialize(device);
        if (FAILED(hr)) return fail(hr, copy_.diagnostic());
        device_ = device;
        return fail(S_OK, "publication ready");
    }
    bool active() const noexcept { return bool(write_); }
    HRESULT last_error() const noexcept { return error_; }
    const char* diagnostic() const noexcept { return diagnostic_; }

    // S_FALSE means a prior transaction/reader holds the required capacity;
    // preserve the current displayed frame and retry later. A failed submit may
    // still be active (Signal failed after Execute); poll/cancel must drain it.
    HRESULT begin(ID3D12Resource* source, const Banks& banks,
                  std::uint64_t epoch, std::uint64_t sequence,
                  std::shared_ptr<void> source_lease,
                  ID3D12Fence* producer_fence = nullptr, UINT64 producer_value = 0) noexcept {
        return begin_with_bank(source,[&banks](unsigned slot){return banks[slot];},
                               epoch,sequence,std::move(source_lease),producer_fence,producer_value);
    }
    // Resolve/import only the slot actually reserved, after footprint validation.
    // The provider may cache imports but must not eagerly populate all banks.
    template<class BankProvider>
    HRESULT begin_with_bank(ID3D12Resource* source, BankProvider&& bank_for_slot,
                  std::uint64_t epoch, std::uint64_t sequence,
                  std::shared_ptr<void> source_lease,
                  ID3D12Fence* producer_fence = nullptr, UINT64 producer_value = 0) noexcept {
        if (!device_ || !source || !source_lease) return fail(E_INVALIDARG, "publication source/lease/device");
        if (write_) return fail(S_FALSE, "publication already in flight");
        const auto td = source->GetDesc();
        if (td.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D || td.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
            td.MipLevels != 1 || td.DepthOrArraySize != 1 || td.SampleDesc.Count != 1 ||
            td.Width > shared_max_dimension || !frames_->fits(static_cast<unsigned>(td.Width), td.Height))
            return fail(E_INVALIDARG, "publication source BGRA extent");
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
        UINT rows = 0; UINT64 row_bytes = 0, required = 0;
        device_->GetCopyableFootprints(&td, 0, 1, 0, &footprint, &rows, &row_bytes, &required);
        const UINT64 image_bytes = td.Width * td.Height * 4;
        if (footprint.Offset || rows != td.Height || row_bytes != td.Width * 4 ||
            footprint.Footprint.RowPitch != row_bytes || required != image_bytes)
            return fail(E_INVALIDARG, "SHM1 requires exact tight BGRA footprint");
        try {
            write_ = frames_->begin_write(epoch, sequence, static_cast<unsigned>(td.Width), td.Height);
            if (!write_) return fail(S_FALSE, "no writable SHM slot");
            const auto slot = write_->slot_index();
            const auto target = write_->external_destination();
            const auto bank = bank_for_slot(slot);
            if (!bank || bank->address() != target.data() || target.size() != image_bytes ||
                bank->mapped_bytes() < image_bytes || bank->description().SizeInBytes < image_bytes) {
                release_transaction(); return fail(E_INVALIDARG, "selected SHM slot differs from external heap address/extent");
            }
            auto& cached = cache_[slot];
            if (cached && (cached->heap() != bank || cached->offset() != 0 ||
                           cached->get()->GetDesc().Width != image_bytes)) cached.reset();
            if (!cached) {
                D3D12_RESOURCE_DESC desc{};
                desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
                desc.Alignment = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;
                desc.Width = image_bytes; desc.Height = 1; desc.DepthOrArraySize = 1; desc.MipLevels = 1;
                desc.SampleDesc.Count = 1; desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
                desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_CROSS_ADAPTER;
                const char* stage = nullptr;
                const HRESULT hr = ExternalBuffer::create(bank, 0, desc, D3D12_RESOURCE_STATE_COPY_DEST, cached, stage);
                if (FAILED(hr)) { release_transaction(); return fail(hr, stage); }
            }
            // Validate actual resource ownership metadata, never caller copies of
            // a pointer/offset. Resource allocation bounds are checked by create.
            if (cached->offset() || cached->heap()->address() != target.data() ||
                cached->get()->GetDesc().Width != target.size()) {
                release_transaction(); return fail(E_INVALIDARG, "placed buffer is not selected slot at zero offset");
            }
            destination_ = cached; source_lease_ = std::move(source_lease);
            tight_pitch_ = static_cast<std::size_t>(row_bytes);
            const HRESULT hr = copy_.submit(source, destination_, producer_fence, producer_value, source_lease_);
            if (FAILED(hr) && !copy_.in_flight()) release_transaction();
            return fail(hr, copy_.diagnostic());
        } catch (const std::bad_alloc&) {
            // All potentially throwing allocation calls precede submit. Preserve
            // the conservative drain if future code adds a post-submit allocation.
            cancel(); return fail(E_OUTOFMEMORY, "publication allocation");
        } catch (const std::exception&) {
            cancel(); return fail(E_INVALIDARG, "publication Frames transaction rejected");
        }
    }

    // Never emits a reference before a successful GPU fence. Output must be empty
    // so an unconsumed prior reference is not silently discarded.
    Status poll(std::vector<std::uint8_t>& reference, DWORD wait_ms = 0) noexcept {
        if (!reference.empty()) { fail(E_INVALIDARG, "reference output must be empty"); return Status::error; }
        if (!write_) return Status::idle;
        const auto status = wait_ms ? copy_.wait(wait_ms) : copy_.poll();
        if (status == ExternalCopy::Status::pending) { fail(copy_.last_error(), copy_.diagnostic()); return Status::pending; }
        if (status == ExternalCopy::Status::device_lost) {
            release_transaction(); fail(copy_.last_error(), copy_.diagnostic()); return Status::error;
        }
        try {
            write_->complete_external(tight_pitch_);
            reference = write_->finish(); // pack allocates before release-store ready.
            release_transaction(); fail(S_OK, "GPU completed; SHM reference published");
            return Status::published;
        } catch (const std::bad_alloc&) {
            release_transaction(); fail(E_OUTOFMEMORY, "reference allocation after GPU completion"); return Status::error;
        } catch (const std::exception&) {
            release_transaction(); fail(E_INVALIDARG, "SHM completion transaction rejected"); return Status::error;
        }
    }
    // Cancellation is local and may block while actual GPU work remains. There
    // is no performance-target timeout that releases the slot or mapping early.
    void cancel() noexcept {
        while (copy_.in_flight() && copy_.wait(100) == ExternalCopy::Status::pending) {}
        release_transaction();
    }
};
} // namespace viewflow::reverse::d12

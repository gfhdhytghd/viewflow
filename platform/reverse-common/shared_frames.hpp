#pragma once
// IVSHMEM ABI v1, x86-64 Windows/Linux, cache-coherent RAM, one producer/consumer.
// The pixel bytes never travel over QUIC: its authenticated frame carries only
// this reference. Slot ownership excludes concurrent pixel reads and writes.
#include <atomic>
#include <cstdint>
#include <cstring>
#include <span>
#include <stdexcept>
#include <vector>
#include <memory>
#include <array>
#include "shared_copy.hpp"
#include "progressive_negotiation.hpp"
#include "progressive_storage.hpp"
#include "wire.hpp"

namespace viewflow::reverse::shm {
inline constexpr unsigned slots=4;
inline constexpr std::size_t header_bytes=4096;
inline constexpr std::size_t max_slot_bytes=std::size_t(shared_max_pixels)*4;
inline constexpr std::size_t max_data_bytes=header_bytes+slots*max_slot_bytes;
inline constexpr std::uint64_t bank_magic=0x324b4e4142465656ULL;
inline constexpr std::size_t bank_layout_offset=1024;
// Host declaration: pixel BARs are actually mapped into the passthrough GPU's
// IOMMU. CPU-only QEMU regions MUST leave this bit clear.
inline constexpr std::uint32_t bank_gpu_dma_mapped=1u;
// Optional banked transport: one small control BAR and four independent pixel
// BARs. Each BAR stays below the signed Windows driver's 32-bit length limit.
struct BankLayout {
    std::uint64_t magic, capacity;
    std::uint32_t bus, addresses[slots], reserved; // reserved bit 0: bank_gpu_dma_mapped
};
static_assert(sizeof(BankLayout)==40);
inline constexpr std::uint32_t codec=3, reference_magic=0x314d4853; // SHM1
struct alignas(64) Slot {
    std::uint64_t state; // 0 free, 1 writing, 2 ready, 3 reading, 4 SHM2 reserved
    std::uint64_t epoch, sequence;
    std::uint32_t width, height;
};
static_assert(sizeof(Slot)==64 && std::endian::native==std::endian::little && sizeof(void*)==8);
static_assert(std::atomic_ref<std::uint64_t>::is_always_lock_free);
struct Reference { std::uint64_t epoch,sequence;unsigned slot,width,height;std::uint64_t capacity; };
inline std::vector<std::uint8_t> pack(Reference ref) {
    Writer w;w.u32(reference_magic);w.u32(ref.slot);w.u64(ref.epoch);w.u64(ref.sequence);w.u32(ref.width);w.u32(ref.height);w.u64(ref.capacity);return w.bytes;
}
inline Reference unpack(std::span<const std::uint8_t> bytes) {
    Reader r{bytes};if(r.u32()!=reference_magic)throw std::runtime_error("shared frame version");
    const auto slot=r.u32();const auto epoch=r.u64(),sequence=r.u64();const auto width=r.u32(),height=r.u32();const auto capacity=r.u64();r.finish();
    if(slot>=slots || !epoch || !sequence || !width || !height || width>shared_max_dimension || height>shared_max_dimension || std::uint64_t(width)*height>shared_max_pixels)
        throw std::runtime_error("shared frame reference bounds");
    return {epoch,sequence,slot,width,height,capacity};
}
class Frames {
    std::uint8_t* base_;std::size_t capacity_;unsigned next_{};
    std::array<std::uint8_t*,slots> banks_{};
    std::shared_ptr<ParallelCopy> copy_worker_;
    std::array<std::shared_ptr<std::vector<std::uint8_t>>,3> buffers_;unsigned next_buffer_{};
    Slot& slot(unsigned i) const { return *reinterpret_cast<Slot*>(base_+i*sizeof(Slot)); }
    std::uint8_t* pixels(unsigned i) const {return banks_[i]?banks_[i]:base_+header_bytes+i*capacity_;}
public:
    bool streaming_writes=false,parallel_writes=false;
    Frames(void* control,std::size_t control_size,std::array<void*,slots> banks,std::size_t capacity)
        :base_(static_cast<std::uint8_t*>(control)),capacity_(capacity) {
        if(!control || reinterpret_cast<std::uintptr_t>(control)%64 || control_size<header_bytes || capacity<4096 || capacity>max_slot_bytes || capacity%64)
            throw std::runtime_error("shared frame bank control/capacity");
        for(unsigned i=0;i<slots;++i){
            if(!banks[i] || reinterpret_cast<std::uintptr_t>(banks[i])%64)throw std::runtime_error("shared frame bank alignment");
            banks_[i]=static_cast<std::uint8_t*>(banks[i]);
        }
    }
    Frames(void* base,std::size_t size):base_(static_cast<std::uint8_t*>(base)),capacity_(size>header_bytes?std::min(max_slot_bytes,((size-header_bytes)/slots)&~std::size_t(63)):0) {
        if(!base || reinterpret_cast<std::uintptr_t>(base)%64 || capacity_<4096)throw std::runtime_error("shared frame mapping extent/alignment");
    }
    // State4 reserves the physical bank across SHM1/SHM2. Legacy binaries
    // skip this state, including recovery; they cannot overwrite SHM2 DMA.
    ProgressiveFrame& progressive_header(unsigned i) const {
        if(i>=slots)throw std::runtime_error("progressive slot");
        static_assert(1536+slots*sizeof(ProgressiveFrame)<=header_bytes);
        return *reinterpret_cast<ProgressiveFrame*>(base_+1536+i*sizeof(ProgressiveFrame));
    }
    void reap_progressive() {
        for(unsigned i=0;i<slots;++i){
            std::atomic_ref state(slot(i).state);
            if(state.load(std::memory_order_acquire)!=4)continue;
            auto& h=progressive_header(i);h.discard_ready();
            if(h.unused()){auto expected=std::uint64_t(4);state.compare_exchange_strong(expected,0,std::memory_order_acq_rel);}
        }
    }
    // Caller must have a current two-sided SHM2 capability agreement.
    std::unique_ptr<ProgressiveStorage::Write> begin_progressive(std::uint64_t epoch,std::uint64_t sequence,unsigned w,unsigned h){
        if(!epoch || !sequence || !fits(w,h))throw std::runtime_error("progressive mapped extent");
        reap_progressive();
        if(streaming_writes && parallel_writes && std::size_t(w)*h*4>=(16u<<20) && !copy_worker_){
            try{copy_worker_=std::make_shared<ParallelCopy>();}catch(const std::exception&){parallel_writes=false;}
        }
        for(unsigned turn=0;turn<slots;++turn){
            const auto i=(next_+turn)%slots;std::atomic_ref state(slot(i).state);auto old=state.load(std::memory_order_acquire);
            if((old!=0 && old!=2) || !state.compare_exchange_strong(old,4,std::memory_order_acq_rel))continue;
            ProgressiveStorage storage(progressive_header(i),{pixels(i),capacity_},{},streaming_writes,parallel_writes?copy_worker_:nullptr);
            auto lease=storage.begin({epoch,sequence,capacity_,i,w,h});
            if(lease){next_=(i+1)%slots;return lease;}
            // Keep reservation if an opposite-side lease survived recovery.
        }
        return {};
    }
    std::shared_ptr<ProgressiveStorage::Read> acquire_progressive(std::span<const std::uint8_t> bytes,unsigned w,unsigned h,std::shared_ptr<void> owner){
        const auto ref=unpack_progressive(bytes);
        if(ref.width!=w || ref.height!=h || ref.capacity!=capacity_)throw std::runtime_error("progressive reference extent mismatch");
        if(std::atomic_ref(slot(ref.slot).state).load(std::memory_order_acquire)!=4)return {};
        ProgressiveStorage storage(progressive_header(ref.slot),{pixels(ref.slot),capacity_},std::move(owner));
        return storage.acquire(bytes);
    }
    // Call only after obtaining the OS reader/writer exclusive ownership lock.
    // Recover a slot abandoned by that side, without touching a live opposite side.
    void recover(bool writer) {for(unsigned i=0;i<slots;++i){std::atomic_ref state(slot(i).state);std::uint64_t expected=writer?1:3;state.compare_exchange_strong(expected,0,std::memory_order_acq_rel);progressive_header(i).recover(writer);}if(writer)reap_progressive();}
    void reader_ready(bool ready) {std::atomic_ref(*reinterpret_cast<std::uint64_t*>(base_+520)).store(capacity_,std::memory_order_relaxed);std::atomic_ref(*reinterpret_cast<std::uint64_t*>(base_+512)).store(ready?1:0,std::memory_order_release);}
    bool reader_ready() const {return std::atomic_ref(*reinterpret_cast<std::uint64_t*>(base_+512)).load(std::memory_order_acquire)==1 && std::atomic_ref(*reinterpret_cast<std::uint64_t*>(base_+520)).load(std::memory_order_relaxed)==capacity_;}
    ProgressiveNegotiation& progressive_negotiation() const {return *reinterpret_cast<ProgressiveNegotiation*>(base_+progressive_negotiation_offset);}
#ifdef VIEWFLOW_PROGRESSIVE_STORAGE_PROBE
    // Standalone diagnostic only: both normal endpoints must be stopped.
    // This does not arbitrate bank ownership with the SHM1 slot headers.
    ProgressiveFrame& probe_header(unsigned i) const {return progressive_header(i);}
    ProgressiveStorage probe_storage(unsigned i,std::shared_ptr<void> owner) const {
        return ProgressiveStorage(probe_header(i),{pixels(i),capacity_},std::move(owner));
    }
    std::size_t probe_capacity() const {return capacity_;}
#endif
    // Fixed virtual slot strides, demand-paged physical storage. Never clear or
    // pre-touch the aperture: publish touches only width*height*4 bytes/slot.
    bool fits(unsigned w,unsigned h) const {return w && h && w<=shared_max_dimension && h<=shared_max_dimension && std::uint64_t(w)*h*4<=capacity_;}
    // One writer transaction owns the slot until every ordered band is copied.
    // Readers see only state2; destruction cancels an incomplete frame locally.
    class Write {
        Frames& owner_;unsigned index_,width_,height_,copied_{};bool finished_{},external_{};
        std::uint64_t epoch_,sequence_;
    public:
        Write(Frames& owner,unsigned index,std::uint64_t epoch,std::uint64_t sequence,unsigned w,unsigned h)
            :owner_(owner),index_(index),width_(w),height_(h),epoch_(epoch),sequence_(sequence) {}
        Write(const Write&)=delete;Write& operator=(const Write&)=delete;
        ~Write(){if(!finished_)std::atomic_ref(owner_.slot(index_).state).store(0,std::memory_order_release);}
        unsigned slot_index() const noexcept {return index_;}
        // External producers must retain this transaction AND its Frames/mapping
        // owner until their GPU work drains, including cancellation/error paths.
        // This is the image extent, not permission to write the whole bank.
        std::span<std::uint8_t> external_destination() {
            if(finished_ || copied_)throw std::runtime_error("shared frame external write state");
            external_=true;
            return {owner_.pixels(index_),std::size_t(width_)*height_*4};
        }
        // Caller must observe successful GPU fence completion and memory
        // visibility before this call. SHM1 cannot represent padded row pitches.
        void complete_external(std::size_t pitch) {
            if(finished_ || !external_ || copied_ || pitch!=std::size_t(width_)*4)
                throw std::runtime_error("shared frame external completion state or pitch");
            copied_=height_;
        }
        void append(const void* data,std::size_t pitch,unsigned rows) {
            const auto row_bytes=std::size_t(width_)*4;
            if(finished_ || external_ || !data || !rows || rows>height_-copied_ || pitch<row_bytes)
                throw std::runtime_error("shared frame band bounds");
            auto* destination=owner_.pixels(index_)+std::size_t(copied_)*row_bytes;
            const auto* source=static_cast<const std::uint8_t*>(data);
            if(owner_.streaming_writes && row_bytes*rows>=(1u<<20)) {
                if(owner_.parallel_writes && row_bytes*rows>=(16u<<20))owner_.copy_worker_->copy(destination,source,row_bytes,pitch,rows);
                else streaming_rows(destination,source,row_bytes,pitch,0,rows);
            }else if(pitch==row_bytes)std::memcpy(destination,source,row_bytes*rows);
            else for(unsigned y=0;y<rows;++y)std::memcpy(destination+y*row_bytes,source+y*pitch,row_bytes);
            copied_+=rows;
        }
        std::vector<std::uint8_t> finish() {
            if(finished_ || copied_!=height_)throw std::runtime_error("shared frame incomplete publication");
            auto reference=pack({epoch_,sequence_,index_,width_,height_,owner_.capacity_});
            std::atomic_ref(owner_.slot(index_).state).store(2,std::memory_order_release);
            owner_.next_=(index_+1)%slots;finished_=true;return reference;
        }
    };
    std::unique_ptr<Write> begin_write(std::uint64_t epoch,std::uint64_t sequence,unsigned w,unsigned h) {
        if(!epoch || !sequence || !fits(w,h))throw std::runtime_error("shared frame exceeds slot capacity");
        reap_progressive();
        if(streaming_writes && parallel_writes && std::size_t(w)*h*4>=(16u<<20) && !copy_worker_) {
            try {copy_worker_=std::make_shared<ParallelCopy>();}
            catch(const std::exception&){parallel_writes=false;}
        }
        for(unsigned turn=0;turn<slots;++turn) {
            const auto i=(next_+turn)%slots;auto& s=slot(i);std::atomic_ref state(s.state);
            auto old=state.load(std::memory_order_acquire);
            if((old!=0 && old!=2) || !state.compare_exchange_strong(old,1,std::memory_order_acq_rel))continue;
            try {
                auto result=std::make_unique<Write>(*this,i,epoch,sequence,w,h);
                s.epoch=epoch;s.sequence=sequence;s.width=w;s.height=h;return result;
            }catch(...){state.store(0,std::memory_order_release);throw;}
        }
        return {};
    }
    std::vector<std::uint8_t> publish(std::uint64_t epoch,std::uint64_t sequence,unsigned w,unsigned h,const void* data,std::size_t pitch) {
        if(!data || pitch<std::size_t(w)*4)throw std::runtime_error("shared frame source bounds");
        auto write=begin_write(epoch,sequence,w,h);if(!write)return {};
        write->append(data,pitch,h);return write->finish();
    }
    // The mapping must outlive the lease. Replacing a queued frame releases its
    // slot immediately; the writer can never overwrite pixels being uploaded.
    std::shared_ptr<SharedPixels> acquire(std::span<const std::uint8_t> bytes,unsigned width,unsigned height,std::shared_ptr<void> mapping={}) {
        const auto ref=unpack(bytes);
        if(ref.capacity!=capacity_ || ref.width!=width || ref.height!=height || !fits(width,height))throw std::runtime_error("shared frame dimensions/capacity mismatch");
        auto& s=slot(ref.slot);std::atomic_ref state(s.state);std::uint64_t expected=2;
        if(!state.compare_exchange_strong(expected,3,std::memory_order_acq_rel))return {};
        if(s.epoch!=ref.epoch || s.sequence!=ref.sequence || s.width!=width || s.height!=height){state.store(2,std::memory_order_release);return {};}
        struct Lease {
            std::uint64_t* state;std::shared_ptr<void> mapping;
            Lease(std::uint64_t* s,std::shared_ptr<void> m):state(s),mapping(std::move(m)){}
            ~Lease(){std::atomic_ref(*state).store(0,std::memory_order_release);}
        };
        auto storage_owner=mapping;
        std::shared_ptr<Lease> owner;
        try {owner=std::make_shared<Lease>(&s.state,std::move(mapping));}
        catch(...){state.store(0,std::memory_order_release);throw;}
        return std::make_shared<SharedPixels>(SharedPixels{std::move(owner),{pixels(ref.slot),std::size_t(width)*height*4},std::move(storage_owner)});
    }
    std::shared_ptr<std::vector<std::uint8_t>> read(std::span<const std::uint8_t> bytes,unsigned width,unsigned height) {
        const auto ref=unpack(bytes);
        if(ref.capacity!=capacity_ || ref.width!=width || ref.height!=height || !fits(width,height))throw std::runtime_error("shared frame dimensions/capacity mismatch");
        auto& s=slot(ref.slot);std::atomic_ref state(s.state);std::uint64_t expected=2;
        if(!state.compare_exchange_strong(expected,3,std::memory_order_acq_rel))return {};
        struct Release {std::atomic_ref<std::uint64_t> state;std::uint64_t value=2;~Release(){state.store(value,std::memory_order_release);}} release{state};
        if(s.epoch!=ref.epoch || s.sequence!=ref.sequence || s.width!=width || s.height!=height)return {};
        auto& buffer=buffers_[next_buffer_++%buffers_.size()];
        if(!buffer || buffer.use_count()!=1)buffer=std::make_shared<std::vector<std::uint8_t>>();
        buffer->resize(std::size_t(width)*height*4);auto result=buffer;
        std::memcpy(result->data(),pixels(ref.slot),result->size());release.value=0;return result;
    }
};
}

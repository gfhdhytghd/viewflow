#pragma once
#include <atomic>
#include <cstdint>
#include <stdexcept>
#include <random>
namespace viewflow::reverse::shm {
inline constexpr std::uint64_t progressive_feature=1,progressive_payload_feature=2;
// Reserved control region768..959, before existing bank layout at1024.
// Separate ownership per cache line; every concurrently accessed field atomic.
struct alignas(64) ProgressiveNegotiation {
    struct alignas(64) Offer {std::uint64_t nonce{},features{};} reader;
    struct alignas(64) Answer {std::uint64_t reader_nonce{},writer_nonce{},features{};} writer;
    struct alignas(64) Commit {std::uint64_t reader_nonce{},writer_nonce{};} commit;
    static std::uint64_t get(std::uint64_t& v){return std::atomic_ref(v).load(std::memory_order_acquire);}
    static void put(std::uint64_t& v,std::uint64_t x){std::atomic_ref(v).store(x,std::memory_order_release);}
    // Nonces are fresh/nonzero per endpoint lifetime, never reused on restart.
    void start_reader(std::uint64_t nonce,std::uint64_t features){
        if(!nonce)throw std::runtime_error("zero reader negotiation nonce");
        put(commit.writer_nonce,0);put(reader.nonce,0);put(reader.features,features);put(reader.nonce,nonce);
    }
    void start_writer(std::uint64_t nonce){
        if(!nonce)throw std::runtime_error("zero writer negotiation nonce");
        put(writer.reader_nonce,0);put(writer.features,0);put(writer.writer_nonce,nonce);
    }
    bool answer(std::uint64_t nonce,std::uint64_t supported){
        if(!nonce || get(writer.writer_nonce)!=nonce)return false;
        const auto request=get(reader.nonce),features=get(reader.features)&supported;
        if(!request || get(reader.nonce)!=request)return false;
        if(get(writer.reader_nonce)==request && get(writer.features)==features)return true;
        put(writer.reader_nonce,0);put(writer.features,features);put(writer.reader_nonce,request);return true;
    }
    bool confirm(std::uint64_t nonce){
        if(!nonce || get(reader.nonce)!=nonce || get(writer.reader_nonce)!=nonce)return false;
        const auto response=get(writer.writer_nonce),features=get(writer.features);
        if(!response || !(features&progressive_feature) || get(writer.reader_nonce)!=nonce)return false;
        put(commit.reader_nonce,nonce);put(commit.writer_nonce,response);return true;
    }
    bool agreed(std::uint64_t reader_nonce,std::uint64_t writer_nonce){
        if(!reader_nonce || !writer_nonce)return false;
        return get(reader.nonce)==reader_nonce && get(writer.reader_nonce)==reader_nonce &&
            get(writer.writer_nonce)==writer_nonce && (get(writer.features)&progressive_feature) &&
            get(commit.writer_nonce)==writer_nonce && get(commit.reader_nonce)==reader_nonce;
    }
};
// Probe-only endpoint lifecycle. It does not enable any SHM2 pixel payloads.
class ProgressiveProbe {
    ProgressiveNegotiation* block_{};std::uint64_t nonce_{};bool writer_{};std::uint64_t features_{};
public:
    ProgressiveProbe(ProgressiveNegotiation* block,bool writer,std::uint64_t features=progressive_feature):block_(block),writer_(writer),features_(features){
        if(!block_)return;
        std::random_device random;do{nonce_=(std::uint64_t(random())<<32)^random();}while(!nonce_);
        if(writer_)block_->start_writer(nonce_);else block_->start_reader(nonce_,features_);
    }
    ProgressiveProbe(const ProgressiveProbe&)=delete;
    ~ProgressiveProbe(){if(!block_)return;
        if(writer_){if(block_->get(block_->writer.writer_nonce)==nonce_){block_->put(block_->writer.reader_nonce,0);block_->put(block_->writer.writer_nonce,0);}}
        else if(block_->get(block_->reader.nonce)==nonce_){block_->put(block_->commit.writer_nonce,0);block_->put(block_->reader.nonce,0);}
    }
    bool payload_agreed(){return poll() && (block_->get(block_->writer.features)&progressive_payload_feature);}
    bool poll(){
        if(!block_)return false;
        if(writer_){block_->answer(nonce_,features_);return block_->agreed(block_->get(block_->reader.nonce),nonce_);}
        block_->confirm(nonce_);return block_->agreed(nonce_,block_->get(block_->writer.writer_nonce));
    }
};
static_assert(sizeof(ProgressiveNegotiation)==192);
inline constexpr unsigned progressive_negotiation_offset=768;
static_assert(progressive_negotiation_offset+sizeof(ProgressiveNegotiation)<=1024);
}

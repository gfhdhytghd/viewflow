#pragma once
#include "progressive_frame.hpp"
#include "shared_copy.hpp"
#include <cstring>
#include <memory>

namespace viewflow::reverse::shm {
// A view over one mapped SHM2 header and its pixel bank. The mapping owner must
// cover BOTH allocations and remain alive through any asynchronous GPU upload.
// This view does not negotiate capabilities or arbitrate SHM1 bank reuse.
class ProgressiveStorage {
    ProgressiveFrame& header_;
    std::span<std::uint8_t> bytes_;
    std::shared_ptr<void> mapping_;
    bool streaming_{};std::shared_ptr<ParallelCopy> worker_;
    void validate(const ProgressiveReference& r)const{
        if(!valid(r) || r.capacity!=bytes_.size())throw std::runtime_error("progressive mapped capacity mismatch");
    }
public:
    ProgressiveStorage(ProgressiveFrame& header,std::span<std::uint8_t> bytes,std::shared_ptr<void> mapping={},bool streaming=false,std::shared_ptr<ParallelCopy> worker={})
        :header_(header),bytes_(bytes),mapping_(std::move(mapping)),streaming_(streaming),worker_(std::move(worker)){}
    class Write {
        friend class ProgressiveStorage;
        ProgressiveFrame& header_;std::span<std::uint8_t> bytes_;std::shared_ptr<void> mapping_;
        ProgressiveReference ref_;unsigned rows_{};bool active_{};
        bool streaming_{};std::shared_ptr<ParallelCopy> worker_;
        Write(ProgressiveFrame& h,std::span<std::uint8_t> b,std::shared_ptr<void> m,const ProgressiveReference& r,bool streaming,std::shared_ptr<ParallelCopy> worker)
            :header_(h),bytes_(b),mapping_(std::move(m)),ref_(r),active_(h.begin(r)),streaming_(streaming),worker_(std::move(worker)){}
    public:
        Write(const Write&)=delete;
        ~Write(){if(active_)header_.abort();}
        std::vector<std::uint8_t> reference()const{return pack_progressive(ref_);}
        void append(std::span<const std::uint8_t> source,std::size_t pitch,unsigned rows){
            const auto row_bytes=std::size_t(ref_.width)*4;
            if(!active_ || !rows || rows>ref_.height-rows_ || pitch<row_bytes || source.size()<row_bytes || rows-1>(source.size()-row_bytes)/pitch)
                throw std::runtime_error("progressive source band bounds");
            auto* destination=bytes_.data()+std::size_t(rows_)*row_bytes;
            if(streaming_ && row_bytes*rows>=(1u<<20)){
                if(worker_ && row_bytes*rows>=(16u<<20))worker_->copy(destination,source.data(),row_bytes,pitch,rows);
                else streaming_rows(destination,source.data(),row_bytes,pitch,0,rows);
            }else if(pitch==row_bytes)std::memcpy(destination,source.data(),row_bytes*rows);
            else for(unsigned y=0;y<rows;++y)std::memcpy(destination+std::size_t(y)*row_bytes,source.data()+std::size_t(y)*pitch,row_bytes);
            rows_+=rows;header_.publish_prefix(rows_);
        }
        void append_chunked(std::span<const std::uint8_t> source,std::size_t pitch,unsigned rows,unsigned chunk_rows){
            const auto row_bytes=std::size_t(ref_.width)*4;
            // Reject the entire input before publishing any partial prefix.
            if(!active_ || !rows || rows>ref_.height-rows_ || pitch<row_bytes || source.size()<row_bytes || rows-1>(source.size()-row_bytes)/pitch)
                throw std::runtime_error("progressive source chunks bounds");
            for(unsigned first=0;first<rows;){
                const auto count=chunk_rows?std::min(chunk_rows,rows-first):rows;
                append(source.subspan(std::size_t(first)*pitch,std::size_t(count-1)*pitch+row_bytes),pitch,count);
                first+=count;
            }
        }
        void finish(){if(!active_)throw std::runtime_error("progressive writer already finished");header_.finish();active_=false;}
    };
    class Read {
        friend class ProgressiveStorage;
        ProgressiveFrame& header_;std::span<const std::uint8_t> bytes_;std::shared_ptr<void> mapping_;
        ProgressiveReference ref_;bool active_{};
        Read(ProgressiveFrame& h,std::span<const std::uint8_t> b,std::shared_ptr<void> m,const ProgressiveReference& r)
            :header_(h),bytes_(b),mapping_(std::move(m)),ref_(r),active_(h.acquire(r)){}
    public:
        Read(const Read&)=delete;
        ~Read(){if(active_)header_.release();}
        std::shared_ptr<void> storage_owner()const{return mapping_;}
        const ProgressiveReference& identity()const{return ref_;}
        bool complete()const{return active_ && header_.complete();}
        bool aborted()const{return active_ && header_.aborted();}
        std::span<const std::uint8_t> prefix()const{
            if(!active_ || header_.aborted())return {};
            const auto rows=header_.available_rows();
            if(rows>ref_.height)throw std::runtime_error("progressive published extent");
            return bytes_.first(std::size_t(rows)*ref_.width*4);
        }
    };
    std::unique_ptr<Write> begin(const ProgressiveReference& r){
        validate(r);auto lease=std::unique_ptr<Write>(new Write(header_,bytes_,mapping_,r,streaming_,worker_));if(!lease->active_)return {};return lease;
    }
    std::unique_ptr<Read> acquire(std::span<const std::uint8_t> reference){
        const auto r=unpack_progressive(reference);validate(r);
        auto lease=std::unique_ptr<Read>(new Read(header_,bytes_,mapping_,r));if(!lease->active_)return {};return lease;
    }
};
}

namespace viewflow::reverse {
struct ProgressivePixels {std::shared_ptr<shm::ProgressiveStorage::Read> lease;};
}

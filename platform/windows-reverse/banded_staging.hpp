#pragma once
#include "capture_staging.hpp"
#include "../reverse-common/fixture_stamp.hpp"
#include "../reverse-common/shared_frames.hpp"
#include <vector>
#include <optional>
namespace viewflow::reverse::shm {
struct CapturedBands {
    struct Band {unsigned y{},height{};Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;Microsoft::WRL::ComPtr<ID3D11Query> done;};
    unsigned width{},height{};
    std::vector<Band> bands;
};
// Independent textures permit mapping a completed prefix without mapping a
// resource that later GPU copies still write. Pool leases cover every band.
class BandedStaging {
    std::array<std::shared_ptr<CapturedBands>,3> slots_;
    const bool flush_bands_=[]{const auto* v=std::getenv("VIEWFLOW_SHM_BAND_FLUSH");return v && std::strcmp(v,"1")==0;}();
public:
    using Timing=CaptureStaging::Timing;
    std::shared_ptr<CapturedBands> copy(ID3D11Device* device,ID3D11DeviceContext* context,ID3D11Texture2D* source,const D3D11_BOX& crop,const std::shared_ptr<CapturedBands>& current,unsigned count=4,Timing* timing=nullptr) {
        using Clock=std::chrono::steady_clock;
        const auto begin=timing?Clock::now():Clock::time_point{};
        D3D11_TEXTURE2D_DESC desc{};source->GetDesc(&desc);
        if(!count || count>16 || crop.front!=0 || crop.back!=1 || crop.left>=crop.right || crop.top>=crop.bottom || crop.right>desc.Width || crop.bottom>desc.Height || desc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM)throw std::runtime_error("banded capture extent");
        const unsigned width=crop.right-crop.left,height=crop.bottom-crop.top;count=std::min(count,height);
        std::shared_ptr<CapturedBands> slot;
        for(auto& s:slots_)if(s && (s.use_count()==1 || (s==current && s.use_count()==2))){slot=s;break;}
        if(!slot)for(auto& s:slots_)if(!s){s=std::make_shared<CapturedBands>();slot=s;break;}
        if(!slot)return {};
        if(slot->width!=width || slot->height!=height || slot->bands.size()!=count){
            std::vector<CapturedBands::Band> replacement;
            for(unsigned i=0;i<count;++i){
                CapturedBands::Band b;b.y=height*i/count;b.height=height*(i+1)/count-b.y;
                auto d=desc;d.Width=width;d.Height=b.height;d.MipLevels=d.ArraySize=1;d.Usage=D3D11_USAGE_STAGING;d.BindFlags=d.MiscFlags=0;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
                if(FAILED(device->CreateTexture2D(&d,nullptr,&b.texture)))throw std::runtime_error("band staging allocation");
                D3D11_QUERY_DESC q{D3D11_QUERY_EVENT,0};if(FAILED(device->CreateQuery(&q,&b.done)))throw std::runtime_error("band completion query");
                replacement.push_back(std::move(b));
            }
            slot->bands=std::move(replacement);slot->width=width;slot->height=height;
        }
        const auto ms=[](auto a,auto b){return std::chrono::duration<double,std::milli>(b-a).count();};
        if(timing){*timing={};timing->prepare_ms=ms(begin,Clock::now());}
        for(auto& b:slot->bands){
            const auto before=timing?Clock::now():Clock::time_point{};
            D3D11_BOX box{crop.left,crop.top+b.y,0,crop.right,crop.top+b.y+b.height,1};
            context->CopySubresourceRegion(b.texture.Get(),0,0,0,0,source,0,&box);
            const auto copied=timing?Clock::now():Clock::time_point{};
            context->End(b.done.Get());
            const auto ended=timing?Clock::now():Clock::time_point{};
            if(flush_bands_)context->Flush();
            if(timing){timing->copy_ms+=ms(before,copied);timing->end_ms+=ms(copied,ended);timing->flush_ms+=ms(ended,Clock::now());}
        }
        if(!flush_bands_){
            const auto before=timing?Clock::now():Clock::time_point{};context->Flush();
            if(timing)timing->flush_ms+=ms(before,Clock::now());
        }
        return slot;
    }
    static void copy_region(ID3D11DeviceContext* context,const CapturedBands& frame,ID3D11Texture2D* destination,unsigned x,unsigned y,const D3D11_BOX& crop){
        D3D11_TEXTURE2D_DESC d{};destination->GetDesc(&d);
        if(crop.front!=0 || crop.back!=1 || crop.left>=crop.right || crop.top>=crop.bottom || crop.right>frame.width || crop.bottom>frame.height || x>d.Width || y>d.Height || crop.right-crop.left>d.Width-x || crop.bottom-crop.top>d.Height-y || d.Format!=DXGI_FORMAT_B8G8R8A8_UNORM)throw std::runtime_error("band atlas bounds");
        for(const auto& b:frame.bands){
            const auto top=std::max(crop.top,b.y),bottom=std::min(crop.bottom,b.y+b.height);if(top>=bottom)continue;
            const D3D11_BOX box{crop.left,top-b.y,0,crop.right,bottom-b.y,1};
            context->CopySubresourceRegion(destination,0,x,y+top-crop.top,0,b.texture.Get(),0,&box);
        }
    }
    static void assemble(ID3D11DeviceContext* context,const CapturedBands& frame,ID3D11Texture2D* destination,unsigned x=0,unsigned y=0){
        copy_region(context,frame,destination,x,y,D3D11_BOX{0,0,0,frame.width,frame.height,1});
    }
};
class BandPublication {
    std::shared_ptr<CapturedBands> capture_;
    std::unique_ptr<Frames::Write> write_;
    std::unique_ptr<ProgressiveStorage::Write> progressive_;
    unsigned next_{};
    const bool trace_=std::getenv("VIEWFLOW_SHM_BAND_TRACE")!=nullptr;
    const unsigned publication_rows_=[]{const auto* value=std::getenv("VIEWFLOW_SHM_PUBLICATION_ROWS");return value && std::strcmp(value,"1024")==0?1024u:0u;}();
    std::chrono::steady_clock::time_point last_poll_{},created_=std::chrono::steady_clock::now();
public:
    struct BandTime {unsigned row_begin{},row_end{};std::int64_t copy_begin{},published{};};
    std::array<BandTime,16> band_times{};unsigned band_time_count{};
    static std::int64_t trace_clock(){LARGE_INTEGER q{},f{};QueryPerformanceCounter(&q);QueryPerformanceFrequency(&f);return q.QuadPart/f.QuadPart*10000000+(q.QuadPart%f.QuadPart)*10000000/f.QuadPart;}
    double map_ms{},publish_ms{},query_max_ms{},poll_gap_max_ms{},first_poll_ms{},unmap_max_ms{};
    std::optional<bool> first_copy_before_last_ready;
    std::optional<fixture_stamp::Stamp> pixel_stamp;
    BandPublication(std::shared_ptr<CapturedBands> capture,std::unique_ptr<Frames::Write> write):capture_(std::move(capture)),write_(std::move(write)){
        if(!capture_ || !write_)throw std::runtime_error("band publication ownership");
    }
    BandPublication(std::shared_ptr<CapturedBands> capture,std::unique_ptr<ProgressiveStorage::Write> write):capture_(std::move(capture)),progressive_(std::move(write)){
        if(!capture_ || !progressive_)throw std::runtime_error("progressive band publication ownership");
    }
    std::optional<std::vector<std::uint8_t>> early_reference()const {
        if(progressive_)return progressive_->reference();return {};
    }
    std::optional<std::vector<std::uint8_t>> poll(ID3D11DeviceContext* context){
        if(!write_ && !progressive_)throw std::runtime_error("band publication already complete");
        if(trace_){const auto now=std::chrono::steady_clock::now();if(last_poll_==std::chrono::steady_clock::time_point{})first_poll_ms=std::chrono::duration<double,std::milli>(now-created_).count();else poll_gap_max_ms=std::max(poll_gap_max_ms,std::chrono::duration<double,std::milli>(now-last_poll_).count());last_poll_=now;}
        while(next_<capture_->bands.size()){
            auto& b=capture_->bands[next_];BOOL done=FALSE;
            const auto query_begin=trace_?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};
            const auto ready=context->GetData(b.done.Get(),&done,sizeof(done),D3D11_ASYNC_GETDATA_DONOTFLUSH);
            if(trace_)query_max_ms=std::max(query_max_ms,std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-query_begin).count());
            if(FAILED(ready))throw std::runtime_error("band GPU completion failed");
            if(ready!=S_OK || !done)return {};
            if(next_==0 && std::getenv("VIEWFLOW_SHM_BAND_TRACE")){
                BOOL last_done=FALSE;
                const auto last_ready=context->GetData(capture_->bands.back().done.Get(),&last_done,sizeof(last_done),D3D11_ASYNC_GETDATA_DONOTFLUSH);
                if(FAILED(last_ready))throw std::runtime_error("band final readiness query failed");
                first_copy_before_last_ready=last_ready!=S_OK || !last_done;
            }
            const auto map_begin=std::chrono::steady_clock::now();
            D3D11_MAPPED_SUBRESOURCE mapped{};const auto hr=context->Map(b.texture.Get(),0,D3D11_MAP_READ,D3D11_MAP_FLAG_DO_NOT_WAIT,&mapped);
            if(hr==DXGI_ERROR_WAS_STILL_DRAWING)return {};
            if(FAILED(hr))throw std::runtime_error("band map failed");
            const auto copy_begin=std::chrono::steady_clock::now();
            map_ms+=std::chrono::duration<double,std::milli>(copy_begin-map_begin).count();
            const auto copy_qpc=trace_?trace_clock():0;
            try{
                if(progressive_){
                    // GPU staging is already complete for this entire band.
                    // Publish immutable CPU-copied prefixes while retaining the
                    // mapped texture and writer lease through the last chunk.
                    progressive_->append_chunked({static_cast<const std::uint8_t*>(mapped.pData),std::size_t(mapped.RowPitch)*(b.height-1)+std::size_t(capture_->width)*4},mapped.RowPitch,b.height,publication_rows_);
                }else write_->append(mapped.pData,mapped.RowPitch,b.height);
            }catch(...){context->Unmap(b.texture.Get(),0);throw;}
            if(trace_)band_times[band_time_count++]={b.y,b.y+b.height,copy_qpc,trace_clock()};
            publish_ms+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-copy_begin).count();
            if(next_==0 && std::getenv("VIEWFLOW_FIXTURE_PIXEL_STAMP") && capture_->width>=fixture_stamp::width)
                pixel_stamp=fixture_stamp::decode({static_cast<const std::uint8_t*>(mapped.pData),fixture_stamp::width*4});
            const auto unmap_begin=trace_?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};
            context->Unmap(b.texture.Get(),0);
            if(trace_)unmap_max_ms=std::max(unmap_max_ms,std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-unmap_begin).count());
            ++next_;
        }
        std::vector<std::uint8_t> reference;
        if(progressive_){reference=progressive_->reference();progressive_->finish();progressive_.reset();}
        else {reference=write_->finish();write_.reset();}
        capture_.reset();return reference;
    }
};
}

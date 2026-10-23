#define NOMINMAX
#include "shared_readback.hpp"
#include "banded_staging.hpp"
#include <cassert>
#include <thread>
#include <cstdio>
#include <malloc.h>
using namespace viewflow::reverse;
using Microsoft::WRL::ComPtr;
int main(int argc,char**) {
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
    assert(SUCCEEDED(D3D11CreateDevice(nullptr,argc>1?D3D_DRIVER_TYPE_HARDWARE:D3D_DRIVER_TYPE_WARP,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context)));
    const unsigned width=argc>2?6144:17,height=argc>2?3456:13;
    D3D11_TEXTURE2D_DESC desc{};desc.Width=width;desc.Height=height;desc.MipLevels=desc.ArraySize=1;desc.SampleDesc.Count=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;
    ComPtr<ID3D11Texture2D> source;assert(SUCCEEDED(device->CreateTexture2D(&desc,nullptr,&source)));
    std::vector<unsigned> input(width*height);
    auto paint=[&](unsigned seed){for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x)input[y*width+x]=0xff000000u|(seed<<16)|(y<<8)|x;context->UpdateSubresource(source.Get(),0,nullptr,input.data(),width*4,0);};
    const auto storage_bytes=shm::header_bytes+4*std::max(std::size_t(65536),std::size_t(width)*height*4);
    std::unique_ptr<void,decltype(&_aligned_free)> storage(_aligned_malloc(storage_bytes,4096),&_aligned_free);assert(storage);
    std::memset(storage.get(),0,storage_bytes);
    shm::Frames writer(storage.get(),storage_bytes),reader(storage.get(),storage_bytes);
    writer.streaming_writes=true;writer.parallel_writes=true;
    shm::Readback readback(writer);shm::CaptureStaging pool;std::shared_ptr<shm::CapturedStaging> current;
    D3D11_BOX whole{0,0,0,width,height,1};
    auto frame=[](unsigned w,unsigned h,long long pts){Frame f;f.width=w;f.height=h;f.pts=pts;return f;};
    {
        shm::BandedStaging bands;paint(7);
        auto captured=bands.copy(device.Get(),context.Get(),source.Get(),whole,{},4);assert(captured);
        shm::Readback early(writer);early.progressive=true;
        assert(early.adopt_bands(captured,frame(width,height,91)));
        unsigned callbacks=0;std::shared_ptr<shm::ProgressiveStorage::Read> lease;
        auto receive=[&](const Frame& f){
            ++callbacks;assert(callbacks==1);assert(f.pts==91);
            lease=reader.acquire_progressive(f.color,f.width,f.height,{});assert(lease);
            assert(lease->prefix().empty());assert(!lease->complete());
            assert(early.last_timing.publish_ms<0);
        };
        const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(10);
        while(!early.idle()){early.poll(context.Get(),receive);assert(std::chrono::steady_clock::now()<until);std::this_thread::yield();}
        assert(callbacks==1 && lease->complete());
        assert(lease->prefix().size()==input.size()*4);
        assert(!std::memcmp(lease->prefix().data(),input.data(),input.size()*4));lease.reset();
        // Cancel after reference delivery but before any staging band is copied.
        {
            shm::Readback canceled(writer);canceled.progressive=true;
            assert(canceled.adopt_bands(captured,frame(width,height,92)));
            bool threw=false;
            try{canceled.poll(context.Get(),[&](const Frame& f){lease=reader.acquire_progressive(f.color,f.width,f.height,{});assert(lease);throw std::runtime_error("diagnostic cancellation");});}
            catch(const std::runtime_error&){threw=true;}
            assert(threw && lease && !lease->aborted());
        }
        assert(lease->aborted());lease.reset();writer.reap_progressive();
        std::puts("progressive_early_reference=1 exact_pixels=1 duplicate_callbacks=0 canceled_reference_aborted=1");
    }
    {
        shm::BandedStaging bands;std::shared_ptr<shm::CapturedBands> band_frame;
        paint(3);
        for(unsigned count:{1u,2u,4u,16u})for(const auto crop:{whole,D3D11_BOX{2,3,0,9,8,1}}){
            band_frame=bands.copy(device.Get(),context.Get(),source.Get(),crop,band_frame,count);assert(band_frame);
            const auto w=crop.right-crop.left,h=crop.bottom-crop.top;
            shm::BandPublication publication(band_frame,writer.begin_write(77,count,w,h));
            std::optional<std::vector<std::uint8_t>> ref;
            const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(5);
            while(!(ref=publication.poll(context.Get()))){assert(std::chrono::steady_clock::now()<until);std::this_thread::yield();}
            auto bytes=reader.read(*ref,w,h);assert(bytes);
            for(unsigned y=0;y<h;++y)assert(!std::memcmp(bytes->data()+y*w*4,input.data()+(y+crop.top)*width+crop.left,w*4));
            const auto refs=band_frame.use_count();
            assert(readback.adopt_bands(band_frame,frame(w,h,100+count)));
            bool delivered=false;
            while(!readback.idle()){
                readback.poll(context.Get(),[&](const Frame& f){
                    assert(f.codec==shm::codec && band_frame.use_count()==refs);
                    auto result=reader.read(f.color,w,h);assert(result && *result==*bytes);delivered=true;
                });
                assert(std::chrono::steady_clock::now()<until);std::this_thread::yield();
            }
            assert(delivered);
            auto d=desc;d.Width=w;d.Height=h;
            ComPtr<ID3D11Texture2D> assembled;assert(SUCCEEDED(device->CreateTexture2D(&d,nullptr,&assembled)));
            shm::BandedStaging::assemble(context.Get(),*band_frame,assembled.Get());
            shm::CaptureStaging check_pool;auto check_frame=check_pool.copy(device.Get(),context.Get(),assembled.Get(),D3D11_BOX{0,0,0,w,h,1},{});
            BOOL done=FALSE;while(context->GetData(check_frame->done.Get(),&done,sizeof(done),D3D11_ASYNC_GETDATA_DONOTFLUSH)!=S_OK || !done){assert(std::chrono::steady_clock::now()<until);std::this_thread::yield();}
            D3D11_MAPPED_SUBRESOURCE mapped{};assert(SUCCEEDED(context->Map(check_frame->texture.Get(),0,D3D11_MAP_READ,0,&mapped)));
            for(unsigned y=0;y<h;++y)assert(!std::memcmp(static_cast<const char*>(mapped.pData)+y*mapped.RowPitch,bytes->data()+y*w*4,w*4));
            context->Unmap(check_frame->texture.Get(),0);
            // Copy a region spanning band boundaries to a different atlas origin.
            shm::BandedStaging::copy_region(context.Get(),*band_frame,assembled.Get(),0,0,D3D11_BOX{1,1,0,w,h,1});
            check_frame=check_pool.copy(device.Get(),context.Get(),assembled.Get(),D3D11_BOX{0,0,0,w,h,1},check_frame);
            done=FALSE;while(context->GetData(check_frame->done.Get(),&done,sizeof(done),D3D11_ASYNC_GETDATA_DONOTFLUSH)!=S_OK || !done){assert(std::chrono::steady_clock::now()<until);std::this_thread::yield();}
            assert(SUCCEEDED(context->Map(check_frame->texture.Get(),0,D3D11_MAP_READ,0,&mapped)));
            for(unsigned y=0;y<h-1;++y)assert(!std::memcmp(static_cast<const char*>(mapped.pData)+y*mapped.RowPitch,bytes->data()+((y+1)*w+1)*4,(w-1)*4));
            context->Unmap(check_frame->texture.Get(),0);
        }
        shm::BandedStaging bounded;std::vector<std::shared_ptr<shm::CapturedBands>> held;
        for(unsigned i=0;i<3;++i){auto f=bounded.copy(device.Get(),context.Get(),source.Get(),whole,{});assert(f);held.push_back(f);}
        assert(!bounded.copy(device.Get(),context.Get(),source.Get(),whole,{}));held.clear();assert(bounded.copy(device.Get(),context.Get(),source.Get(),whole,{}));
        std::fprintf(stderr,"banded staging publication, crop, atlas reconstruction, pool ownership passed\n");
    }
    paint(1);current=pool.copy(device.Get(),context.Get(),source.Get(),whole,current);assert(current);
    assert(readback.adopt(current,frame(width,height,1)));
    paint(2);current=pool.copy(device.Get(),context.Get(),source.Get(),whole,current);assert(current);
    assert(readback.adopt(current,frame(width,height,2)));
    assert(!readback.available());
    paint(3);current=pool.copy(device.Get(),context.Get(),source.Get(),whole,current);assert(current);
    const auto* unleased=current.get();
    paint(4);current=pool.copy(device.Get(),context.Get(),source.Get(),whole,current);assert(current.get()==unleased);
    unsigned received=0;
    const auto collect=[&](unsigned first,unsigned crop_x,unsigned crop_y) {
        const auto start=std::chrono::steady_clock::now();
        while(!readback.idle()) {
            readback.poll(context.Get(),[&](const Frame& f){
                auto bytes=reader.read(f.color,f.width,f.height);assert(bytes);
                const unsigned seed=first+received;
                for(unsigned y=0;y<f.height;++y)for(unsigned x=0;x<f.width;++x) {
                    unsigned pixel{};std::memcpy(&pixel,bytes->data()+(y*f.width+x)*4,4);
                    assert(pixel==(0xff000000u|(seed<<16)|((y+crop_y)<<8)|(x+crop_x)));
                }
                ++received;
            });
            assert(std::chrono::steady_clock::now()-start<std::chrono::seconds(5));std::this_thread::yield();
        }
    };
    collect(1,0,0);assert(received==2); // New captures did not overwrite leased A/B.
    D3D11_BOX cropped{2,3,0,9,8,1};
    current=pool.copy(device.Get(),context.Get(),source.Get(),cropped,current);assert(current && current->width==7 && current->height==5);
    assert(readback.adopt(current,frame(7,5,3)));received=0;collect(4,2,3);assert(received==1);
    // Staging captures also remain valid GPU sources for multi-window atlases.
    desc.Width=7;desc.Height=5;ComPtr<ID3D11Texture2D> atlas;assert(SUCCEEDED(device->CreateTexture2D(&desc,nullptr,&atlas)));
    context->CopyResource(atlas.Get(),current->texture.Get());
    assert(readback.enqueue(device.Get(),context.Get(),atlas.Get(),frame(7,5,4)));received=0;collect(4,2,3);assert(received==1);
    readback.single_pending=true;assert(readback.adopt(current,frame(7,5,5)));assert(!readback.adopt(current,frame(7,5,6)));received=0;collect(4,2,3);
    // Bounded pool exhaustion must retain snapshots and recover on release.
    shm::CaptureStaging bounded;std::shared_ptr<shm::CapturedStaging> latest;
    std::vector<std::shared_ptr<shm::CapturedStaging>> held;
    for(unsigned i=0;i<3;++i){latest=bounded.copy(device.Get(),context.Get(),source.Get(),whole,latest);assert(latest);held.push_back(latest);}
    assert(!bounded.copy(device.Get(),context.Get(),source.Get(),whole,latest));
    held.erase(held.begin());assert(bounded.copy(device.Get(),context.Get(),source.Get(),whole,latest));
    // A downstream exception must still Unmap and return the external lease.
    const auto references_before_publish=current.use_count();
    assert(readback.adopt(current,frame(7,5,7)));bool threw=false;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
    while(!readback.idle()) {
        try {readback.poll(context.Get(),[&](const Frame&){assert(current.use_count()==references_before_publish);throw std::runtime_error("consumer failure");});}catch(const std::runtime_error&){threw=true;}
        assert(std::chrono::steady_clock::now()<deadline);std::this_thread::yield();
    }
    assert(threw);paint(5);current=pool.copy(device.Get(),context.Get(),source.Get(),cropped,current);assert(current);
    assert(readback.adopt(current,frame(7,5,8)));received=0;collect(5,2,3);
    // Two completed pixel-only snapshots publish only the newest exact image.
    readback.single_pending=false;readback.latest_ready=true;
    const auto wait_ready=[&] {
        BOOL done=FALSE;const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(5);
        while(context->GetData(current->done.Get(),&done,sizeof(done),D3D11_ASYNC_GETDATA_DONOTFLUSH)==S_FALSE || !done){assert(std::chrono::steady_clock::now()<until);std::this_thread::yield();}
    };
    paint(6);current=pool.copy(device.Get(),context.Get(),source.Get(),cropped,current);assert(readback.adopt(current,frame(7,5,9)));
    paint(7);current=pool.copy(device.Get(),context.Get(),source.Get(),cropped,current);assert(readback.adopt(current,frame(7,5,10)));
    wait_ready();received=0;collect(7,2,3);assert(received==1 && readback.superseded_frames==1);
    // An activity transition must not disappear when both copies are ready.
    auto old=frame(7,5,11),next=frame(7,5,12);next.activity_epoch=1;
    paint(8);current=pool.copy(device.Get(),context.Get(),source.Get(),cropped,current);assert(readback.adopt(current,old));
    paint(9);current=pool.copy(device.Get(),context.Get(),source.Get(),cropped,current);assert(readback.adopt(current,next));
    wait_ready();received=0;collect(8,2,3);assert(received==2 && readback.superseded_frames==1);
    old.tiles.resize(1);next=old;next.pts++;
    assert(shm::supersedes_readback(next,old));
    next.tiles[0].geometry_ack=1;assert(!shm::supersedes_readback(next,old));
    next=old;next.pts++;next.tiles[0].icon_png={1};assert(!shm::supersedes_readback(next,old));
    next=old;next.pts++;next.tiles[0].flags=5;assert(!shm::supersedes_readback(next,old));
    next=old;next.pts++;next.tiles[0].resident_width=1;assert(!shm::supersedes_readback(next,old));
    if(argc>3) {
        // Optional isolated copy probe: real mapped D3D staging source, ordinary
        // aligned RAM destination. This does not measure PCI IVSHMEM writes.
        current=pool.copy(device.Get(),context.Get(),source.Get(),whole,current);assert(current);
        BOOL done=FALSE;const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(5);
        while(context->GetData(current->done.Get(),&done,sizeof(done),D3D11_ASYNC_GETDATA_DONOTFLUSH)==S_FALSE || !done) {
            assert(std::chrono::steady_clock::now()<until);std::this_thread::yield();
        }
        D3D11_MAPPED_SUBRESOURCE mapped{};assert(SUCCEEDED(context->Map(current->texture.Get(),0,D3D11_MAP_READ,0,&mapped)));
        MEMORY_BASIC_INFORMATION memory{};assert(VirtualQuery(mapped.pData,&memory,sizeof(memory))==sizeof(memory));
        std::printf("copy-probe source_protect=0x%lx source_type=0x%lx row_pitch=%u width=%u height=%u destination=ordinary-aligned-RAM\n",memory.Protect,memory.Type,mapped.RowPitch,width,height);
        auto* destination=static_cast<std::uint8_t*>(storage.get());const auto* data=static_cast<const std::uint8_t*>(mapped.pData);
        const std::size_t row_bytes=std::size_t(width)*4;
        for(bool cached: {false,true})for(bool avx2: {false,true})for(unsigned threads: {0u,1u,2u,4u}) {
            if(cached && (avx2 || !threads))continue;
            if(avx2 && (!threads || !shm::copy_avx2_available()))continue;
            shm::ParallelCopy copier(std::max(1u,threads),avx2,cached);std::vector<double> samples;
            for(unsigned iteration=0;iteration<24;++iteration) {
                const auto begin=std::chrono::steady_clock::now();
                if(threads)copier.copy(destination,data,row_bytes,mapped.RowPitch,height);
                else for(unsigned y=0;y<height;++y)std::memcpy(destination+y*row_bytes,data+std::size_t(y)*mapped.RowPitch,row_bytes);
                const auto end=std::chrono::steady_clock::now();
                if(iteration>=4)samples.push_back(std::chrono::duration<double,std::milli>(end-begin).count());
            }
            for(unsigned y=0;y<height;++y)assert(std::memcmp(destination+y*row_bytes,data+std::size_t(y)*mapped.RowPitch,row_bytes)==0);
            std::sort(samples.begin(),samples.end());
            std::printf("copy-probe threads=%u mode=%s p50_ms=%.3f p95_ms=%.3f exact_pixels=1\n",threads,threads?(cached?"parallel-memcpy":avx2?"avx2":"sse2"):"memcpy",samples[samples.size()/2],samples[samples.size()*95/100]);
        }
        context->Unmap(current->texture.Get(),0);
    }
    std::printf("capture staging leases, reuse, crop/resize, adoption, atlas fallback and publication pixels passed width=%u height=%u hardware=%u\n",width,height,unsigned(argc>1));
}

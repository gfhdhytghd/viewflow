#include "shared_readback.hpp"
#include <io.h>
#include <fcntl.h>
#include <cstdio>
#include <thread>
#include <chrono>
#include <algorithm>
using namespace viewflow::reverse;
int main(int argc,char** argv){try{
    if(argc==2 && std::string(argv[1])=="--clock") {
        _setmode(_fileno(stdin),_O_BINARY);_setmode(_fileno(stdout),_O_BINARY);
        LARGE_INTEGER frequency{};QueryPerformanceFrequency(&frequency);
        std::puts("READY");std::fflush(stdout);char request{};
        while(std::fread(&request,1,1,stdin)==1)if(request=='t') {
            LARGE_INTEGER ticks{};QueryPerformanceCounter(&ticks);
            std::printf("%lld %lld\n",ticks.QuadPart,frequency.QuadPart);std::fflush(stdout);
        }
        return 0;
    }
    const unsigned width=argc>1?std::stoul(argv[1]):1920,height=argc>2?std::stoul(argv[2]):1080,count=argc>3?std::stoul(argv[3]):120;
    const unsigned fps=argc>4?std::stoul(argv[4]):0;
    const bool performance=argc>5 && std::string(argv[5])=="--performance";
    shm::Mapping mapping(0);auto frames=mapping.frames();frames.streaming_writes=argc>6 && std::string(argv[6])=="--streaming";frames.parallel_writes=argc>7 && std::string(argv[7])=="--parallel";shm::Readback readback(frames);readback.measure=true;
    Microsoft::WRL::ComPtr<ID3D11Device> device;Microsoft::WRL::ComPtr<ID3D11DeviceContext> context;
    if(FAILED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context)))throw std::runtime_error("probe D3D device");
    Microsoft::WRL::ComPtr<IDXGIDevice> dxgi;Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;DXGI_ADAPTER_DESC gpu{};
    if(SUCCEEDED(device.As(&dxgi)) && SUCCEEDED(dxgi->GetAdapter(&adapter)) && SUCCEEDED(adapter->GetDesc(&gpu)))std::fprintf(stderr,"ivshmem-probe GPU vendor=%04x device=%04x\n",gpu.VendorId,gpu.DeviceId);
    _setmode(_fileno(stdout),_O_BINARY);
    D3D11_TEXTURE2D_DESC desc{};desc.Width=width;desc.Height=height;desc.ArraySize=desc.MipLevels=desc.SampleDesc.Count=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_RENDER_TARGET;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;if(FAILED(device->CreateTexture2D(&desc,nullptr,&texture)))throw std::runtime_error("probe texture");
    Microsoft::WRL::ComPtr<ID3D11RenderTargetView> target;
    if(FAILED(device->CreateRenderTargetView(texture.Get(),nullptr,&target)))throw std::runtime_error("probe render target");
    std::vector<std::uint8_t> pixels(performance?0:std::size_t(width)*height*4);unsigned sent=0;
    std::vector<std::chrono::steady_clock::time_point> submitted(count+1);
    std::vector<double> ready_ms,map_ms,publish_ms;
    auto publish=[&](const Frame& f){map_ms.push_back(readback.last_timing.map_ms);publish_ms.push_back(readback.last_timing.publish_ms);ready_ms.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-submitted.at(f.pts)).count());auto bytes=pack_frame(f);Writer prefix;prefix.u32(bytes.size());if(fwrite(prefix.bytes.data(),1,4,stdout)!=4 || fwrite(bytes.data(),1,bytes.size(),stdout)!=bytes.size() || fflush(stdout))throw std::runtime_error("probe pipe");++sent;};
    const auto begin=std::chrono::steady_clock::now();
    for(unsigned i=1;i<=count;++i){
        if(performance){const float color[]={float(i%251)/250.f,.25f,.5f,1.f};context->ClearRenderTargetView(target.Get(),color);}
        else {for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x){auto* p=pixels.data()+(std::size_t(y)*width+x)*4;p[0]=(x+i)%251;p[1]=(y+i)%251;p[2]=i%251;p[3]=128+(x+y)%128;}
        context->UpdateSubresource(texture.Get(),0,nullptr,pixels.data(),width*4,0);}
        Frame f;f.width=width;f.height=height;f.pts=i;
        while(!readback.available()){readback.poll(context.Get(),publish);std::this_thread::yield();}
        submitted[i]=std::chrono::steady_clock::now();
        readback.enqueue(device.Get(),context.Get(),texture.Get(),std::move(f));readback.poll(context.Get(),publish);
        if(fps){const auto next=begin+std::chrono::nanoseconds(1000000000ull*i/fps);
            while(std::chrono::steady_clock::now()<next){readback.poll(context.Get(),publish);std::this_thread::yield();}}
    }
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while(sent<count && std::chrono::steady_clock::now()<deadline){readback.poll(context.Get(),publish);std::this_thread::yield();}
    std::fprintf(stderr,"ivshmem-probe sent=%u requested=%u width=%u height=%u elapsed_ms=%.3f (includes fixture generation and control pipe)\n",sent,count,width,height,std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count());
    std::sort(ready_ms.begin(),ready_ms.end());
    if(!ready_ms.empty())std::fprintf(stderr,"mode=%s readback_publish_p50_ms=%.3f readback_publish_p95_ms=%.3f (GPU copy enqueue to shared publish; excludes capture and pipe)\n",performance?"performance":"correctness",ready_ms[ready_ms.size()/2],ready_ms[ready_ms.size()*95/100]);
    std::sort(map_ms.begin(),map_ms.end());std::sort(publish_ms.begin(),publish_ms.end());
    if(!map_ms.empty())std::fprintf(stderr,"map_p50_ms=%.3f map_p95_ms=%.3f publish_p50_ms=%.3f publish_p95_ms=%.3f\n",map_ms[map_ms.size()/2],map_ms[map_ms.size()*95/100],publish_ms[publish_ms.size()/2],publish_ms[publish_ms.size()*95/100]);
    return sent==count?0:2;
}catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 1;}}

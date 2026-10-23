#include "hardware_encoder.hpp"
#include <wrl/client.h>
#include <d3d11_4.h>
#include <mmsystem.h>
struct ProbeTimer {MMRESULT result=timeBeginPeriod(1);~ProbeTimer(){if(result==TIMERR_NOERROR)timeEndPeriod(1);}};
#include <chrono>
#include <cstdio>
#include <map>
#include <fstream>
#include <cstdlib>
#include <vector>
#include <string>
#include <thread>
using Microsoft::WRL::ComPtr;
using Clock=std::chrono::steady_clock;
int main(int argc,char** argv){
    ProbeTimer timer;
    const unsigned width=argc>1?std::stoul(argv[1]):5120,height=argc>2?std::stoul(argv[2]):2304;
    const unsigned count=argc>3?std::stoul(argv[3]):60,drain_ms=argc>4?std::stoul(argv[4]):20;
    if(!count)return 1;
    std::ofstream output;if(argc>5){output.open(argv[5],std::ios::binary);if(!output)return 10;}
    CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;D3D_FEATURE_LEVEL level{};
    if(FAILED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT|D3D11_CREATE_DEVICE_VIDEO_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,&level,&context)))return 2;
    ComPtr<ID3D11Multithread> mt;device.As(&mt);if(mt)mt->SetMultithreadProtected(TRUE);
    viewflow::reverse::HardwareEncoder encoder;const auto init=Clock::now();
    if(FAILED(encoder.start(device.Get(),width,height,60,2)))return 3;
    std::printf("init_us=%lld width=%u height=%u count=%u drain_ms=%u\n",static_cast<long long>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-init).count()),width,height,count,drain_ms);
    D3D11_TEXTURE2D_DESC d{};d.Width=width;d.Height=height;d.ArraySize=d.MipLevels=d.SampleDesc.Count=1;d.Format=DXGI_FORMAT_B8G8R8A8_UNORM;d.BindFlags=D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> texture;ComPtr<ID3D11RenderTargetView> target;
    if(FAILED(device->CreateTexture2D(&d,nullptr,&texture))||FAILED(device->CreateRenderTargetView(texture.Get(),nullptr,&target)))return 4;
    const bool detail=std::getenv("VIEWFLOW_PROBE_DETAIL")!=nullptr;
    std::vector<unsigned char> pixels;if(detail){pixels.resize(std::size_t(width)*height*4);for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x){const auto at=(std::size_t(y)*width+x)*4;pixels[at]=static_cast<unsigned char>(x*7+y*3);pixels[at+1]=static_cast<unsigned char>(x/8+y/8);pixels[at+2]=static_cast<unsigned char>((x^y)*11);pixels[at+3]=255;}}
    std::printf("detail=%u\n",unsigned(detail));
    const auto start=Clock::now();auto next=start,last=start;std::map<std::int64_t,Clock::time_point> accepted;unsigned sent=0,received=0;
    while(received<count && Clock::now()-start<std::chrono::seconds(20)){
        std::vector<viewflow::reverse::EncodedFrame> frames;if(FAILED(encoder.poll(frames)))return 5;
        for(const auto& f:frames){if(output.is_open()){output.write(reinterpret_cast<const char*>(f.bytes.data()),f.bytes.size());if(!output)return 11;}auto it=accepted.find(f.timestamp);if(it==accepted.end())return 6;
            std::printf("frame=%lld latency_us=%lld key=%u bytes=%zu\n",static_cast<long long>(f.timestamp),static_cast<long long>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-it->second).count()),unsigned(f.keyframe),f.bytes.size());accepted.erase(it);++received;}
        if(sent<count && Clock::now()>=next && encoder.can_submit()==S_OK){
            const float color[]={float(sent%60)/60,0.3f,0.5f,1};context->ClearRenderTargetView(target.Get(),color);
            if(detail){const unsigned offset=sent%height;D3D11_BOX upper{0,0,0,width,height-offset,1};context->UpdateSubresource(texture.Get(),0,&upper,pixels.data()+std::size_t(offset)*width*4,width*4,0);if(offset){D3D11_BOX lower{0,height-offset,0,width,height,1};context->UpdateSubresource(texture.Get(),0,&lower,pixels.data(),width*4,0);}}
            const auto begin=Clock::now();const auto hr=encoder.submit(texture.Get(),sent,sent==0);if(FAILED(hr))return 7;
            if(hr==S_OK){accepted.emplace(sent,begin);++sent;last=Clock::now();next=start+std::chrono::microseconds(16667LL*sent);}
        }
        if(!accepted.empty() && Clock::now()-last>=std::chrono::milliseconds(drain_ms))if(FAILED(encoder.request_output()))return 8;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    std::printf("submitted=%u received=%u elapsed_us=%lld\n",sent,received,static_cast<long long>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-start).count()));
    return received==count?0:9;
}

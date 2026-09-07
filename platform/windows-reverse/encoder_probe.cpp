#include "hardware_encoder.hpp"
#include <wrl/client.h>
#include <cstdio>
#include <chrono>
#include <thread>
#include <string>
#include <d3d11_4.h>
using Microsoft::WRL::ComPtr;
int main(int argc, char** argv) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> context;
    D3D_FEATURE_LEVEL level{};
    HRESULT hr=D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, &device, &level, &context);
    if (FAILED(hr)) return 2;
    ComPtr<ID3D11Multithread> mt; device.As(&mt); if (mt) mt->SetMultithreadProtected(TRUE);
    viewflow::reverse::HardwareEncoder encoder;
    const unsigned width=argc>2?static_cast<unsigned>(std::stoul(argv[2])):1280;
    const unsigned height=argc>3?static_cast<unsigned>(std::stoul(argv[3])):720;
    const unsigned codec=argc>4?static_cast<unsigned>(std::stoul(argv[4])):1;
    hr=encoder.start(device.Get(), width, height, 60, codec);
    if (FAILED(hr)) { std::fprintf(stderr,"start=%08lx\n", static_cast<unsigned long>(hr)); return 3; }
    D3D11_TEXTURE2D_DESC desc{}; desc.Width=width;desc.Height=height;desc.ArraySize=1;desc.MipLevels=1;
    desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.BindFlags=D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> texture; hr=device->CreateTexture2D(&desc,nullptr,&texture); if(FAILED(hr)) return 4;
    ComPtr<ID3D11RenderTargetView> target; hr=device->CreateRenderTargetView(texture.Get(),nullptr,&target); if(FAILED(hr)) return 5;
    FILE* file=nullptr; if(argc>1) fopen_s(&file,argv[1],"wb");
    unsigned sent=0,received=0;
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while(std::chrono::steady_clock::now()<deadline && received<60) {
        if(sent<60) {
            const float color[4]={static_cast<float>(sent)/60.0f,0.3f,0.5f,1.0f};
            context->ClearRenderTargetView(target.Get(),color);
            hr=encoder.submit(texture.Get(),static_cast<std::int64_t>(sent)*166667,sent==0);
            if(FAILED(hr)) return 6; if(hr==S_OK) ++sent;
        }
        std::vector<viewflow::reverse::EncodedFrame> frames;
        hr=encoder.poll(frames); if(FAILED(hr)) return 7;
        for(auto& frame:frames) {
            if(file) fwrite(frame.bytes.data(),1,frame.bytes.size(),file);
            ++received;
            std::fprintf(stderr,"encoded frame=%u pts=%lld bytes=%zu key=%d\n",received,static_cast<long long>(frame.timestamp),frame.bytes.size(),frame.keyframe);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    if(file) fclose(file);
    std::fprintf(stderr,"reverse-hardware-probe submitted=%u encoded=%u\n",sent,received);
    return received==60 ? 0 : 8;
}

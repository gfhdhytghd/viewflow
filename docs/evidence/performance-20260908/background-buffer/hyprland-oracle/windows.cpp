#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <winrt/base.h>
#include <array>
#include <vector>
#include <algorithm>
#include <cstring>
#include <cstdio>
#include <string>
#include "hyprland_blur.h"
int main(int n,char** a){if(n!=2)return 2;try{
 using namespace winrt;constexpr UINT w=1024,h=1024;
 com_ptr<ID3D11Device> device;com_ptr<ID3D11DeviceContext> context;check_hresult(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,device.put(),nullptr,context.put()));
 auto dxgi=device.as<IDXGIDevice>();com_ptr<IDXGIAdapter> adapter;check_hresult(dxgi->GetAdapter(adapter.put()));DXGI_ADAPTER_DESC ad{};check_hresult(adapter->GetDesc(&ad));std::printf("adapter_vendor=%u adapter_device=%u\n",ad.VendorId,ad.DeviceId);
 std::vector<uint8_t> pixels(w*h*4);for(UINT y=0;y<h;++y)for(UINT x=0;x<w;++x){auto p=&pixels[(y*w+x)*4];p[2]=(x/4+y/9)%256;p[1]=(x*3/8+y/3)%256;p[0]=((x/37+y/53)%2)?220:30;p[3]=255;}
 D3D11_TEXTURE2D_DESC td{};td.Width=w;td.Height=h;td.MipLevels=td.ArraySize=td.SampleDesc.Count=1;td.Format=DXGI_FORMAT_B8G8R8A8_UNORM;td.BindFlags=D3D11_BIND_SHADER_RESOURCE;D3D11_SUBRESOURCE_DATA data{pixels.data(),w*4,0};com_ptr<ID3D11Texture2D> input,output,readback;check_hresult(device->CreateTexture2D(&td,&data,input.put()));td.BindFlags=D3D11_BIND_RENDER_TARGET;check_hresult(device->CreateTexture2D(&td,nullptr,output.put()));
 com_ptr<ID3D11ShaderResourceView> srv;com_ptr<ID3D11RenderTargetView> rtv;check_hresult(device->CreateShaderResourceView(input.get(),nullptr,srv.put()));check_hresult(device->CreateRenderTargetView(output.get(),nullptr,rtv.put()));
 HyprlandBlur blur;blur.settings.noise=0;blur.Initialize(device.get(),w,h);blur.Draw(srv.get(),rtv.get(),{0,0});
 td.BindFlags=0;td.Usage=D3D11_USAGE_STAGING;td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;check_hresult(device->CreateTexture2D(&td,nullptr,readback.put()));context->CopyResource(readback.get(),output.get());D3D11_MAPPED_SUBRESOURCE map{};check_hresult(context->Map(readback.get(),0,D3D11_MAP_READ,0,&map));
 for(UINT y=0;y<h;++y)for(UINT x=0;x<w;++x){auto src=static_cast<const uint8_t*>(map.pData)+map.RowPitch*y+x*4;auto dst=&pixels[(y*w+x)*4];dst[0]=src[2];dst[1]=src[1];dst[2]=src[0];dst[3]=src[3];}context->Unmap(readback.get(),0);
 FILE* file{};fopen_s(&file,a[1],"wb");if(!file)return 3;auto written=fwrite(pixels.data(),1,pixels.size(),file);fclose(file);if(written!=pixels.size())return 4;
 std::printf("PASS width=1024 height=1024 noise=0 hdr=0 rgba=1 input_injected=0\n");return 0;
 }catch(winrt::hresult_error const& e){std::fprintf(stderr,"error=%08lx %s\n",(unsigned long)e.code().value,winrt::to_string(e.message()).c_str());return 1;}}

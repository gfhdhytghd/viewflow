#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11_4.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <cstdio>
#include <initializer_list>
using Microsoft::WRL::ComPtr;
int main(){
 ComPtr<ID3D11Device> dev;ComPtr<ID3D11DeviceContext> ctx;D3D_FEATURE_LEVEL level{};
 auto hr=D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT|D3D11_CREATE_DEVICE_VIDEO_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&dev,&level,&ctx);std::printf("device=%08lx level=%u\n",(unsigned long)hr,unsigned(level));if(FAILED(hr))return 1;
 ComPtr<IDXGIDevice> dxgi;ComPtr<IDXGIAdapter> adapter;DXGI_ADAPTER_DESC desc{};if(SUCCEEDED(dev.As(&dxgi))&&SUCCEEDED(dxgi->GetAdapter(&adapter))&&SUCCEEDED(adapter->GetDesc(&desc)))std::printf("adapter vendor=%u device=%u\n",desc.VendorId,desc.DeviceId);
 ComPtr<ID3D11Device3> dev3;hr=dev.As(&dev3);std::printf("device3=%08lx\n",(unsigned long)hr);if(FAILED(hr))return 2;
 for(auto format:{DXGI_FORMAT_R8_UNORM,DXGI_FORMAT_R8G8_UNORM}){D3D11_FEATURE_DATA_FORMAT_SUPPORT2 support{format,0};hr=dev->CheckFeatureSupport(D3D11_FEATURE_FORMAT_SUPPORT2,&support,sizeof(support));std::printf("format=%u query=%08lx support2=%u typed_store=%u\n",unsigned(format),(unsigned long)hr,support.OutFormatSupport2,unsigned(bool(support.OutFormatSupport2&D3D11_FORMAT_SUPPORT2_UAV_TYPED_STORE)));}
 for(UINT flags:{UINT(D3D11_BIND_UNORDERED_ACCESS),UINT(D3D11_BIND_UNORDERED_ACCESS|D3D11_BIND_RENDER_TARGET),UINT(D3D11_BIND_UNORDERED_ACCESS|D3D11_BIND_RENDER_TARGET|D3D11_BIND_VIDEO_ENCODER)}){
  D3D11_TEXTURE2D_DESC td{};td.Width=6144;td.Height=3456;td.ArraySize=td.MipLevels=td.SampleDesc.Count=1;td.Format=DXGI_FORMAT_NV12;td.BindFlags=flags;
  ComPtr<ID3D11Texture2D> texture;hr=dev->CreateTexture2D(&td,nullptr,&texture);std::printf("nv12 bind=%u texture=%08lx\n",flags,(unsigned long)hr);if(FAILED(hr))continue;
  for(UINT plane=0;plane<2;++plane){D3D11_UNORDERED_ACCESS_VIEW_DESC1 ud{};ud.Format=plane?DXGI_FORMAT_R8G8_UNORM:DXGI_FORMAT_R8_UNORM;ud.ViewDimension=D3D11_UAV_DIMENSION_TEXTURE2D;ud.Texture2D.PlaneSlice=plane;ComPtr<ID3D11UnorderedAccessView1> view;hr=dev3->CreateUnorderedAccessView1(texture.Get(),&ud,&view);std::printf("nv12 bind=%u plane=%u view=%08lx\n",flags,plane,(unsigned long)hr);}
 }
 return 0;
}

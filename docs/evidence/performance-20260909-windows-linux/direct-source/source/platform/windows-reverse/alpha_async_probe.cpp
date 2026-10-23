#include "alpha_plane.hpp"
#include <d3d11_4.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <thread>
#include <stdexcept>
using Microsoft::WRL::ComPtr;
void check(HRESULT h){if(FAILED(h))throw std::runtime_error("alpha probe HRESULT failure");}
int main(){try{
 ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> ctx;check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&ctx));
 ComPtr<ID3D11Multithread> mt;check(device.As(&mt));mt->SetMultithreadProtected(TRUE);
 for(const auto dimensions:{std::pair{64u,32u},std::pair{6144u,3456u}}){
  auto [w,h]=dimensions;viewflow::reverse::AlphaPlane alpha;check(alpha.start(device.Get(),w,h));
  D3D11_TEXTURE2D_DESC d{};d.Width=w;d.Height=h;d.ArraySize=1;d.MipLevels=1;d.Format=DXGI_FORMAT_B8G8R8A8_UNORM;d.SampleDesc.Count=1;d.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
  ComPtr<ID3D11Texture2D> tex;ComPtr<ID3D11RenderTargetView> target;ComPtr<ID3D11ShaderResourceView> view;check(device->CreateTexture2D(&d,nullptr,&tex));check(device->CreateRenderTargetView(tex.Get(),nullptr,&target));check(device->CreateShaderResourceView(tex.Get(),nullptr,&view));
  unsigned expected[]={0,64,128,255};
  for(unsigned cycle=0;cycle<2;++cycle){
   for(unsigned i=0;i<4;++i){const float rgba[]={.2f,.3f,.4f,expected[i]/255.0f};ctx->ClearRenderTargetView(target.Get(),rgba);if(alpha.enqueue(view.Get(),100+cycle*4+i)!=S_OK)throw std::runtime_error("queue failed before full");}
   if(alpha.enqueue(view.Get(),999)!=S_FALSE)throw std::runtime_error("full queue did not retain ownership");
   unsigned got=0,not_ready=0;const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
   while(got<4 && std::chrono::steady_clock::now()<deadline){std::int64_t tag=-1;std::vector<std::uint8_t> bytes;const auto result=alpha.poll(tag,bytes);check(result);if(result==S_FALSE){++not_ready;std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}if(tag!=100+cycle*4+got || bytes.size()!=std::size_t(w)*h || !std::all_of(bytes.begin(),bytes.end(),[&](auto v){return v==expected[got];}))throw std::runtime_error("alpha tag or exact pixels mismatch");++got;}
   if(got!=4)throw std::runtime_error("alpha completion timeout");std::int64_t tag{};std::vector<std::uint8_t> empty;if(alpha.poll(tag,empty)!=S_FALSE)throw std::runtime_error("empty queue mismatch");
   std::fprintf(stderr,"alpha_async_exact width=%u height=%u cycle=%u completed=%u not_ready=%u\n",w,h,cycle,got,not_ready);
  }
 }
 return 0;
}catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 1;}}

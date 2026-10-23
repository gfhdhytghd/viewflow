#include "alpha_plane.hpp"
#include <d3d11_4.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <thread>
#include <stdexcept>
using Microsoft::WRL::ComPtr;
void check(HRESULT h){if(FAILED(h)){std::fprintf(stderr,"probe_failure hr=%08lx\n",static_cast<unsigned long>(h));throw std::runtime_error("alpha probe HRESULT failure");}}
int main(){try{
 ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> ctx;check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&ctx));
 ComPtr<ID3D11Multithread> mt;check(device.As(&mt));mt->SetMultithreadProtected(TRUE);
 for(const auto dimensions:{std::pair{64u,32u},std::pair{67u,35u},std::pair{6144u,3456u}}){
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
  // Exercise every byte value, partial edge groups, and the one-pixel case
  // that must never be mistaken for a completely opaque frame.
  for(unsigned pattern=0;pattern<3;++pattern) {
   std::vector<std::uint8_t> rgba(std::size_t(w)*h*4,255);
   for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x) {
    const auto a=pattern==0?std::uint8_t((x+17*y)%256):std::uint8_t(pattern==1 && x==w-1 && y==h-1?254:255);
    rgba[(std::size_t(y)*w+x)*4+3]=a;
   }
   ctx->UpdateSubresource(tex.Get(),0,nullptr,rgba.data(),w*4,0);
   const auto expected_tag=1000+pattern;if(alpha.enqueue(view.Get(),expected_tag)!=S_OK)throw std::runtime_error("pattern enqueue failed");
   const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);bool complete=false,opaque=false;std::int64_t tag=-1;std::vector<std::uint8_t> bytes;
   while(std::chrono::steady_clock::now()<deadline) {
    const auto result=alpha.poll(tag,bytes,&opaque);check(result);if(result==S_FALSE){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}complete=true;break;
   }
   if(!complete || tag!=expected_tag || opaque!=(pattern==2))throw std::runtime_error("pattern tag or opaque classification mismatch");
   if(opaque){if(!bytes.empty())throw std::runtime_error("opaque fast path returned full plane");}
   else {
    if(bytes.size()!=std::size_t(w)*h)throw std::runtime_error("pattern alpha size mismatch");
    for(std::size_t i=0;i<bytes.size();++i)if(bytes[i]!=rgba[i*4+3])throw std::runtime_error("pattern exact pixel mismatch");
   }
   std::fprintf(stderr,"alpha_summary_exact width=%u height=%u pattern=%u opaque=%u bytes=%zu\n",w,h,pattern,unsigned(opaque),bytes.size());
  }
 }
 return 0;
}catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 1;}}

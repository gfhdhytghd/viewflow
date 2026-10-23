#define NOMINMAX
#include "window_decoration_gpu.hpp"
#include <cassert>
#include <vector>
#include <cmath>
#include <algorithm>
#include <chrono>
#include <cstdio>
using Microsoft::WRL::ComPtr;
int main(int argc,char**){
 ComPtr<ID3D11Device>d;ComPtr<ID3D11DeviceContext>c;
 assert(SUCCEEDED(D3D11CreateDevice(nullptr,argc>1?D3D_DRIVER_TYPE_HARDWARE:D3D_DRIVER_TYPE_WARP,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&d,nullptr,&c)));
 viewflow::reverse::WindowDecorationGpu effect;assert(SUCCEEDED(effect.start(d.Get())));
 for(unsigned radius: {0u,3u,6u}){
  std::vector<unsigned> pixels(16*16,0xff4080c0u);
  for(unsigned y=0;y<radius;y++)for(unsigned x=0;x<radius;x++)if((radius-x)*(radius-x)+(radius-y)*(radius-y)>radius*radius)pixels[y*16+x]=0;
  D3D11_TEXTURE2D_DESC t{};t.Width=t.Height=16;t.MipLevels=t.ArraySize=1;t.Format=DXGI_FORMAT_B8G8R8A8_UNORM;t.SampleDesc.Count=1;t.BindFlags=D3D11_BIND_SHADER_RESOURCE;
  D3D11_SUBRESOURCE_DATA data{pixels.data(),64,0};ComPtr<ID3D11Texture2D>src;assert(SUCCEEDED(d->CreateTexture2D(&t,&data,&src)));
  ComPtr<ID3D11ShaderResourceView>view;assert(SUCCEEDED(d->CreateShaderResourceView(src.Get(),nullptr,&view)));
  t.Width=t.Height=232;t.BindFlags=D3D11_BIND_RENDER_TARGET;ComPtr<ID3D11Texture2D>dst;assert(SUCCEEDED(d->CreateTexture2D(&t,nullptr,&dst)));
  ComPtr<ID3D11RenderTargetView>target;assert(SUCCEEDED(d->CreateRenderTargetView(dst.Get(),nullptr,&target)));
  assert(SUCCEEDED(effect.draw(c.Get(),view.Get(),target.Get(),16,16,108)));
  t.BindFlags=0;t.Usage=D3D11_USAGE_STAGING;t.CPUAccessFlags=D3D11_CPU_ACCESS_READ;ComPtr<ID3D11Texture2D>read;assert(SUCCEEDED(d->CreateTexture2D(&t,nullptr,&read)));c->CopyResource(read.Get(),dst.Get());
  D3D11_MAPPED_SUBRESOURCE m{};assert(SUCCEEDED(c->Map(read.Get(),0,D3D11_MAP_READ,0,&m)));
  auto sample=[&](unsigned x,unsigned y){return reinterpret_cast<const unsigned*>(static_cast<const char*>(m.pData)+y*m.RowPitch)[x];};
  assert(sample(116,116)==0xff4080c0u); // Opaque source pixels are byte-exact.
  if(!radius)assert((sample(108,108)>>24)==255u);
  if(radius)assert((sample(108,108)>>24)<64); // Real transparent corner remains distinct.
  assert((sample(107,116)>>24)>0 && (sample(107,116)&0xffffffu)==0); // Black outside silhouette shadow.
  // Broad-lobe profile matches the Mac recipe away from the contact band.
  auto lobe=[](double x,double y,double ix,double iy,double off,double r,double range,double opacity){
   ix=std::min(ix,4.);iy=std::min(iy,4.);const double hx=8-ix,hy=8-iy;r=std::min(r,std::min(hx,hy));
   const double qx=std::abs(x-8)-(hx-r),qy=std::abs(y-8-off)-(hy-r);
   const double distance=std::hypot(std::max(qx,0.),std::max(qy,0.))+std::min(std::max(qx,qy),0.)-r;
   return opacity*std::pow(std::clamp(1-std::max(distance,0.)/range,0.,1.),4);
  };
  for(unsigned yy:{60u,80u,160u,200u}){
   const double x=8.5,y=double(yy)+.5-108;
   const double a=lobe(x,y,13,14,17.5,35.5,88,.233),b=lobe(x,y,0,0,19,27,74,.107);
   const auto expected=std::lround((1-(1-a)*(1-b))*255);
   assert(std::abs(long(sample(116,yy)>>24)-expected)<=1);
  }
  c->Unmap(read.Get(),0);
 }
 if(argc>1){
  D3D11_TEXTURE2D_DESC t{};t.Width=1920;t.Height=1080;t.MipLevels=t.ArraySize=1;t.Format=DXGI_FORMAT_B8G8R8A8_UNORM;t.SampleDesc.Count=1;t.BindFlags=D3D11_BIND_SHADER_RESOURCE;
  std::vector<unsigned> pixels(t.Width*t.Height,0xff4080c0u);D3D11_SUBRESOURCE_DATA data{pixels.data(),t.Width*4,0};ComPtr<ID3D11Texture2D>src;assert(SUCCEEDED(d->CreateTexture2D(&t,&data,&src)));
  ComPtr<ID3D11ShaderResourceView>v;assert(SUCCEEDED(d->CreateShaderResourceView(src.Get(),nullptr,&v)));
  t.Width+=216;t.Height+=216;t.BindFlags=D3D11_BIND_RENDER_TARGET;ComPtr<ID3D11Texture2D>dst;assert(SUCCEEDED(d->CreateTexture2D(&t,nullptr,&dst)));ComPtr<ID3D11RenderTargetView>r;assert(SUCCEEDED(d->CreateRenderTargetView(dst.Get(),nullptr,&r)));
  D3D11_QUERY_DESC qd{D3D11_QUERY_EVENT,0};ComPtr<ID3D11Query>q;assert(SUCCEEDED(d->CreateQuery(&qd,&q)));
  auto fence=[&]{c->End(q.Get());c->Flush();BOOL done=FALSE;while(c->GetData(q.Get(),&done,sizeof(done),0)==S_FALSE)Sleep(0);};
  for(int i=0;i<5;i++)assert(SUCCEEDED(effect.draw(c.Get(),v.Get(),r.Get(),1920,1080,108)));fence();
  const auto start=std::chrono::steady_clock::now();
  for(int i=0;i<60;i++)assert(SUCCEEDED(effect.draw(c.Get(),v.Get(),r.Get(),1920,1080,108)));fence();
  const auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
  std::printf("owned-texture-shadow-benchmark hardware=1 body=1920x1080 padding=108 frames=60 wall-ms=%.3f amortized-ms=%.3f input-injected=0\n",ms,ms/60);
 }
}

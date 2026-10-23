#include "window_decoration_gpu.hpp"
#include <d3dcompiler.h>
#include <cstring>
namespace viewflow::reverse {
using Microsoft::WRL::ComPtr;
#define VF_CHECK(x) do { const auto hr=(x);if(FAILED(hr))return hr; } while(false)
HRESULT WindowDecorationGpu::start(ID3D11Device* device) {
    VF_CHECK(device->CreateDeferredContext(0,&deferred_));
    const char* shader=R"(
Texture2D<float4> image:register(t0);SamplerState edge:register(s0);
cbuffer Config:register(b0){float2 size;float padding;float sigma;};
float4 vs(uint id:SV_VertexID):SV_Position{float2 p=float2((id<<1)&2,id&2);return float4(p*float2(2,-2)+float2(-1,1),0,1);}
float lobe(float2 p,float2 inset,float offset,float radius,float range,float opacity){
 inset=min(inset,size*.25);float2 halfSize=size*.5-inset;
 radius=min(radius,min(halfSize.x,halfSize.y));
 float2 q=abs(p-float2(size.x*.5,size.y*.5+offset))-(halfSize-radius);
 float distance=length(max(q,0))+min(max(q.x,q.y),0)-radius;
 float a=saturate(1-max(distance,0)/range);return opacity*a*a*a*a;
}
float4 ps(float4 position:SV_Position):SV_Target{
 float2 p=position.xy-padding;
 // The source body, including its real rounded-corner coverage, is unchanged.
 // Windows native exterior shadow is never reused for our generated padding.
 if(all(p>=0)&&all(p<size))return image.Load(int3(p,0));
 if(padding==0)return 0;
 float scale=padding/108;
 float a=lobe(p,float2(13,14)*scale,17.5*scale,35.5*scale,88*scale,.233);
 float b=lobe(p,0,19*scale,27*scale,74*scale,.107);
 float contact=0;
 // Contact lobe follows actual source alpha; only the two-DIP boundary needs
 // texture sampling. Broad shadows are analytic, not multi-pass convolutions.
 if(all(p>=-2*scale)&&all(p<size+2*scale)){
  [unroll]for(int y=-2;y<=2;y++)[unroll]for(int x=-2;x<=2;x++){
   float2 delta=float2(x,y)*scale;float d=length(delta);
   float w=saturate(1-d/(2*scale));w=w*w*w*w;
   contact=max(contact,.32*w*image.SampleLevel(edge,(p+delta)/size,0).a);
  }
 }
 return float4(0,0,0,1-(1-a)*(1-b)*(1-contact));
}
)";
    ComPtr<ID3DBlob> code,error;
    VF_CHECK(D3DCompile(shader,std::strlen(shader),nullptr,nullptr,nullptr,"vs","vs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&error));
    VF_CHECK(device->CreateVertexShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&vertex_));code.Reset();
    VF_CHECK(D3DCompile(shader,std::strlen(shader),nullptr,nullptr,nullptr,"ps","ps_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&error));
    VF_CHECK(device->CreatePixelShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&pixel_));
    D3D11_BUFFER_DESC buffer{};buffer.ByteWidth=16;buffer.Usage=D3D11_USAGE_DEFAULT;buffer.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
    VF_CHECK(device->CreateBuffer(&buffer,nullptr,&constants_));
    D3D11_SAMPLER_DESC sampler{};sampler.Filter=D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;
    sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D11_TEXTURE_ADDRESS_BORDER;sampler.MaxLOD=D3D11_FLOAT32_MAX;
    VF_CHECK(device->CreateSamplerState(&sampler,&sampler_));return S_OK;
}
HRESULT WindowDecorationGpu::draw(ID3D11DeviceContext* immediate,ID3D11ShaderResourceView* image,ID3D11RenderTargetView* output,unsigned width,unsigned height,unsigned padding) {
    const float config[4]={float(width),float(height),float(padding),float(padding)/108};
    deferred_->UpdateSubresource(constants_.Get(),0,nullptr,config,0,0);
    D3D11_VIEWPORT viewport{0,0,float(width+2*padding),float(height+2*padding),0,1};
    deferred_->RSSetViewports(1,&viewport);deferred_->OMSetRenderTargets(1,&output,nullptr);
    deferred_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    deferred_->VSSetShader(vertex_.Get(),nullptr,0);deferred_->PSSetShader(pixel_.Get(),nullptr,0);
    auto* buffer=constants_.Get();auto* sampler=sampler_.Get();
    deferred_->PSSetConstantBuffers(0,1,&buffer);deferred_->PSSetSamplers(0,1,&sampler);deferred_->PSSetShaderResources(0,1,&image);
    deferred_->Draw(3,0);ComPtr<ID3D11CommandList> commands;
    VF_CHECK(deferred_->FinishCommandList(FALSE,&commands));
    // Atomic submission preserves the immediate context's encoder/alpha state;
    // capture callbacks never interleave a series of shared render-state calls.
    immediate->ExecuteCommandList(commands.Get(),TRUE);return S_OK;
}
}

#pragma once
#include <d3d11.h>
#include <d3dcompiler.h>
#include <winrt/base.h>
#include <vector>
#include <algorithm>
#include <cstring>

// ARM dual-filter weights: five bilinear taps down, eight up. No Gaussian pass.
class DualKawase {
  using winrt_ptr = winrt::com_ptr<ID3D11Texture2D>;
  struct Level {
    UINT width{},height{};
    winrt_ptr texture;
    winrt::com_ptr<ID3D11ShaderResourceView> srv;
    winrt::com_ptr<ID3D11RenderTargetView> rtv;
  };
  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::com_ptr<ID3D11VertexShader> vs_;
  winrt::com_ptr<ID3D11PixelShader> down_,up_;
  winrt::com_ptr<ID3D11SamplerState> sampler_;
  winrt::com_ptr<ID3D11Buffer> constants_;
  winrt::com_ptr<ID3D11RasterizerState> raster_;
  std::vector<Level> levels_;
  static constexpr const char shader[]=R"(
Texture2D source : register(t0); SamplerState linearMirror : register(s0);
cbuffer Params : register(b0) { float2 texel; float offset; float unused; }
struct V { float4 p:SV_Position; float2 uv:TEXCOORD; };
V vs(uint id:SV_VertexID) {
 float2 p[3]={float2(-1,-1),float2(-1,3),float2(3,-1)};
 V o;o.p=float4(p[id],0,1);o.uv=float2((p[id].x+1)*.5,(1-p[id].y)*.5);return o;
}
float4 down(V i):SV_Target {
 float2 d=texel*.5*offset;
 float4 s=source.Sample(linearMirror,i.uv)*4;
 s+=source.Sample(linearMirror,i.uv+float2(-d.x,-d.y));
 s+=source.Sample(linearMirror,i.uv+float2( d.x,-d.y));
 s+=source.Sample(linearMirror,i.uv+float2(-d.x, d.y));
 s+=source.Sample(linearMirror,i.uv+float2( d.x, d.y));return s/8;
}
float4 up(V i):SV_Target {
 float2 d=texel*.5*offset;
 float4 s=source.Sample(linearMirror,i.uv+float2(-2*d.x,0));
 s+=source.Sample(linearMirror,i.uv+float2(-d.x, d.y))*2;
 s+=source.Sample(linearMirror,i.uv+float2(0,2*d.y));
 s+=source.Sample(linearMirror,i.uv+float2(d.x, d.y))*2;
 s+=source.Sample(linearMirror,i.uv+float2(2*d.x,0));
 s+=source.Sample(linearMirror,i.uv+float2(d.x,-d.y))*2;
 s+=source.Sample(linearMirror,i.uv+float2(0,-2*d.y));
 s+=source.Sample(linearMirror,i.uv+float2(-d.x,-d.y))*2;return s/12;
})";
 public:
  void Initialize(ID3D11Device* device,UINT width,UINT height,UINT count) {
    using winrt::check_hresult;
    device_.copy_from(device);device->GetImmediateContext(context_.put());
    auto compile=[&](const char* entry,const char* profile){winrt::com_ptr<ID3DBlob> code,error;check_hresult(D3DCompile(shader,sizeof(shader)-1,"dual_kawase.hlsl",nullptr,nullptr,entry,profile,D3DCOMPILE_ENABLE_STRICTNESS,0,code.put(),error.put()));return code;};
    auto vertex=compile("vs","vs_5_0"),down=compile("down","ps_5_0"),up=compile("up","ps_5_0");
    check_hresult(device->CreateVertexShader(vertex->GetBufferPointer(),vertex->GetBufferSize(),nullptr,vs_.put()));
    check_hresult(device->CreatePixelShader(down->GetBufferPointer(),down->GetBufferSize(),nullptr,down_.put()));
    check_hresult(device->CreatePixelShader(up->GetBufferPointer(),up->GetBufferSize(),nullptr,up_.put()));
    D3D11_SAMPLER_DESC sampler{};sampler.Filter=D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D11_TEXTURE_ADDRESS_MIRROR;sampler.MaxLOD=D3D11_FLOAT32_MAX;
    check_hresult(device->CreateSamplerState(&sampler,sampler_.put()));
    D3D11_BUFFER_DESC cb{};cb.ByteWidth=16;cb.Usage=D3D11_USAGE_DYNAMIC;cb.BindFlags=D3D11_BIND_CONSTANT_BUFFER;cb.CPUAccessFlags=D3D11_CPU_ACCESS_WRITE;
    check_hresult(device->CreateBuffer(&cb,nullptr,constants_.put()));
    D3D11_RASTERIZER_DESC rs{};rs.FillMode=D3D11_FILL_SOLID;rs.CullMode=D3D11_CULL_NONE;rs.DepthClipEnable=TRUE;
    check_hresult(device->CreateRasterizerState(&rs,raster_.put()));
    for(UINT i=0;i<count;++i){width=std::max(1u,(width+1)/2);height=std::max(1u,(height+1)/2);Level next;next.width=width;next.height=height;D3D11_TEXTURE2D_DESC d{};d.Width=width;d.Height=height;d.MipLevels=d.ArraySize=d.SampleDesc.Count=1;d.Format=DXGI_FORMAT_B8G8R8A8_UNORM;d.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
      check_hresult(device->CreateTexture2D(&d,nullptr,next.texture.put()));check_hresult(device->CreateShaderResourceView(next.texture.get(),nullptr,next.srv.put()));check_hresult(device->CreateRenderTargetView(next.texture.get(),nullptr,next.rtv.put()));levels_.push_back(std::move(next));}
  }
  void Draw(ID3D11ShaderResourceView* input,UINT width,UINT height,ID3D11RenderTargetView* target,UINT count,float offset) {
    if(!input||!target||!count||count>levels_.size())throw std::runtime_error("invalid Dual Kawase draw");
    context_->IASetInputLayout(nullptr);context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->VSSetShader(vs_.get(),nullptr,0);context_->GSSetShader(nullptr,nullptr,0);
    context_->RSSetState(raster_.get());context_->OMSetBlendState(nullptr,nullptr,0xffffffff);context_->OMSetDepthStencilState(nullptr,0);
    auto sampler=sampler_.get();context_->PSSetSamplers(0,1,&sampler);auto cb=constants_.get();context_->PSSetConstantBuffers(0,1,&cb);
    auto pass=[&](ID3D11ShaderResourceView* source,UINT sw,UINT sh,ID3D11RenderTargetView* dest,UINT dw,UINT dh,ID3D11PixelShader* ps){
      ID3D11ShaderResourceView* clear{};context_->PSSetShaderResources(0,1,&clear);
      context_->OMSetRenderTargets(1,&dest,nullptr);D3D11_VIEWPORT vp{0,0,float(dw),float(dh),0,1};context_->RSSetViewports(1,&vp);
      D3D11_MAPPED_SUBRESOURCE map{};winrt::check_hresult(context_->Map(constants_.get(),0,D3D11_MAP_WRITE_DISCARD,0,&map));float params[]{1.0f/sw,1.0f/sh,offset,0};std::memcpy(map.pData,params,sizeof(params));context_->Unmap(constants_.get(),0);
      context_->PSSetShader(ps,nullptr,0);context_->PSSetShaderResources(0,1,&source);context_->Draw(3,0);
    };
    for(UINT i=0;i<count;++i){auto& dst=levels_[i];pass(i?levels_[i-1].srv.get():input,i?levels_[i-1].width:width,i?levels_[i-1].height:height,dst.rtv.get(),dst.width,dst.height,down_.get());}
    for(UINT i=count;i>0;--i){auto& src=levels_[i-1];pass(src.srv.get(),src.width,src.height,i>1?levels_[i-2].rtv.get():target,i>1?levels_[i-2].width:width,i>1?levels_[i-2].height:height,up_.get());}
    ID3D11ShaderResourceView* clear{};context_->PSSetShaderResources(0,1,&clear);context_->OMSetRenderTargets(0,nullptr,nullptr);
  }
};

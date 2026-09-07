#include "alpha_plane.hpp"
#include <d3dcompiler.h>
#include <cstring>
namespace viewflow::reverse {
using Microsoft::WRL::ComPtr;
#define CHECK_HR(expr) do {HRESULT vf_hr=(expr);if(FAILED(vf_hr))return vf_hr;}while(0)
HRESULT AlphaPlane::start(ID3D11Device* device,unsigned width,unsigned height) {
    if(!device || !width || !height)return E_INVALIDARG;
    device->GetImmediateContext(&context_);width_=width;height_=height;
    D3D11_TEXTURE2D_DESC desc{};desc.Width=width;desc.Height=height;desc.ArraySize=1;desc.MipLevels=1;
    desc.Format=DXGI_FORMAT_R8_UNORM;desc.SampleDesc.Count=1;desc.BindFlags=D3D11_BIND_RENDER_TARGET;
    CHECK_HR(device->CreateTexture2D(&desc,nullptr,&alpha_));
    CHECK_HR(device->CreateRenderTargetView(alpha_.Get(),nullptr,&target_));
    desc.BindFlags=0;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    CHECK_HR(device->CreateTexture2D(&desc,nullptr,&staging_));
    const char* source=R"(
Texture2D<float4> color:register(t0);
float4 vs(uint id:SV_VertexID):SV_Position {
    float2 p=float2((id<<1)&2,id&2);return float4(p*float2(2,-2)+float2(-1,1),0,1);
}
float ps(float4 pos:SV_Position):SV_Target {return color.Load(int3(pos.xy,0)).a;}
)";
    ComPtr<ID3DBlob> code,error;
    CHECK_HR(D3DCompile(source,std::strlen(source),nullptr,nullptr,nullptr,"vs","vs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&error));
    CHECK_HR(device->CreateVertexShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&vertex_));
    code.Reset();error.Reset();
    CHECK_HR(D3DCompile(source,std::strlen(source),nullptr,nullptr,nullptr,"ps","ps_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&error));
    CHECK_HR(device->CreatePixelShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&pixel_));
    return S_OK;
}
HRESULT AlphaPlane::read(ID3D11ShaderResourceView* source,std::vector<std::uint8_t>& bytes) {
    if(!context_ || !source)return E_INVALIDARG;
    D3D11_VIEWPORT viewport{0,0,static_cast<float>(width_),static_cast<float>(height_),0,1};
    auto* target=target_.Get();
    context_->OMSetRenderTargets(1,&target,nullptr);
    context_->RSSetViewports(1,&viewport);context_->RSSetState(nullptr);
    context_->OMSetBlendState(nullptr,nullptr,0xffffffff);context_->OMSetDepthStencilState(nullptr,0);
    context_->IASetInputLayout(nullptr);context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->VSSetShader(vertex_.Get(),nullptr,0);context_->PSSetShader(pixel_.Get(),nullptr,0);
    context_->PSSetShaderResources(0,1,&source);context_->Draw(3,0);
    ID3D11ShaderResourceView* empty=nullptr;context_->PSSetShaderResources(0,1,&empty);
    context_->OMSetRenderTargets(0,nullptr,nullptr);context_->CopyResource(staging_.Get(),alpha_.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};CHECK_HR(context_->Map(staging_.Get(),0,D3D11_MAP_READ,0,&mapped));
    try {
        bytes.resize(static_cast<std::size_t>(width_)*height_);
        for(unsigned y=0;y<height_;++y)std::memcpy(bytes.data()+static_cast<std::size_t>(y)*width_,static_cast<const std::uint8_t*>(mapped.pData)+static_cast<std::size_t>(y)*mapped.RowPitch,width_);
    }catch(...){context_->Unmap(staging_.Get(),0);throw;}
    context_->Unmap(staging_.Get(),0);return S_OK;
}
}

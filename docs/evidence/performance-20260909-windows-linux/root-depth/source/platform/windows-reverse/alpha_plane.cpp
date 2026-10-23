#include "alpha_plane.hpp"
#include <d3dcompiler.h>
#include <cstring>
#include <cstdio>
namespace viewflow::reverse {
using Microsoft::WRL::ComPtr;
#define CHECK_HR(expr) do {HRESULT vf_hr=(expr);if(FAILED(vf_hr))return vf_hr;}while(0)
HRESULT AlphaPlane::start(ID3D11Device* device,unsigned width,unsigned height) {
    if(!device || !width || !height)return E_INVALIDARG;
    wchar_t value[8]{};
    const bool requested=GetEnvironmentVariableW(L"VIEWFLOW_REVERSE_ALPHA_SUMMARY",value,8)!=1 || value[0]!=L'0';
    if(requested){auto candidate=std::make_unique<CompactAlphaPlane>();const auto result=candidate->start(device,width,height);std::fprintf(stderr,"reverse_alpha_summary enabled=%u hr=%08lx width=%u height=%u\n",unsigned(SUCCEEDED(result)),static_cast<unsigned long>(result),width,height);if(SUCCEEDED(result)){compact_=std::move(candidate);return S_OK;}}
    device->GetImmediateContext(&context_);width_=width;height_=height;
    D3D11_TEXTURE2D_DESC desc{};desc.Width=width;desc.Height=height;desc.ArraySize=1;desc.MipLevels=1;
    desc.Format=DXGI_FORMAT_R8_UNORM;desc.SampleDesc.Count=1;desc.BindFlags=D3D11_BIND_RENDER_TARGET;
    CHECK_HR(device->CreateTexture2D(&desc,nullptr,&alpha_));
    CHECK_HR(device->CreateRenderTargetView(alpha_.Get(),nullptr,&target_));
    desc.BindFlags=0;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    for(auto& slot:slots_){
        CHECK_HR(device->CreateTexture2D(&desc,nullptr,&slot.staging));
        const D3D11_QUERY_DESC query{D3D11_QUERY_EVENT,0};CHECK_HR(device->CreateQuery(&query,&slot.ready));
    }
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
HRESULT AlphaPlane::enqueue(ID3D11ShaderResourceView* source,std::int64_t tag) {
    if(compact_)return compact_->enqueue(source,tag);
    if(!context_ || !source)return E_INVALIDARG;
    if(count_==slots_.size())return S_FALSE;
    auto& slot=slots_[(head_+count_)%slots_.size()];
    D3D11_VIEWPORT viewport{0,0,static_cast<float>(width_),static_cast<float>(height_),0,1};
    auto* target=target_.Get();
    context_->OMSetRenderTargets(1,&target,nullptr);
    context_->RSSetViewports(1,&viewport);context_->RSSetState(nullptr);
    context_->OMSetBlendState(nullptr,nullptr,0xffffffff);context_->OMSetDepthStencilState(nullptr,0);
    context_->IASetInputLayout(nullptr);context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->VSSetShader(vertex_.Get(),nullptr,0);context_->PSSetShader(pixel_.Get(),nullptr,0);
    context_->PSSetShaderResources(0,1,&source);context_->Draw(3,0);
    ID3D11ShaderResourceView* empty=nullptr;context_->PSSetShaderResources(0,1,&empty);
    context_->OMSetRenderTargets(0,nullptr,nullptr);context_->CopyResource(slot.staging.Get(),alpha_.Get());
    context_->End(slot.ready.Get());context_->Flush();slot.tag=tag;++count_;return S_OK;
}
HRESULT AlphaPlane::poll(std::int64_t& tag,std::vector<std::uint8_t>& bytes,bool* opaque_hint) {
    if(compact_)return compact_->poll(tag,bytes,opaque_hint);
    if(opaque_hint)*opaque_hint=false;
    if(!context_)return E_UNEXPECTED;
    if(!count_)return S_FALSE;
    auto& slot=slots_[head_];BOOL ready=FALSE;
    const HRESULT query=context_->GetData(slot.ready.Get(),&ready,sizeof(ready),D3D11_ASYNC_GETDATA_DONOTFLUSH);
    CHECK_HR(query);if(query==S_FALSE || !ready)return S_FALSE;
    D3D11_MAPPED_SUBRESOURCE mapped{};
    const HRESULT mapped_result=context_->Map(slot.staging.Get(),0,D3D11_MAP_READ,D3D11_MAP_FLAG_DO_NOT_WAIT,&mapped);
    if(mapped_result==DXGI_ERROR_WAS_STILL_DRAWING)return S_FALSE;
    CHECK_HR(mapped_result);
    try {
        bytes.resize(static_cast<std::size_t>(width_)*height_);
        for(unsigned y=0;y<height_;++y)std::memcpy(bytes.data()+static_cast<std::size_t>(y)*width_,static_cast<const std::uint8_t*>(mapped.pData)+static_cast<std::size_t>(y)*mapped.RowPitch,width_);
    }catch(...){context_->Unmap(slot.staging.Get(),0);throw;}
    context_->Unmap(slot.staging.Get(),0);tag=slot.tag;head_=(head_+1)%slots_.size();--count_;return S_OK;
}
}

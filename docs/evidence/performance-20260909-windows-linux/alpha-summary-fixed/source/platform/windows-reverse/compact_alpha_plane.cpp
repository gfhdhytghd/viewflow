#include "compact_alpha_plane.hpp"
#include <d3dcompiler.h>
#include <algorithm>
#include <cstring>
#include <cstdio>
namespace viewflow::reverse {
using Microsoft::WRL::ComPtr;
#define CHECK_HR(expr) do {const HRESULT vf_compact_status=(expr);if(FAILED(vf_compact_status)){std::fprintf(stderr,"compact_alpha_failure expr=%s hr=%08lx\n",#expr,static_cast<unsigned long>(vf_compact_status));return vf_compact_status;}}while(0)
HRESULT CompactAlphaPlane::start(ID3D11Device* device,unsigned width,unsigned height) {
    if(!device || !width || !height)return E_INVALIDARG;
    UINT support{};CHECK_HR(device->CheckFormatSupport(DXGI_FORMAT_R8_UINT,&support));
    if(!(support&D3D11_FORMAT_SUPPORT_TYPED_UNORDERED_ACCESS_VIEW))return E_NOTIMPL;
    device->GetImmediateContext(&context_);width_=width;height_=height;groups_x_=(width+63)/64;groups_y_=(height+63)/64;
    for(auto& slot:slots_) {
        D3D11_TEXTURE2D_DESC d{};d.Width=width;d.Height=height;d.ArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Format=DXGI_FORMAT_R8_UINT;d.BindFlags=D3D11_BIND_UNORDERED_ACCESS;
        CHECK_HR(device->CreateTexture2D(&d,nullptr,&slot.alpha));CHECK_HR(device->CreateUnorderedAccessView(slot.alpha.Get(),nullptr,&slot.alpha_view));
        d.Usage=D3D11_USAGE_STAGING;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;d.BindFlags=0;CHECK_HR(device->CreateTexture2D(&d,nullptr,&slot.staging));
        d.Width=groups_x_;d.Height=groups_y_;d.Format=DXGI_FORMAT_R32_UINT;d.Usage=D3D11_USAGE_DEFAULT;d.CPUAccessFlags=0;d.BindFlags=D3D11_BIND_UNORDERED_ACCESS;
        CHECK_HR(device->CreateTexture2D(&d,nullptr,&slot.summary));CHECK_HR(device->CreateUnorderedAccessView(slot.summary.Get(),nullptr,&slot.summary_view));
        d.Usage=D3D11_USAGE_STAGING;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;d.BindFlags=0;CHECK_HR(device->CreateTexture2D(&d,nullptr,&slot.summary_staging));
        const D3D11_QUERY_DESC query{D3D11_QUERY_EVENT,0};CHECK_HR(device->CreateQuery(&query,&slot.ready));
    }
    const char* source=R"(
Texture2D<float4> color:register(t0);
RWTexture2D<uint> alpha:register(u0);
RWTexture2D<uint> summary:register(u1);
groupshared uint opaque_group[256];
[numthreads(16,16,1)]
void main(uint3 group:SV_GroupID,uint3 local:SV_GroupThreadID) {
    uint width,height;alpha.GetDimensions(width,height);uint opaque=1;
    [unroll] for(uint y=0;y<4;++y) [unroll] for(uint x=0;x<4;++x) {
        uint2 p=group.xy*64+local.xy*4+uint2(x,y);
        if(p.x<width && p.y<height) {
            uint value=uint(round(saturate(color.Load(int3(p,0)).a)*255.0));
            alpha[p]=value;opaque&=uint(value==255);
        }
    }
    uint index=local.y*16+local.x;opaque_group[index]=opaque;GroupMemoryBarrierWithGroupSync();
    [unroll] for(uint stride=128;stride>0;stride>>=1) {
        if(index<stride)opaque_group[index]&=opaque_group[index+stride];
        GroupMemoryBarrierWithGroupSync();
    }
    if(index==0)summary[group.xy]=opaque_group[0];
})";
    ComPtr<ID3DBlob> code,error;const auto compiled=D3DCompile(source,std::strlen(source),nullptr,nullptr,nullptr,"main","cs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&error);if(FAILED(compiled) && error)std::fprintf(stderr,"alpha_summary_shader %s\n",static_cast<const char*>(error->GetBufferPointer()));CHECK_HR(compiled);
    CHECK_HR(device->CreateComputeShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&shader_));return S_OK;
}
HRESULT CompactAlphaPlane::enqueue(ID3D11ShaderResourceView* source,std::int64_t tag) {
    if(!context_ || !source)return E_INVALIDARG;if(count_==slots_.size())return S_FALSE;
    auto& slot=slots_[(head_+count_)%slots_.size()];
    ID3D11UnorderedAccessView* outputs[]={slot.alpha_view.Get(),slot.summary_view.Get()};
    context_->CSSetShader(shader_.Get(),nullptr,0);context_->CSSetShaderResources(0,1,&source);context_->CSSetUnorderedAccessViews(0,2,outputs,nullptr);
    context_->Dispatch(groups_x_,groups_y_,1);
    ID3D11ShaderResourceView* empty_source=nullptr;ID3D11UnorderedAccessView* empty_outputs[2]{};
    context_->CSSetShaderResources(0,1,&empty_source);context_->CSSetUnorderedAccessViews(0,2,empty_outputs,nullptr);context_->CSSetShader(nullptr,nullptr,0);
    context_->CopyResource(slot.summary_staging.Get(),slot.summary.Get());context_->End(slot.ready.Get());context_->Flush();
    slot.tag=tag;slot.copying_alpha=false;++count_;return S_OK;
}
HRESULT CompactAlphaPlane::poll(std::int64_t& tag,std::vector<std::uint8_t>& bytes,bool* opaque_hint) {
    if(!context_)return E_UNEXPECTED;if(!count_)return S_FALSE;
    auto& slot=slots_[head_];BOOL ready=FALSE;const auto result=context_->GetData(slot.ready.Get(),&ready,sizeof(ready),D3D11_ASYNC_GETDATA_DONOTFLUSH);
    CHECK_HR(result);if(result==S_FALSE || !ready)return S_FALSE;
    if(!slot.copying_alpha) {
        D3D11_MAPPED_SUBRESOURCE mapped{};const auto hr=context_->Map(slot.summary_staging.Get(),0,D3D11_MAP_READ,D3D11_MAP_FLAG_DO_NOT_WAIT,&mapped);
        if(hr==DXGI_ERROR_WAS_STILL_DRAWING)return S_FALSE;CHECK_HR(hr);bool opaque=true;
        for(unsigned y=0;y<groups_y_;++y) {
            const auto* row=reinterpret_cast<const std::uint32_t*>(static_cast<const std::uint8_t*>(mapped.pData)+std::size_t(y)*mapped.RowPitch);
            for(unsigned x=0;x<groups_x_;++x)opaque=opaque && row[x]==1;
        }
        context_->Unmap(slot.summary_staging.Get(),0);
        if(opaque) {
            if(opaque_hint){*opaque_hint=true;bytes.clear();}else bytes.assign(std::size_t(width_)*height_,255);
            tag=slot.tag;head_=(head_+1)%slots_.size();--count_;return S_OK;
        }
        context_->CopyResource(slot.staging.Get(),slot.alpha.Get());context_->End(slot.ready.Get());context_->Flush();slot.copying_alpha=true;return S_FALSE;
    }
    D3D11_MAPPED_SUBRESOURCE mapped{};const auto hr=context_->Map(slot.staging.Get(),0,D3D11_MAP_READ,D3D11_MAP_FLAG_DO_NOT_WAIT,&mapped);
    if(hr==DXGI_ERROR_WAS_STILL_DRAWING)return S_FALSE;CHECK_HR(hr);
    try {bytes.resize(std::size_t(width_)*height_);for(unsigned y=0;y<height_;++y)std::memcpy(bytes.data()+std::size_t(y)*width_,static_cast<const std::uint8_t*>(mapped.pData)+std::size_t(y)*mapped.RowPitch,width_);}
    catch(...){context_->Unmap(slot.staging.Get(),0);throw;}
    context_->Unmap(slot.staging.Get(),0);if(opaque_hint)*opaque_hint=false;tag=slot.tag;head_=(head_+1)%slots_.size();--count_;return S_OK;
}
}

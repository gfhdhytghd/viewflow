#include "compact_alpha_plane.hpp"
#include "alpha_summary_cs.hpp"
#include "alpha_extract_vs.hpp"
#include "alpha_extract_ps.hpp"
#include <algorithm>
#include <cstring>
#include <cstdio>
#include <chrono>
namespace viewflow::reverse {
using Microsoft::WRL::ComPtr;
#define CHECK_HR(expr) do {const HRESULT vf_compact_status=(expr);if(FAILED(vf_compact_status)){std::fprintf(stderr,"compact_alpha_failure expr=%s hr=%08lx\n",#expr,static_cast<unsigned long>(vf_compact_status));return vf_compact_status;}}while(0)
HRESULT CompactAlphaPlane::start(ID3D11Device* device,unsigned width,unsigned height) {
    auto stage_at=std::chrono::steady_clock::now();const auto stage=[&](const char* name){auto now=std::chrono::steady_clock::now();std::fprintf(stderr,"alpha_init_stage name=%s us=%lld\n",name,static_cast<long long>(std::chrono::duration_cast<std::chrono::microseconds>(now-stage_at).count()));stage_at=now;};
    if(!device || !width || !height)return E_INVALIDARG;
    UINT support{};CHECK_HR(device->CheckFormatSupport(DXGI_FORMAT_R8_UNORM,&support));
    if(!(support&D3D11_FORMAT_SUPPORT_RENDER_TARGET) || !(support&D3D11_FORMAT_SUPPORT_SHADER_LOAD))return E_NOTIMPL;
    device->GetImmediateContext(&context_);width_=width;height_=height;groups_x_=(width+63)/64;groups_y_=(height+63)/64;
    for(auto& slot:slots_) {
        D3D11_TEXTURE2D_DESC d{};d.Width=width;d.Height=height;d.ArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Format=DXGI_FORMAT_R8_UNORM;d.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
        CHECK_HR(device->CreateTexture2D(&d,nullptr,&slot.alpha));CHECK_HR(device->CreateRenderTargetView(slot.alpha.Get(),nullptr,&slot.alpha_target));CHECK_HR(device->CreateShaderResourceView(slot.alpha.Get(),nullptr,&slot.alpha_source));
        d.Usage=D3D11_USAGE_STAGING;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;d.BindFlags=0;CHECK_HR(device->CreateTexture2D(&d,nullptr,&slot.staging));
        d.Width=groups_x_;d.Height=groups_y_;d.Format=DXGI_FORMAT_R32_UINT;d.Usage=D3D11_USAGE_DEFAULT;d.CPUAccessFlags=0;d.BindFlags=D3D11_BIND_UNORDERED_ACCESS;
        CHECK_HR(device->CreateTexture2D(&d,nullptr,&slot.summary));CHECK_HR(device->CreateUnorderedAccessView(slot.summary.Get(),nullptr,&slot.summary_view));
        d.Usage=D3D11_USAGE_STAGING;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;d.BindFlags=0;CHECK_HR(device->CreateTexture2D(&d,nullptr,&slot.summary_staging));
        const D3D11_QUERY_DESC query{D3D11_QUERY_EVENT,0};CHECK_HR(device->CreateQuery(&query,&slot.ready));
    }
    stage("resources");

    CHECK_HR(device->CreateComputeShader(vf_alpha_summary_cs,sizeof(vf_alpha_summary_cs),nullptr,&shader_));
    stage("compute-shader");

    CHECK_HR(device->CreateVertexShader(vf_alpha_extract_vs,sizeof(vf_alpha_extract_vs),nullptr,&vertex_));
    CHECK_HR(device->CreatePixelShader(vf_alpha_extract_ps,sizeof(vf_alpha_extract_ps),nullptr,&pixel_));stage("extract-shaders");return S_OK;
}
HRESULT CompactAlphaPlane::enqueue(ID3D11ShaderResourceView* source,std::int64_t tag,bool full_readback) {
    if(!context_ || !source)return E_INVALIDARG;if(count_==slots_.size())return S_FALSE;
    auto& slot=slots_[(head_+count_)%slots_.size()];
    // Preserve the original fast R8 render-target extraction. Summarize that
    // compact plane, rather than scattering R8_UINT UAV stores from the RGBA
    // compute pass. Keep a slot-owned plane for deferred nonopaque readback.
    D3D11_VIEWPORT viewport{0,0,static_cast<float>(width_),static_cast<float>(height_),0,1};auto* target=slot.alpha_target.Get();
    context_->OMSetRenderTargets(1,&target,nullptr);context_->RSSetViewports(1,&viewport);context_->RSSetState(nullptr);
    context_->OMSetBlendState(nullptr,nullptr,0xffffffff);context_->OMSetDepthStencilState(nullptr,0);
    context_->IASetInputLayout(nullptr);context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);context_->VSSetShader(vertex_.Get(),nullptr,0);context_->PSSetShader(pixel_.Get(),nullptr,0);
    context_->PSSetShaderResources(0,1,&source);context_->Draw(3,0);ID3D11ShaderResourceView* empty_source=nullptr;
    context_->PSSetShaderResources(0,1,&empty_source);context_->OMSetRenderTargets(0,nullptr,nullptr);
    if(full_readback){
        context_->CopyResource(slot.staging.Get(),slot.alpha.Get());context_->End(slot.ready.Get());context_->Flush();
        slot.tag=tag;slot.copying_alpha=true;++count_;return S_OK;
    }
    auto* summary=slot.summary_view.Get();auto* plane=slot.alpha_source.Get();
    context_->CSSetShader(shader_.Get(),nullptr,0);context_->CSSetShaderResources(0,1,&plane);context_->CSSetUnorderedAccessViews(0,1,&summary,nullptr);context_->Dispatch(groups_x_,groups_y_,1);
    ID3D11UnorderedAccessView* empty_output=nullptr;context_->CSSetShaderResources(0,1,&empty_source);context_->CSSetUnorderedAccessViews(0,1,&empty_output,nullptr);context_->CSSetShader(nullptr,nullptr,0);
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

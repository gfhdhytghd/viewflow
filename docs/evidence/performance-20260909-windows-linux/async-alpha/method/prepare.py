from pathlib import Path
import shutil
base=Path('docs/evidence/performance-20260909-windows-linux');b=base/'async-alpha';src=b/'source/platform/windows-reverse';(b/'method').mkdir(parents=True,exist_ok=True);(b/'runs').mkdir(exist_ok=True)
shutil.copytree(base/'source-profile/source',b/'source',dirs_exist_ok=True)
p=src/'alpha_plane.hpp';t=p.read_text().replace('#include <vector>','#include <vector>\n#include <array>');t=t.replace('HRESULT read(ID3D11ShaderResourceView*,std::vector<std::uint8_t>&);','HRESULT enqueue(ID3D11ShaderResourceView*,std::int64_t);\n    HRESULT poll(std::int64_t&,std::vector<std::uint8_t>&);');t=t.replace('Microsoft::WRL::ComPtr<ID3D11Texture2D> alpha_,staging_;','Microsoft::WRL::ComPtr<ID3D11Texture2D> alpha_;\n    struct Slot { Microsoft::WRL::ComPtr<ID3D11Texture2D> staging; Microsoft::WRL::ComPtr<ID3D11Query> ready; std::int64_t tag{}; };\n    std::array<Slot,4> slots_;\n    unsigned head_{},count_{};');p.write_text(t)
p=src/'alpha_plane.cpp';t=p.read_text();t=t.replace('CHECK_HR(device->CreateTexture2D(&desc,nullptr,&staging_));','for(auto& slot:slots_){\n        CHECK_HR(device->CreateTexture2D(&desc,nullptr,&slot.staging));\n        const D3D11_QUERY_DESC query{D3D11_QUERY_EVENT,0};CHECK_HR(device->CreateQuery(&query,&slot.ready));\n    }');t=t.replace('HRESULT AlphaPlane::read(ID3D11ShaderResourceView* source,std::vector<std::uint8_t>& bytes) {','HRESULT AlphaPlane::enqueue(ID3D11ShaderResourceView* source,std::int64_t tag) {');t=t.replace('if(!context_ || !source)return E_INVALIDARG;','if(!context_ || !source)return E_INVALIDARG;\n    if(count_==slots_.size())return S_FALSE;\n    auto& slot=slots_[(head_+count_)%slots_.size()];');t=t.replace('context_->OMSetRenderTargets(0,nullptr,nullptr);context_->CopyResource(staging_.Get(),alpha_.Get());\n    D3D11_MAPPED_SUBRESOURCE mapped{};CHECK_HR(context_->Map(staging_.Get(),0,D3D11_MAP_READ,0,&mapped));','''context_->OMSetRenderTargets(0,nullptr,nullptr);context_->CopyResource(slot.staging.Get(),alpha_.Get());
    context_->End(slot.ready.Get());context_->Flush();slot.tag=tag;++count_;return S_OK;
}
HRESULT AlphaPlane::poll(std::int64_t& tag,std::vector<std::uint8_t>& bytes) {
    if(!context_)return E_UNEXPECTED;
    if(!count_)return S_FALSE;
    auto& slot=slots_[head_];BOOL ready=FALSE;
    const HRESULT query=context_->GetData(slot.ready.Get(),&ready,sizeof(ready),D3D11_ASYNC_GETDATA_DONOTFLUSH);
    CHECK_HR(query);if(query==S_FALSE || !ready)return S_FALSE;
    D3D11_MAPPED_SUBRESOURCE mapped{};
    const HRESULT mapped_result=context_->Map(slot.staging.Get(),0,D3D11_MAP_READ,D3D11_MAP_FLAG_DO_NOT_WAIT,&mapped);
    if(mapped_result==DXGI_ERROR_WAS_STILL_DRAWING)return S_FALSE;
    CHECK_HR(mapped_result);''');t=t.replace('staging_.Get()','slot.staging.Get()');t=t.replace('context_->Unmap(slot.staging.Get(),0);return S_OK;','context_->Unmap(slot.staging.Get(),0);tag=slot.tag;head_=(head_+1)%slots_.size();--count_;return S_OK;');p.write_text(t)
p=src/'main.cpp';t=p.read_text();old='''                        found->second.color=std::move(packet.bytes);found->second.keyframe=packet.keyframe;write_frame(found->second);
                        pending.erase(found);''';assert old in t;t=t.replace(old,'''                        found->second.color=std::move(packet.bytes);found->second.keyframe=packet.keyframe;
                        std::fprintf(stderr,"profile_color_ready pts=%lld at=%lld\\n",packet.timestamp,qpc100ns());''')
needle='''                if(Clock::now()<next_frame || pending.size()>=4)''';assert needle in t
t=t.replace(needle,'''                if(alpha){
                    for(;;){
                        std::int64_t tag{};std::vector<std::uint8_t> raw_alpha;const auto collect_begin=qpc100ns();
                        const auto result=alpha->poll(tag,raw_alpha);check(result);if(result==S_FALSE)break;
                        const auto collect_end=qpc100ns();
                        auto found=pending.find(tag);if(found==pending.end())throw std::runtime_error("alpha metadata missing");
                        if(raw_alpha!=last_raw_alpha){last_encoded_alpha=vf::encode_alpha(raw_alpha);last_raw_alpha=std::move(raw_alpha);}
                        found->second.alpha=last_encoded_alpha;
                        std::fprintf(stderr,"profile_alpha_ready pts=%lld begin=%lld copied=%lld packed=%lld\\n",tag,collect_begin,collect_end,qpc100ns());
                    }
                }
                while(!pending.empty() && !pending.begin()->second.color.empty() && !pending.begin()->second.alpha.empty()){
                    write_frame(pending.begin()->second);pending.erase(pending.begin());
                }
                if(Clock::now()<next_frame || pending.size()>=4)''')
old='''                const auto alpha_begin=qpc100ns();std::vector<std::uint8_t> raw_alpha;check(alpha->read(atlas_view.Get(),raw_alpha));const auto alpha_end=qpc100ns();
                if(raw_alpha!=last_raw_alpha){last_encoded_alpha=vf::encode_alpha(raw_alpha);last_raw_alpha=std::move(raw_alpha);}
                frame.alpha=last_encoded_alpha;''';assert old in t;t=t.replace(old,'''                const auto alpha_begin=qpc100ns();const auto queued=alpha->enqueue(atlas_view.Get(),pts);check(queued);
                if(queued!=S_OK)throw std::runtime_error("alpha queue ownership mismatch");const auto alpha_end=qpc100ns();''');p.write_text(t)
for name in ['stage-build.py','build.cmd','run-source.py','analyze.py']:
 t=(base/'source-profile/method'/name).read_text().replace('reverse-profile-20260909','reverse-async-alpha-20260909').replace('Reverse6KSource-20260909','Reverse6KAsyncAlpha-20260909').replace("'stream.vfrv','build-attempt1.log'","'stream.vfrv'")
 (b/'method'/name).write_text(t)
shutil.copy2('/tmp/viewflow-prepare-async-alpha.py',b/'method/prepare.py')

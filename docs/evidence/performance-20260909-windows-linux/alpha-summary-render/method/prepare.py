from pathlib import Path
import shutil
base=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');a=base/'alpha-summary-fixed';b=base/'alpha-summary-render';assert not b.exists();shutil.copytree(a/'source',b/'source');(b/'method').mkdir();(b/'runs').mkdir()
p=b/'source/platform/windows-reverse/compact_alpha_plane.hpp';s=p.read_text().replace('Microsoft::WRL::ComPtr<ID3D11ComputeShader> shader_;','Microsoft::WRL::ComPtr<ID3D11ComputeShader> shader_;\n    Microsoft::WRL::ComPtr<ID3D11VertexShader> vertex_;\n    Microsoft::WRL::ComPtr<ID3D11PixelShader> pixel_;').replace('Microsoft::WRL::ComPtr<ID3D11UnorderedAccessView> alpha_view,summary_view;','Microsoft::WRL::ComPtr<ID3D11UnorderedAccessView> summary_view;\n        Microsoft::WRL::ComPtr<ID3D11RenderTargetView> alpha_target;\n        Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> alpha_source;');p.write_text(s)
p=b/'source/platform/windows-reverse/compact_alpha_plane.cpp';s=p.read_text();s=s.replace('device->CheckFormatSupport(DXGI_FORMAT_R8_UINT,&support)','device->CheckFormatSupport(DXGI_FORMAT_R8_UNORM,&support)').replace('if(!(support&D3D11_FORMAT_SUPPORT_TYPED_UNORDERED_ACCESS_VIEW))return E_NOTIMPL;','if(!(support&D3D11_FORMAT_SUPPORT_RENDER_TARGET) || !(support&D3D11_FORMAT_SUPPORT_SHADER_LOAD))return E_NOTIMPL;')
s=s.replace('d.Format=DXGI_FORMAT_R8_UINT;d.BindFlags=D3D11_BIND_UNORDERED_ACCESS;','d.Format=DXGI_FORMAT_R8_UNORM;d.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;').replace('CHECK_HR(device->CreateUnorderedAccessView(slot.alpha.Get(),nullptr,&slot.alpha_view));','CHECK_HR(device->CreateRenderTargetView(slot.alpha.Get(),nullptr,&slot.alpha_target));CHECK_HR(device->CreateShaderResourceView(slot.alpha.Get(),nullptr,&slot.alpha_source));')
s=s.replace('Texture2D<float4> color:register(t0);\nRWTexture2D<uint> alpha:register(u0);\nRWTexture2D<uint> summary:register(u1);','Texture2D<float> color:register(t0);\nRWTexture2D<uint> summary:register(u0);').replace('alpha.GetDimensions(width,height)','color.GetDimensions(width,height)').replace('color.Load(int3(p,0)).a','color.Load(int3(p,0))').replace('alpha[p]=value;opaque&=uint(value==255);','opaque&=uint(value==255);')
needle='CHECK_HR(device->CreateComputeShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&shader_));return S_OK;';assert needle in s;s=s.replace(needle,'''CHECK_HR(device->CreateComputeShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&shader_));
    const char* extract=R"(
Texture2D<float4> color:register(t0);
float4 vs(uint id:SV_VertexID):SV_Position{float2 p=float2((id<<1)&2,id&2);return float4(p*float2(2,-2)+float2(-1,1),0,1);}
float ps(float4 pos:SV_Position):SV_Target{return color.Load(int3(pos.xy,0)).a;}
)";
    code.Reset();error.Reset();CHECK_HR(D3DCompile(extract,std::strlen(extract),nullptr,nullptr,nullptr,"vs","vs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&error));CHECK_HR(device->CreateVertexShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&vertex_));
    code.Reset();error.Reset();CHECK_HR(D3DCompile(extract,std::strlen(extract),nullptr,nullptr,nullptr,"ps","ps_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&error));CHECK_HR(device->CreatePixelShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&pixel_));return S_OK;''')
start=s.index('    ID3D11UnorderedAccessView* outputs[]');end=s.index('    context_->CopyResource(slot.summary_staging',start)
s=s[:start]+'''    // Preserve the original fast R8 render-target extraction. Summarize that
    // compact plane, rather than scattering R8_UINT UAV stores from the RGBA
    // compute pass. Keep a slot-owned plane for deferred nonopaque readback.
    D3D11_VIEWPORT viewport{0,0,static_cast<float>(width_),static_cast<float>(height_),0,1};auto* target=slot.alpha_target.Get();
    context_->OMSetRenderTargets(1,&target,nullptr);context_->RSSetViewports(1,&viewport);context_->RSSetState(nullptr);
    context_->OMSetBlendState(nullptr,nullptr,0xffffffff);context_->OMSetDepthStencilState(nullptr,0);
    context_->IASetInputLayout(nullptr);context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);context_->VSSetShader(vertex_.Get(),nullptr,0);context_->PSSetShader(pixel_.Get(),nullptr,0);
    context_->PSSetShaderResources(0,1,&source);context_->Draw(3,0);ID3D11ShaderResourceView* empty_source=nullptr;
    context_->PSSetShaderResources(0,1,&empty_source);context_->OMSetRenderTargets(0,nullptr,nullptr);
    auto* summary=slot.summary_view.Get();auto* plane=slot.alpha_source.Get();
    context_->CSSetShader(shader_.Get(),nullptr,0);context_->CSSetShaderResources(0,1,&plane);context_->CSSetUnorderedAccessViews(0,1,&summary,nullptr);context_->Dispatch(groups_x_,groups_y_,1);
    ID3D11UnorderedAccessView* empty_output=nullptr;context_->CSSetShaderResources(0,1,&empty_source);context_->CSSetUnorderedAccessViews(0,1,&empty_output,nullptr);context_->CSSetShader(nullptr,nullptr,0);
'''+s[end:];p.write_text(s)
for name in ['stage-build.py','build.cmd','run-source.py','analyze.py']:
 s=(a/'method'/name).read_text().replace('reverse-alpha-summary-fixed-20260909','reverse-alpha-summary-render-20260909').replace('Reverse6KAlphaSummaryFixed-20260909','Reverse6KAlphaSummaryRender-20260909');(b/'method'/name).write_text(s)
shutil.copy2(__file__,b/'method/prepare.py')

#pragma once
#include <d3d11.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <optional>
#include <cstring>
#include <stdexcept>
#include <string>

namespace viewflow::reverse {
class ShellCrop {
    template<class T> using Ptr=Microsoft::WRL::ComPtr<T>;
    Ptr<ID3D11ComputeShader> shader;
    Ptr<ID3D11DeviceContext> deferred;
    Ptr<ID3D11Buffer> output,readback;
    Ptr<ID3D11UnorderedAccessView> uav;
    Ptr<ID3D11Texture2D> texture;
    Ptr<ID3D11ShaderResourceView> srv;
    unsigned width{},height{};
    static void check(HRESULT hr){if(FAILED(hr))throw std::runtime_error("shell alpha bounds HRESULT="+std::to_string(hr));}
public:
    std::optional<RECT> measure(ID3D11Device* device,ID3D11DeviceContext* context,ID3D11Texture2D* frame) {
        if(!shader) {
            const char* code=R"(
Texture2D<float4> image:register(t0);RWBuffer<uint> result:register(u0);
groupshared uint x0,y0,x1,y1;
[numthreads(16,16,1)] void main(uint3 p:SV_DispatchThreadID,uint index:SV_GroupIndex) {
 uint w,h;image.GetDimensions(w,h);
 if(index==0){x0=w;y0=h;x1=0;y1=0;}GroupMemoryBarrierWithGroupSync();
 if(p.x<w && p.y<h && image.Load(int3(p.xy,0)).a>0.01){InterlockedMin(x0,p.x);InterlockedMin(y0,p.y);InterlockedMax(x1,p.x+1);InterlockedMax(y1,p.y+1);}
 GroupMemoryBarrierWithGroupSync();
 if(index==0 && x1>x0 && y1>y0){InterlockedMin(result[0],x0);InterlockedMin(result[1],y0);InterlockedMax(result[2],x1);InterlockedMax(result[3],y1);}
})";
            Ptr<ID3DBlob> compiled,error;
            check(D3DCompile(code,std::strlen(code),nullptr,nullptr,nullptr,"main","cs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&compiled,&error));
            check(device->CreateComputeShader(compiled->GetBufferPointer(),compiled->GetBufferSize(),nullptr,&shader));
            check(device->CreateDeferredContext(0,&deferred));
            D3D11_BUFFER_DESC desc{};desc.ByteWidth=16;desc.BindFlags=D3D11_BIND_UNORDERED_ACCESS;
            check(device->CreateBuffer(&desc,nullptr,&output));
            D3D11_UNORDERED_ACCESS_VIEW_DESC view{};view.Format=DXGI_FORMAT_R32_UINT;view.ViewDimension=D3D11_UAV_DIMENSION_BUFFER;view.Buffer.NumElements=4;
            check(device->CreateUnorderedAccessView(output.Get(),&view,&uav));
            desc.BindFlags=0;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
            check(device->CreateBuffer(&desc,nullptr,&readback));
        }
        D3D11_TEXTURE2D_DESC desc{};frame->GetDesc(&desc);
        if(!texture || width!=desc.Width || height!=desc.Height) {
            width=desc.Width;height=desc.Height;texture.Reset();srv.Reset();
            desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;desc.MiscFlags=0;desc.Usage=D3D11_USAGE_DEFAULT;desc.CPUAccessFlags=0;
            check(device->CreateTexture2D(&desc,nullptr,&texture));
            check(device->CreateShaderResourceView(texture.Get(),nullptr,&srv));
        }
        unsigned initial[4]={width,height,0,0};
        deferred->CopyResource(texture.Get(),frame);
        deferred->UpdateSubresource(output.Get(),0,nullptr,initial,0,0);
        auto* input=srv.Get();auto* result=uav.Get();
        deferred->CSSetShader(shader.Get(),nullptr,0);deferred->CSSetShaderResources(0,1,&input);deferred->CSSetUnorderedAccessViews(0,1,&result,nullptr);
        deferred->Dispatch((width+15)/16,(height+15)/16,1);
        deferred->CopyResource(readback.Get(),output.Get());
        Ptr<ID3D11CommandList> commands;check(deferred->FinishCommandList(FALSE,&commands));
        context->ExecuteCommandList(commands.Get(),TRUE);
        D3D11_MAPPED_SUBRESOURCE mapped{};check(context->Map(readback.Get(),0,D3D11_MAP_READ,0,&mapped));
        auto* values=static_cast<unsigned*>(mapped.pData);RECT rect{LONG(values[0]),LONG(values[1]),LONG(values[2]),LONG(values[3])};context->Unmap(readback.Get(),0);
        if(rect.right<=rect.left || rect.bottom<=rect.top)return std::nullopt;
        return rect;
    }
};
}

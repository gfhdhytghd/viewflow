#pragma once
#include <d3d11.h>
#include <wrl/client.h>
namespace viewflow::reverse {
class WindowDecorationGpu {
public:
    HRESULT start(ID3D11Device*);
    HRESULT draw(ID3D11DeviceContext*, ID3D11ShaderResourceView*, ID3D11RenderTargetView*, unsigned, unsigned, unsigned);
private:
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> deferred_;
    Microsoft::WRL::ComPtr<ID3D11VertexShader> vertex_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> pixel_;
    Microsoft::WRL::ComPtr<ID3D11Buffer> constants_;
    Microsoft::WRL::ComPtr<ID3D11SamplerState> sampler_;
};
}

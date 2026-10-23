#pragma once
#include <d3d11.h>
#include <wrl/client.h>
#include <vector>
#include <cstdint>
namespace viewflow::reverse {
class AlphaPlane {
public:
    HRESULT start(ID3D11Device*,unsigned,unsigned);
    HRESULT read(ID3D11ShaderResourceView*,std::vector<std::uint8_t>&);
private:
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> alpha_,staging_;
    Microsoft::WRL::ComPtr<ID3D11RenderTargetView> target_;
    Microsoft::WRL::ComPtr<ID3D11VertexShader> vertex_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> pixel_;
    unsigned width_{},height_{};
};
}

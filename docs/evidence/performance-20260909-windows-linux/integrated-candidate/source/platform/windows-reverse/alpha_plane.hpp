#pragma once
#include <d3d11.h>
#include <wrl/client.h>
#include <vector>
#include <array>
#include <cstdint>
#include <memory>
#include "compact_alpha_plane.hpp"
namespace viewflow::reverse {
class AlphaPlane {
public:
    HRESULT start(ID3D11Device*,unsigned,unsigned);
    HRESULT enqueue(ID3D11ShaderResourceView*,std::int64_t);
    HRESULT poll(std::int64_t&,std::vector<std::uint8_t>&,bool* opaque_hint=nullptr);
private:
    std::unique_ptr<CompactAlphaPlane> compact_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> alpha_;
    struct Slot { Microsoft::WRL::ComPtr<ID3D11Texture2D> staging; Microsoft::WRL::ComPtr<ID3D11Query> ready; std::int64_t tag{}; };
    std::array<Slot,4> slots_;
    unsigned head_{},count_{};
    Microsoft::WRL::ComPtr<ID3D11RenderTargetView> target_;
    Microsoft::WRL::ComPtr<ID3D11VertexShader> vertex_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> pixel_;
    unsigned width_{},height_{};
};
}

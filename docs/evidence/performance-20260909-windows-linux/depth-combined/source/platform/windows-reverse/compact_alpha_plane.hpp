#pragma once
#include <d3d11.h>
#include <wrl/client.h>
#include <array>
#include <vector>
#include <cstdint>
namespace viewflow::reverse {
class CompactAlphaPlane {
public:
    HRESULT start(ID3D11Device*,unsigned,unsigned);
    HRESULT enqueue(ID3D11ShaderResourceView*,std::int64_t);
    HRESULT poll(std::int64_t&,std::vector<std::uint8_t>&,bool*);
private:
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    Microsoft::WRL::ComPtr<ID3D11ComputeShader> shader_;
    Microsoft::WRL::ComPtr<ID3D11VertexShader> vertex_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> pixel_;
    struct Slot {
        Microsoft::WRL::ComPtr<ID3D11Texture2D> alpha,staging,summary,summary_staging;
        Microsoft::WRL::ComPtr<ID3D11UnorderedAccessView> summary_view;
        Microsoft::WRL::ComPtr<ID3D11RenderTargetView> alpha_target;
        Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> alpha_source;
        Microsoft::WRL::ComPtr<ID3D11Query> ready;
        std::int64_t tag{};bool copying_alpha{};
    };
    std::array<Slot,4> slots_;
    unsigned width_{},height_{},groups_x_{},groups_y_{},head_{},count_{};
};
}

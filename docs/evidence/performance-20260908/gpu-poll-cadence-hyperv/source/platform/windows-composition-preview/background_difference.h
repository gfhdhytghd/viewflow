#pragma once
#include <array>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <optional>
#include <string>
#include <winrt/base.h>

// Experimental background-worker helper. It compares every pixel against the
// last processed source; it never reads a full image back to the CPU. A
// one-code tolerance can absorb the HostBackdrop refresh offset's measured SDR
// jitter. The reference changes only after actual processing, so small changes
// cannot accumulate indefinitely without being detected.
class BackgroundDifference {
  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::com_ptr<ID3D11ComputeShader> shader_;
  winrt::com_ptr<ID3D11Texture2D> reference_;
  winrt::com_ptr<ID3D11ShaderResourceView> reference_view_;
  winrt::com_ptr<ID3D11Buffer> changed_, readback_, constants_;
  winrt::com_ptr<ID3D11UnorderedAccessView> changed_view_;
  UINT width_{}, height_{};
  bool has_reference_{};

  void Validate(ID3D11Texture2D *texture) const {
    if (!texture) winrt::throw_hresult(E_INVALIDARG);
    D3D11_TEXTURE2D_DESC d{};
    texture->GetDesc(&d);
    if (d.Width < width_ || d.Height < height_ ||
        d.Format != DXGI_FORMAT_B8G8R8A8_UNORM || d.SampleDesc.Count != 1 ||
        d.ArraySize != 1 || d.MipLevels != 1)
      winrt::throw_hresult(E_INVALIDARG);
  }

public:
  void Initialize(ID3D11Device *device, UINT width, UINT height,
                  UINT tolerance = 0) {
    using winrt::check_hresult;
    if (device_ || !device || !width || !height || tolerance > 1)
      winrt::throw_hresult(E_INVALIDARG);
    device_.copy_from(device);
    device->GetImmediateContext(context_.put());
    width_ = width;
    height_ = height;
    static constexpr char source[] = R"hlsl(
Texture2D<float4> Current : register(t0);
Texture2D<float4> Previous : register(t1);
RWByteAddressBuffer Changed : register(u0);
cbuffer Dimensions : register(b0) { uint Width; uint Height; uint Tolerance; uint Padding; }
groupshared uint GroupChanged;
groupshared uint SkipGroup;
[numthreads(16,16,1)]
void main(uint3 pixel : SV_DispatchThreadID, uint lane : SV_GroupIndex) {
  if (lane==0) { SkipGroup=Changed.Load(0); GroupChanged=0; }
  GroupMemoryBarrierWithGroupSync();
  if (SkipGroup!=0) return;
  if (pixel.x<Width && pixel.y<Height) {
    int4 a=int4(round(Current.Load(int3(pixel.xy,0))*255.0));
    int4 b=int4(round(Previous.Load(int3(pixel.xy,0))*255.0));
    if (any(abs(a.rgb-b.rgb)>int(Tolerance)) || a.a!=b.a) InterlockedOr(GroupChanged,1);
  }
  GroupMemoryBarrierWithGroupSync();
  if (lane==0 && GroupChanged!=0) { uint ignored; Changed.InterlockedOr(0,1,ignored); }
}
)hlsl";
    winrt::com_ptr<ID3DBlob> code, error;
    const auto hr = D3DCompile(
        source, sizeof(source) - 1, "background_difference.h", nullptr, nullptr,
        "main", "cs_5_0",
        D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3, 0,
        code.put(), error.put());
    if (FAILED(hr) && error)
      throw winrt::hresult_error(
          hr, winrt::to_hstring(std::string(
                  static_cast<const char *>(error->GetBufferPointer()),
                  error->GetBufferSize())));
    check_hresult(hr);
    check_hresult(device->CreateComputeShader(code->GetBufferPointer(),
                                              code->GetBufferSize(), nullptr,
                                              shader_.put()));
    D3D11_TEXTURE2D_DESC td{};
    td.Width = width;
    td.Height = height;
    td.MipLevels = td.ArraySize = td.SampleDesc.Count = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    check_hresult(device->CreateTexture2D(&td, nullptr, reference_.put()));
    check_hresult(device->CreateShaderResourceView(reference_.get(), nullptr,
                                                   reference_view_.put()));
    D3D11_BUFFER_DESC bd{};
    bd.ByteWidth = 4;
    bd.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
    bd.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_ALLOW_RAW_VIEWS;
    check_hresult(device->CreateBuffer(&bd, nullptr, changed_.put()));
    D3D11_UNORDERED_ACCESS_VIEW_DESC uv{};
    uv.Format = DXGI_FORMAT_R32_TYPELESS;
    uv.ViewDimension = D3D11_UAV_DIMENSION_BUFFER;
    uv.Buffer.NumElements = 1;
    uv.Buffer.Flags = D3D11_BUFFER_UAV_FLAG_RAW;
    check_hresult(device->CreateUnorderedAccessView(changed_.get(), &uv,
                                                    changed_view_.put()));
    bd.BindFlags = bd.MiscFlags = 0;
    bd.Usage = D3D11_USAGE_STAGING;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    check_hresult(device->CreateBuffer(&bd, nullptr, readback_.put()));
    const std::array<UINT, 4> values{width, height, tolerance, 0};
    bd = {};
    bd.ByteWidth = 16;
    bd.Usage = D3D11_USAGE_IMMUTABLE;
    bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    D3D11_SUBRESOURCE_DATA data{values.data(), 0, 0};
    check_hresult(device->CreateBuffer(&bd, &data, constants_.put()));
  }
  bool HasReference() const { return has_reference_; }
  void Begin(ID3D11Texture2D *current) {
    if (!has_reference_)
      winrt::throw_hresult(E_UNEXPECTED);
    Validate(current);
    winrt::com_ptr<ID3D11ShaderResourceView> current_view;
    winrt::check_hresult(device_->CreateShaderResourceView(current, nullptr,
                                                           current_view.put()));
    constexpr UINT zero[4]{};
    context_->ClearUnorderedAccessViewUint(changed_view_.get(), zero);
    ID3D11ShaderResourceView *views[]{current_view.get(),
                                      reference_view_.get()};
    auto cb = constants_.get();
    auto uav = changed_view_.get();
    context_->CSSetShader(shader_.get(), nullptr, 0);
    context_->CSSetShaderResources(0, 2, views);
    context_->CSSetConstantBuffers(0, 1, &cb);
    context_->CSSetUnorderedAccessViews(0, 1, &uav, nullptr);
    context_->Dispatch((width_ + 15) / 16, (height_ + 15) / 16, 1);
    ID3D11ShaderResourceView *no_views[2]{};
    ID3D11UnorderedAccessView *no_uav{};
    context_->CSSetShaderResources(0, 2, no_views);
    context_->CSSetUnorderedAccessViews(0, 1, &no_uav, nullptr);
    context_->CSSetShader(nullptr, nullptr, 0);
    context_->CopyResource(readback_.get(), changed_.get());
  }
  std::optional<bool> TryResult() {
    D3D11_MAPPED_SUBRESOURCE mapped{};
    const auto hr = context_->Map(readback_.get(), 0, D3D11_MAP_READ,
                                  D3D11_MAP_FLAG_DO_NOT_WAIT, &mapped);
    if (hr == DXGI_ERROR_WAS_STILL_DRAWING)
      return {};
    winrt::check_hresult(hr);
    const bool changed = *static_cast<const UINT *>(mapped.pData) != 0;
    context_->Unmap(readback_.get(), 0);
    return changed;
  }
  void Remember(ID3D11Texture2D *current) {
    Validate(current);
    const D3D11_BOX box{0, 0, 0, width_, height_, 1};
    context_->CopySubresourceRegion(reference_.get(), 0, 0, 0, 0, current, 0,
                                    &box);
    has_reference_ = true;
  }
};

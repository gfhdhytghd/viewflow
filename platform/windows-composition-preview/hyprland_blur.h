#pragma once
#include "hyprland_blur_shader.h"
// SDR BGRA port of Hyprland's blur kernels and color adjustments. Compact level
// textures clamp their boundaries; Hyprland's damage scratch buffers can sample
// outside a valid lower-resolution region. No HDR color management is claimed.
class HyprlandBlur {
  struct Level {
    UINT w{}, h{};
    winrt::com_ptr<ID3D11Texture2D> texture;
    winrt::com_ptr<ID3D11ShaderResourceView> srv;
    winrt::com_ptr<ID3D11RenderTargetView> rtv;
  };
  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::com_ptr<ID3D11VertexShader> vs_;
  std::array<winrt::com_ptr<ID3D11PixelShader>, 4> ps_;
  winrt::com_ptr<ID3D11SamplerState> sampler_;
  winrt::com_ptr<ID3D11Buffer> cb_;
  winrt::com_ptr<ID3D11RasterizerState> raster_;
  Level prepared_, upsampled_;
  std::vector<Level> levels_;

public:
  struct Settings {
    float radius = 5, contrast = .8916f, brightness = 1, noise = .0117f,
          vibrancy = .1696f, vibrancy_darkness = 0;
    UINT passes = 4;
    std::array<float, 2> noise_origin{0, 0}, noise_scale{1, 1};
  };
  Settings settings;
  void Initialize(ID3D11Device *device, UINT w, UINT h) {
    using winrt::check_hresult;
    device_.copy_from(device);
    device->GetImmediateContext(context_.put());
    auto compile = [&](const char *entry, const char *profile) {
      winrt::com_ptr<ID3DBlob> code, error;
      auto hr = D3DCompile(
          kHyprlandBlurShader, sizeof(kHyprlandBlurShader) - 1,
          "hyprland_blur_shader.h", nullptr, nullptr, entry, profile,
          D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3, 0,
          code.put(), error.put());
      if (FAILED(hr) && error) {
        FILE *f{};
        fopen_s(&f, "hyprland-shader-compile-error.log", "wb");
        if (f) {
          fwrite(error->GetBufferPointer(), 1, error->GetBufferSize(), f);
          fclose(f);
        }
      }
      if (FAILED(hr) && error)
        throw winrt::hresult_error(
            hr, winrt::to_hstring(
                    std::string(static_cast<char *>(error->GetBufferPointer()),
                                error->GetBufferSize())));
      check_hresult(hr);
      return code;
    };
    auto vertex = compile("vs", "vs_5_0");
    check_hresult(device->CreateVertexShader(vertex->GetBufferPointer(),
                                             vertex->GetBufferSize(), nullptr,
                                             vs_.put()));
    const char *names[] = {"prepare", "down", "up", "finish"};
    for (int i = 0; i < 4; ++i) {
      auto code = compile(names[i], "ps_5_0");
      check_hresult(device->CreatePixelShader(code->GetBufferPointer(),
                                              code->GetBufferSize(), nullptr,
                                              ps_[i].put()));
    }
    D3D11_SAMPLER_DESC sampler{};
    sampler.Filter = D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;
    sampler.AddressU = sampler.AddressV = sampler.AddressW =
        D3D11_TEXTURE_ADDRESS_CLAMP;
    sampler.MaxLOD = D3D11_FLOAT32_MAX;
    check_hresult(device->CreateSamplerState(&sampler, sampler_.put()));
    D3D11_BUFFER_DESC cb{};
    cb.ByteWidth = 64;
    cb.Usage = D3D11_USAGE_DYNAMIC;
    cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    cb.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    check_hresult(device->CreateBuffer(&cb, nullptr, cb_.put()));
    D3D11_RASTERIZER_DESC rs{};
    rs.FillMode = D3D11_FILL_SOLID;
    rs.CullMode = D3D11_CULL_NONE;
    rs.DepthClipEnable = TRUE;
    check_hresult(device->CreateRasterizerState(&rs, raster_.put()));
    auto make = [&](UINT w, UINT h) {
      Level l;
      l.w = w;
      l.h = h;
      D3D11_TEXTURE2D_DESC d{};
      d.Width = w;
      d.Height = h;
      d.MipLevels = d.ArraySize = d.SampleDesc.Count = 1;
      d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
      check_hresult(device->CreateTexture2D(&d, nullptr, l.texture.put()));
      check_hresult(device->CreateRenderTargetView(l.texture.get(), nullptr,
                                                   l.rtv.put()));
      check_hresult(device->CreateShaderResourceView(l.texture.get(), nullptr,
                                                     l.srv.put()));
      return l;
    };
    prepared_ = make(w, h);
    upsampled_ = make(w, h);
    for (UINT i = 0; i < settings.passes; ++i) {
      w = std::max(1u, (w + 1) / 2);
      h = std::max(1u, (h + 1) / 2);
      levels_.push_back(make(w, h));
    }
  }
  void Draw(ID3D11ShaderResourceView *input, ID3D11RenderTargetView *output,
            POINT offset) {
    if (!input || !output || levels_.size() != settings.passes)
      throw winrt::hresult_error(E_INVALIDARG);
    context_->IASetInputLayout(nullptr);
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->VSSetShader(vs_.get(), nullptr, 0);
    context_->GSSetShader(nullptr, nullptr, 0);
    context_->RSSetState(raster_.get());
    context_->OMSetBlendState(nullptr, nullptr, 0xffffffff);
    context_->OMSetDepthStencilState(nullptr, 0);
    auto sampler = sampler_.get();
    context_->PSSetSamplers(0, 1, &sampler);
    auto cb = cb_.get();
    context_->PSSetConstantBuffers(0, 1, &cb);
    auto pass = [&](ID3D11ShaderResourceView *src, UINT sw, UINT sh,
                    ID3D11RenderTargetView *dst, UINT dw, UINT dh, int which,
                    POINT offset = POINT{}) {
      ID3D11ShaderResourceView *clear{};
      context_->PSSetShaderResources(0, 1, &clear);
      context_->OMSetRenderTargets(1, &dst, nullptr);
      D3D11_VIEWPORT vp{
          float(offset.x), float(offset.y), float(dw), float(dh), 0, 1};
      context_->RSSetViewports(1, &vp);
      D3D11_MAPPED_SUBRESOURCE map{};
      winrt::check_hresult(
          context_->Map(cb_.get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &map));
      const float params[] = {1.0f / sw,
                              1.0f / sh,
                              settings.radius,
                              float(settings.passes),
                              settings.contrast,
                              settings.brightness,
                              settings.noise,
                              settings.vibrancy,
                              settings.vibrancy_darkness,
                              0,
                              settings.noise_origin[0],
                              settings.noise_origin[1],
                              settings.noise_scale[0],
                              settings.noise_scale[1],
                              0,
                              0};
      std::memcpy(map.pData, params, sizeof(params));
      context_->Unmap(cb_.get(), 0);
      context_->PSSetShader(ps_[which].get(), nullptr, 0);
      context_->PSSetShaderResources(0, 1, &src);
      context_->Draw(3, 0);
    };
    pass(input, prepared_.w, prepared_.h, prepared_.rtv.get(), prepared_.w,
         prepared_.h, 0);
    for (UINT i = 0; i < levels_.size(); ++i) {
      auto &src = i ? levels_[i - 1] : prepared_;
      auto &dst = levels_[i];
      pass(src.srv.get(), src.w, src.h, dst.rtv.get(), dst.w, dst.h, 1);
    }
    for (UINT i = UINT(levels_.size()); i > 0; --i) {
      auto &src = levels_[i - 1];
      auto &dst = i > 1 ? levels_[i - 2] : upsampled_;
      pass(src.srv.get(), src.w, src.h, dst.rtv.get(), dst.w, dst.h, 2);
    }
    pass(upsampled_.srv.get(), upsampled_.w, upsampled_.h, output, upsampled_.w,
         upsampled_.h, 3, offset);
    ID3D11ShaderResourceView *clear{};
    context_->PSSetShaderResources(0, 1, &clear);
    context_->OMSetRenderTargets(0, nullptr, nullptr);
  }
};

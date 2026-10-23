#pragma once
#include <d3d11.h>
#include <wrl/client.h>
#include <array>
#include <cstdint>
#include <cstddef>
#include <memory>
#include <new>

namespace viewflow::windows {
// Only for frame-owning callers: every published frame/region must retain the
// shared owner. Raw COM aliases alone are not a pool lease. GPU readers must be
// queued on the same serialized immediate context before releasing that owner.
struct OutputSurface {
  UINT width{}, height{};
  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
  Microsoft::WRL::ComPtr<ID3D11RenderTargetView> view;
};
class OutputSurfacePool {
 public:
  struct Counters { uint64_t acquisitions{}, created{}, reused{}, fallback{}; size_t slots{}; };
  HRESULT Acquire(ID3D11Device* device, UINT width, UINT height,
                  std::shared_ptr<OutputSurface>* output, bool* reused) {
    if (!device || !width || !height || !output || !reused) return E_INVALIDARG;
    *reused = false;
    ++counts_.acquisitions;
    size_t available = capacity;
    for (size_t i=0;i<capacity;++i) {
      auto& entry=slots_[i];
      if (!entry) { if(available==capacity) available=i; continue; }
      if (entry.use_count()!=1) continue;
      if (available==capacity) available=i;
      Microsoft::WRL::ComPtr<ID3D11Device> owner;
      entry->texture->GetDevice(&owner);
      if (owner.Get()==device && entry->width==width && entry->height==height) {
        *output=entry;*reused=true;++counts_.reused;return S_OK;
      }
    }
    std::shared_ptr<OutputSurface> next;
    try { next=std::make_shared<OutputSurface>(); }
    catch(const std::bad_alloc&) { return E_OUTOFMEMORY; }
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width=width;desc.Height=height;desc.MipLevels=1;desc.ArraySize=1;
    desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;
    desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
    HRESULT hr=device->CreateTexture2D(&desc,nullptr,&next->texture);
    if(SUCCEEDED(hr))hr=device->CreateRenderTargetView(next->texture.Get(),nullptr,&next->view);
    if(FAILED(hr))return hr;
    next->width=width;next->height=height;++counts_.created;
    if(available<capacity)slots_[available]=next;
    else ++counts_.fallback; // Full pool: ordinary allocation, never wait/drop.
    *output=std::move(next);return S_OK;
  }
  Counters counters() const {
    auto result=counts_;
    for(const auto& entry:slots_)if(entry)++result.slots;
    return result;
  }
  static constexpr size_t capacity=4;
 private:
  std::array<std::shared_ptr<OutputSurface>,capacity> slots_{};
  Counters counts_{};
};
}

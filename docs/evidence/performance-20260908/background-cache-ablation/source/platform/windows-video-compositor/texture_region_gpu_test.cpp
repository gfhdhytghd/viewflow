#include "video_compositor.h"
#include <array>
#include <iostream>

using namespace viewflow::windows;
using Microsoft::WRL::ComPtr;

int main() {
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  D3D_FEATURE_LEVEL level{};
  if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
      nullptr, 0, D3D11_SDK_VERSION, &device, &level, &context))) return 2;
  std::array<uint8_t, 8 * 8 * 4> pixels{};
  for (size_t i = 0; i < 64; ++i) {
    const auto alpha = uint8_t(i + 1);
    pixels[i * 4] = alpha / 4; pixels[i * 4 + 1] = alpha / 2;
    pixels[i * 4 + 2] = alpha / 3; pixels[i * 4 + 3] = alpha;
  }
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = 8; desc.Height = 8; desc.MipLevels = 1; desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM; desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT; desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  D3D11_SUBRESOURCE_DATA initial{pixels.data(), 8 * 4, 0};
  ComPtr<ID3D11Texture2D> source;
  if (FAILED(device->CreateTexture2D(&desc, &initial, &source))) return 3;
  CompositedFrame atlas{7, 8, 8, source, std::nullopt}, tile;
  if (FAILED(MakeCompositedRegion(atlas, {3, 1, 3, 5}, &tile)) ||
      tile.premultiplied_bgra.Get() != source.Get() || tile.width != 3 || tile.height != 5 ||
      tile.frame_identity != 7) return 4;
  CompositedFrame unchanged = tile;
  if (SUCCEEDED(MakeCompositedRegion(atlas, {7, 1, 3, 5}, &unchanged)) ||
      unchanged.width != tile.width || unchanged.source_region->x != 3 ||
      SUCCEEDED(MakeCompositedRegion(tile, {0, 0, 1, 1}, &unchanged))) return 5;
  // CPU readback is test-only evidence. Production copies into composition
  // drawing surfaces using the exact same CopyCompositedRegion implementation.
  desc.Width = 5; desc.Height = 7; desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  std::array<uint8_t, 5 * 7 * 4> zero{};
  initial = {zero.data(), 5 * 4, 0};
  ComPtr<ID3D11Texture2D> target;
  if (FAILED(device->CreateTexture2D(&desc, &initial, &target))) return 6;
  if (SUCCEEDED(CopyCompositedRegion(context.Get(), tile, target.Get(), 3, 0)) ||
      FAILED(CopyCompositedRegion(context.Get(), tile, target.Get(), 1, 1))) return 7;
  D3D11_MAPPED_SUBRESOURCE mapped{};
  if (FAILED(context->Map(target.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return 8;
  bool exact = true;
  for (size_t y = 0; y < 7; ++y) for (size_t x = 0; x < 5; ++x) {
    const auto* actual = static_cast<const uint8_t*>(mapped.pData) + y * mapped.RowPitch + x * 4;
    for (size_t channel = 0; channel < 4; ++channel) {
      const auto expected = x >= 1 && x < 4 && y >= 1 && y < 6
          ? pixels[((y - 1 + 1) * 8 + (x - 1 + 3)) * 4 + channel] : 0;
      exact = exact && actual[channel] == expected;
    }
  }
  context->Unmap(target.Get(), 0);
  std::cout << "gpu_atlas_region_exact=" << (exact ? "true" : "false") << '\n';
  return exact ? 0 : 9;
}

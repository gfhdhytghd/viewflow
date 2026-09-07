#pragma once
#include <d3d11.h>
#include <wrl/client.h>
#include <cstdint>
#include <memory>
#include <span>
#include <vector>
struct AVCodecContext;
struct AVBufferRef;
struct AVFrame;
namespace viewflow::windows {
struct FfmpegDecodedFrame {
  std::shared_ptr<AVFrame> allocation;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
  uint32_t subresource{}, width{}, height{}, crop_x{}, crop_y{};
  int64_t timestamp{};
};
// Uses the compositor's D3D11 device; no color readback or software fallback.
class FfmpegDecoder final {
 public:
  ~FfmpegDecoder();
  HRESULT Initialize(ID3D11Device* device, uint32_t codec);
  HRESULT Submit(std::span<const uint8_t> bytes, int64_t timestamp,
                 std::vector<FfmpegDecodedFrame>* frames);
 private:
  AVCodecContext* decoder_{};
  AVBufferRef* device_{};
};
}

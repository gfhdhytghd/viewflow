#pragma once

#include <d3d11.h>
#ifdef VIEWFLOW_HAVE_FFMPEG
#include "ffmpeg_decoder.h"
#endif
#include <mfidl.h>
#include <wrl/client.h>

#include <cstdint>
#include <memory>
#include <span>
#include <vector>
#include <optional>
#include "texture_region.h"
#include "gpu_timestamp_probe.h"

// This class is deliberately bound to one D3D11 immediate context.  Call every
// method from that context's owning thread (or serialize externally).
namespace viewflow::windows {

struct RawGray8Alpha {
  uint64_t frame_identity{};
  uint32_t width{};
  uint32_t height{};
  std::span<const uint8_t> bytes; // exactly width * height bytes, tightly packed
  // Optional immutable owner of exactly bytes. Retention permits identity-based
  // texture reuse; callers must never modify the allocation through an alias.
  std::shared_ptr<const std::vector<uint8_t>> owner{};
};

struct CompositedFrame {
  uint64_t frame_identity{};
  uint32_t width{};
  uint32_t height{};
  // Same-device, premultiplied BGRA render-target/SRV texture.  It can be copied
  // directly into a CompositionDrawingSurface's D3D backing texture.
  Microsoft::WRL::ComPtr<ID3D11Texture2D> premultiplied_bgra;
  // A tile shares the decoded atlas texture. width/height above are its visible
  // dimensions; only this region may be copied into the proxy surface.
  std::optional<TextureRegion> source_region;
  std::shared_ptr<GpuTimestampProbe> shader_gpu_timing;
};

// No decode, allocation, CPU readback or pixel copy: retain the same atlas COM
// texture for an independently sized proxy. Only a full decoded frame is an
// eligible source, so nested crops cannot silently reinterpret coordinates.
inline HRESULT MakeCompositedRegion(const CompositedFrame& atlas,
                                    TextureRegion region,
                                    CompositedFrame* output) {
  if (!output || !atlas.frame_identity || !atlas.premultiplied_bgra ||
      atlas.source_region || !valid_texture_region(atlas.width, atlas.height, region))
    return E_INVALIDARG;
  D3D11_TEXTURE2D_DESC desc{};
  atlas.premultiplied_bgra->GetDesc(&desc);
  if (desc.Width != atlas.width || desc.Height != atlas.height ||
      desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM || desc.SampleDesc.Count != 1 ||
      desc.MipLevels != 1 || desc.ArraySize != 1)
    return E_INVALIDARG;
  *output = {atlas.frame_identity, region.width, region.height,
             atlas.premultiplied_bgra, region, atlas.shader_gpu_timing};
  return S_OK;
}

// Shared by native surface presentation and the headless crop-copy test. The
// caller owns BeginDraw/EndDraw and the final presentation deadline admission.
inline HRESULT CopyCompositedRegion(ID3D11DeviceContext* context,
                                    const CompositedFrame& frame,
                                    ID3D11Texture2D* destination,
                                    uint32_t x, uint32_t y) {
  if (!context || !destination || !frame.frame_identity || !frame.premultiplied_bgra) return E_INVALIDARG;
  D3D11_TEXTURE2D_DESC src{}, dst{};
  frame.premultiplied_bgra->GetDesc(&src);
  destination->GetDesc(&dst);
  Microsoft::WRL::ComPtr<ID3D11Device> device, source_device, destination_device;
  context->GetDevice(&device);
  frame.premultiplied_bgra->GetDevice(&source_device);
  destination->GetDevice(&destination_device);
  const auto region = frame.source_region.value_or(TextureRegion{0, 0, frame.width, frame.height});
  if (device.Get() != source_device.Get() || device.Get() != destination_device.Get() ||
      src.Format != DXGI_FORMAT_B8G8R8A8_UNORM || dst.Format != src.Format ||
      dst.Usage == D3D11_USAGE_IMMUTABLE ||
      src.SampleDesc.Count != 1 || dst.SampleDesc.Count != 1 ||
      src.SampleDesc.Quality != dst.SampleDesc.Quality || src.MipLevels != 1 || src.ArraySize != 1 ||
      !valid_texture_region(src.Width, src.Height, region) ||
      region.width != frame.width || region.height != frame.height ||
      (!frame.source_region && (src.Width != frame.width || src.Height != frame.height)) ||
      uint64_t(x) + frame.width > dst.Width || uint64_t(y) + frame.height > dst.Height ||
      destination == frame.premultiplied_bgra.Get()) return E_INVALIDARG;
  const D3D11_BOX box{region.x, region.y, 0, region.x + region.width, region.y + region.height, 1};
  context->CopySubresourceRegion(destination, 0, x, y, 0, frame.premultiplied_bgra.Get(), 0, &box);
  return device->GetDeviceRemovedReason();
}

// Last decoder geometry observed by the compositor.  This is diagnostic-only:
// negotiated_* comes from the output media type, texture_* from the decoded
// D3D resource, and aperture_* from MF_MT_MINIMUM_DISPLAY_APERTURE when present.
struct DecoderGeometry {
  uint32_t negotiated_width{};
  uint32_t negotiated_height{};
  uint32_t texture_width{};
  uint32_t texture_height{};
  bool has_minimum_display_aperture{};
  int32_t aperture_x{};
  int32_t aperture_y{};
  uint16_t aperture_x_fraction{};
  uint16_t aperture_y_fraction{};
  uint32_t aperture_width{};
  uint32_t aperture_height{};
};

// Host-side time spent by the most recent Submit().  These timings measure API
// submission/CPU work only; GPU completion remains asynchronous.  A delayed
// decoder frame is charged to the Submit() whose Drain() received it.
struct SubmitHostDurations {
  uint64_t frame_identity{};
  // Cache hit comparison or cache-miss R8 texture plus SRV construction.
  uint64_t alpha_texture_create_us{};
  bool alpha_texture_reused{};
  uint64_t mf_sample_copy_us{};
  uint64_t mf_process_input_us{};
  uint64_t mf_process_output_us{};
  uint64_t composite_gpu_resource_alloc_us{};
  uint64_t composite_video_processor_us{};
  uint64_t composite_shader_us{};
  uint64_t total_submit_us{};
};

// Hardware-only H.264 High (profile 100) decoder plus NV12/R8 GPU compositor.
// There is intentionally no software decoder, CPU color readback, or alpha
// reconstruction path.  Failures such as unsupported hardware/profile surface
// as HRESULTs to the caller.
class GpuVideoCompositor final {
 public:
  // Zero preserves decoder default; two is a diagnostic worker-count contrast.
  static HRESULT Create(GpuVideoCompositor* out, uint32_t diagnostic_workers = 0, uint32_t color_codec = 2);
  GpuVideoCompositor() = default;
  ~GpuVideoCompositor();
  GpuVideoCompositor(const GpuVideoCompositor&) = delete;
  GpuVideoCompositor& operator=(const GpuVideoCompositor&) = delete;

  // Submit exactly one Annex-B access unit and its independently supplied alpha.
  // Completed display-order frames are returned.  A decoder is permitted to
  // retain a bounded reorder queue; call Finish() to drain it.
  HRESULT Submit(uint64_t frame_identity, std::span<const uint8_t> h264_annex_b,
                 const RawGray8Alpha& alpha,
                 std::vector<CompositedFrame>* completed);
  HRESULT Finish(std::vector<CompositedFrame>* completed);

  ID3D11Device* device() const { return device_.Get(); }
  ID3D11DeviceContext* context() const { return context_.Get(); }
  DecoderGeometry decoder_geometry() const { return decoder_geometry_; }
  SubmitHostDurations last_submit_host_durations() const { return last_submit_host_durations_; }

 private:
  struct Pending {
    uint64_t identity{};
    LONGLONG sample_time{};
    uint32_t width{};
    uint32_t height{};
    Microsoft::WRL::ComPtr<ID3D11Texture2D> alpha;
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> alpha_srv;
  };
  struct ConversionCache {
    UINT input_width{}, input_height{}, output_width{}, output_height{};
    Microsoft::WRL::ComPtr<ID3D11VideoProcessorEnumerator> enumerator;
    Microsoft::WRL::ComPtr<ID3D11VideoProcessor> processor;
  };
  // Bounded scratch for the decoder-only NV12 -> shader-NV12 fallback.  This
  // is never a delivered frame: callers can retain CompositedFrame textures.
  struct ShaderNv12Cache {
    ID3D11Device* device{};
    DXGI_FORMAT input_format{DXGI_FORMAT_UNKNOWN};
    UINT input_width{}, input_height{};
    UINT input_sample_count{}, input_sample_quality{};
    UINT crop_x{}, crop_y{}, output_width{}, output_height{};
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> y;
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> uv;
  };
  HRESULT Initialize(uint32_t diagnostic_workers, uint32_t color_codec);
  HRESULT Drain(std::vector<CompositedFrame>* completed);
  HRESULT SetOutputType();
  HRESULT Composite(IMFSample* sample, std::vector<CompositedFrame>* completed);

  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> manager_;
  Microsoft::WRL::ComPtr<IMFTransform> decoder_;
#ifdef VIEWFLOW_HAVE_FFMPEG
  std::unique_ptr<FfmpegDecoder> ffmpeg_decoder_;
#endif
  Microsoft::WRL::ComPtr<ID3D11VertexShader> vs_;
  Microsoft::WRL::ComPtr<ID3D11PixelShader> ps_;
  Microsoft::WRL::ComPtr<ID3D11PixelShader> bgra_alpha_ps_;
  Microsoft::WRL::ComPtr<ID3D11SamplerState> sampler_;
  Microsoft::WRL::ComPtr<ID3D11VideoDevice> video_device_;
  Microsoft::WRL::ComPtr<ID3D11VideoContext> video_context_;
  UINT reset_token_{};
  bool streaming_{};
  bool poisoned_{};
  uint64_t last_frame_identity_{};
  LONGLONG next_sample_time_{};
  DecoderGeometry decoder_geometry_{};
  SubmitHostDurations last_submit_host_durations_{};
  bool recording_submit_host_durations_{};
  ConversionCache conversion_{}; // One geometry only; no frame/pixel ownership.
  ShaderNv12Cache shader_nv12_{};
  // One immutable alpha texture/SRV pair. Pending frames retain their own COM
  // references; a cache miss builds the complete pair before it replaces this
  // cache, so it cannot overwrite an in-flight frame or a usable old pair.
  uint32_t cached_alpha_width_{}, cached_alpha_height_{};
  std::vector<uint8_t> cached_alpha_bytes_;
  std::shared_ptr<const std::vector<uint8_t>> cached_alpha_owner_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> cached_alpha_texture_;
  Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> cached_alpha_srv_;
  std::vector<Pending> pending_;
};

} // namespace viewflow::windows

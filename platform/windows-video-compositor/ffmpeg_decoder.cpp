#include "ffmpeg_decoder.h"
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>
}
#include <cstdio>
#include <cstring>
#include <limits>
namespace viewflow::windows {
namespace {
AVPixelFormat gpu_format(AVCodecContext*, const AVPixelFormat* formats) {
  for (; *formats != AV_PIX_FMT_NONE; ++formats)
    if (*formats == AV_PIX_FMT_D3D11) return *formats;
  return AV_PIX_FMT_NONE;
}
HRESULT failure(int status, const char* stage) {
  char error[AV_ERROR_MAX_STRING_SIZE]{};
  av_strerror(status, error, sizeof(error));
  std::fprintf(stderr, "atlas-ffmpeg-decode stage=%s error=%s\n", stage, error);
  return E_FAIL;
}
}
FfmpegDecoder::~FfmpegDecoder() {
  avcodec_free_context(&decoder_);
  av_buffer_unref(&device_);
}
HRESULT FfmpegDecoder::Initialize(ID3D11Device* device, uint32_t codec) {
  if (!device || decoder_ || device_ || codec != 4) return E_INVALIDARG;
  device_ = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
  if (!device_) return E_OUTOFMEMORY;
  auto* hw = static_cast<AVD3D11VADeviceContext*>(
      reinterpret_cast<AVHWDeviceContext*>(device_->data)->hwctx);
  hw->device = device;
  device->AddRef();
  int result = av_hwdevice_ctx_init(device_);
  if (result < 0) return failure(result, "device");
  const AVCodec* implementation = avcodec_find_decoder_by_name("av1");
  if (!implementation) return E_NOTIMPL;
  decoder_ = avcodec_alloc_context3(implementation);
  if (!decoder_) return E_OUTOFMEMORY;
  decoder_->hw_device_ctx = av_buffer_ref(device_);
  if (!decoder_->hw_device_ctx) return E_OUTOFMEMORY;
  decoder_->get_format = gpu_format;
  decoder_->thread_count = 1;
  decoder_->flags |= AV_CODEC_FLAG_LOW_DELAY;
  decoder_->pkt_timebase = AVRational{1, 10000000};
  decoder_->extra_hw_frames = 4;
  decoder_->apply_cropping = 0;
  result = avcodec_open2(decoder_, implementation, nullptr);
  if (result < 0) return failure(result, "open");
  std::fprintf(stderr, "atlas-color-decoder codec=av1 backend=ffmpeg-d3d11va hardware_required=true\n");
  return S_OK;
}
HRESULT FfmpegDecoder::Submit(std::span<const uint8_t> bytes, int64_t timestamp,
                             std::vector<FfmpegDecodedFrame>* frames) {
  if (!decoder_ || !frames || bytes.empty() || bytes.size() > INT_MAX || timestamp < 0)
    return E_INVALIDARG;
  AVPacket* packet = av_packet_alloc();
  if (!packet) return E_OUTOFMEMORY;
  int result = av_new_packet(packet, static_cast<int>(bytes.size()));
  if (result >= 0) {
    std::memcpy(packet->data, bytes.data(), bytes.size());
    packet->pts = packet->dts = timestamp;
    result = avcodec_send_packet(decoder_, packet);
  }
  av_packet_free(&packet);
  if (result < 0) return failure(result, "submit");
  for (;;) {
    AVFrame* raw = av_frame_alloc();
    if (!raw) return E_OUTOFMEMORY;
    std::shared_ptr<AVFrame> frame(raw, [](AVFrame* owned) { av_frame_free(&owned); });
    result = avcodec_receive_frame(decoder_, raw);
    if (result == AVERROR(EAGAIN)) return S_OK;
    if (result < 0) return failure(result, "output");
    if (raw->format != AV_PIX_FMT_D3D11 || !raw->data[0] || raw->pts < 0 ||
        raw->width <= 0 || raw->height <= 0 ||
        raw->crop_left + raw->crop_right >= static_cast<size_t>(raw->width) ||
        raw->crop_top + raw->crop_bottom >= static_cast<size_t>(raw->height)) return E_FAIL;
    FfmpegDecodedFrame output;
    output.allocation = std::move(frame);
    output.texture = reinterpret_cast<ID3D11Texture2D*>(raw->data[0]);
    const auto subresource = reinterpret_cast<uintptr_t>(raw->data[1]);
    if (subresource > UINT_MAX) return E_FAIL;
    output.subresource = static_cast<uint32_t>(subresource);
    output.width = static_cast<uint32_t>(raw->width - raw->crop_left - raw->crop_right);
    output.height = static_cast<uint32_t>(raw->height - raw->crop_top - raw->crop_bottom);
    output.crop_x = static_cast<uint32_t>(raw->crop_left);
    output.crop_y = static_cast<uint32_t>(raw->crop_top);
    output.timestamp = raw->pts;
    D3D11_TEXTURE2D_DESC desc{};
    output.texture->GetDesc(&desc);
    if (desc.Format != DXGI_FORMAT_NV12 || output.subresource >= desc.ArraySize) return E_FAIL;
    frames->push_back(std::move(output));
  }
}
}

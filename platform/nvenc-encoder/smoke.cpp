#include "nvenc_encoder.hpp"

#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
}

using namespace viewflow::nvenc;

bool verify_alpha_software_decode(const std::vector<EncodedAccessUnit>& output,
                                  const std::vector<std::vector<std::uint8_t>>& inputs,
                                  std::uint32_t width, std::uint32_t height, std::string* error) {
  const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
  AVCodecContext* context = codec ? avcodec_alloc_context3(codec) : nullptr;
  AVPacket* packet = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  if (!codec || !context || !packet || !frame || avcodec_open2(context, codec, nullptr) < 0) {
    *error = "could not initialize software H.264 decoder";
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&context);
    return false;
  }
  bool valid = output.size() == inputs.size();
  for (std::size_t index = 0; index < output.size() && valid; ++index) {
    if (output[index].alpha == AlphaDisposition::OpaqueOmitted) continue;
    const auto& annex_b = output[index].alpha_annex_b;
    if (annex_b.size() > static_cast<std::size_t>(std::numeric_limits<int>::max()) ||
        av_new_packet(packet, static_cast<int>(annex_b.size())) < 0) {
      valid = false;
      break;
    }
    std::memcpy(packet->data, annex_b.data(), annex_b.size());
    const int sent = avcodec_send_packet(context, packet);
    const int received = sent < 0 ? sent : avcodec_receive_frame(context, frame);
    const bool yuv444_full_range = frame->format == AV_PIX_FMT_YUV444P ||
                                   frame->format == AV_PIX_FMT_YUVJ444P;
    valid = received >= 0 && yuv444_full_range && frame->color_range == AVCOL_RANGE_JPEG &&
            frame->width == static_cast<int>(width) &&
            frame->height == static_cast<int>(height);
    if (!valid) {
      *error = "decoded alpha properties: receive=" + std::to_string(received) +
               " format=" + std::to_string(frame->format) +
               " range=" + std::to_string(frame->color_range) +
               " size=" + std::to_string(frame->width) + "x" + std::to_string(frame->height);
    }
    if (valid) {
      for (std::uint32_t y = 0; y < height && valid; ++y) {
        for (std::uint32_t x = 0; x < width; ++x) {
          const auto offset = static_cast<std::size_t>(y) * width + x;
          const auto decoded =
              frame->data[0][static_cast<std::ptrdiff_t>(y) * frame->linesize[0] + x];
          const auto expected = inputs[index][offset * 4 + 3];
          const bool chroma =
              frame->data[1][static_cast<std::ptrdiff_t>(y) * frame->linesize[1] + x] == 128 &&
              frame->data[2][static_cast<std::ptrdiff_t>(y) * frame->linesize[2] + x] == 128;
          valid = decoded == expected && chroma;
          if (!valid) {
            *error = "alpha mismatch at frame " + std::to_string(index) + " pixel " +
                     std::to_string(offset) + ": decoded=" + std::to_string(decoded) +
                     " expected=" + std::to_string(expected) +
                     (chroma ? "" : " (non-neutral chroma)");
            break;
          }
        }
      }
    }
    av_packet_unref(packet);
  }
  if (!valid && error->empty()) *error = "software decode did not preserve full-range YUV444 alpha exactly";
  av_frame_free(&frame);
  av_packet_free(&packet);
  avcodec_free_context(&context);
  return valid;
}

int main() {
  constexpr std::uint32_t kWidth = 1556;
  constexpr std::uint32_t kHeight = 1300;
  std::string error;
  std::vector<std::uint8_t> rgba(static_cast<std::size_t>(kWidth) * kHeight * 4, 0);
  for (std::size_t pixel = 0; pixel < rgba.size() / 4; ++pixel) {
    rgba[pixel * 4] = static_cast<std::uint8_t>(pixel);
    rgba[pixel * 4 + 1] = static_cast<std::uint8_t>(pixel >> 3U);
    rgba[pixel * 4 + 2] = 127;
    rgba[pixel * 4 + 3] = static_cast<std::uint8_t>(pixel >> 5U);
  }
  std::vector<std::vector<std::uint8_t>> inputs;
  inputs.push_back(rgba);
  std::vector<std::uint8_t> opaque = rgba;
  for (std::size_t pixel = 0; pixel < opaque.size() / 4; ++pixel) opaque[pixel * 4 + 3] = 255;
  inputs.push_back(opaque);
  std::vector<std::uint8_t> resumed = rgba;
  for (std::size_t pixel = 0; pixel < resumed.size() / 4; ++pixel) resumed[pixel * 4 + 3] ^= 0x5aU;
  inputs.push_back(resumed);
  std::vector<EncodedAccessUnit> output;
  const EncoderConfig config_with_omission{kWidth,
                                           kHeight,
                                           32U * 1024U * 1024U,
                                           2,
                                           AlphaPolicy::OpaqueMayOmit,
                                           AlphaFidelity{AlphaFidelityKind::Lossless}};
  auto encoder = Encoder::create(config_with_omission, &error);
  if (!encoder ||
      !encoder->submit(inputs[0], FrameMetadata{7, 123456789, 3}, true, &output, &error) ||
      !encoder->submit(inputs[1], FrameMetadata{8, 123456790, 3}, false, &output, &error) ||
      !encoder->submit(inputs[2], FrameMetadata{9, 123456791, 4}, false, &output, &error) ||
      !encoder->drain(&output, &error)) {
    std::cerr << "NVENC smoke encode failed: " << error << '\n';
    return 1;
  }
  if (output.size() != 3 || output[0].metadata.frame_id != 7 ||
      output[1].metadata.timestamp_ns != 123456790 || output[2].metadata.geometry_epoch != 4 ||
      output[0].alpha != AlphaDisposition::EncodedFullRange ||
      output[1].alpha != AlphaDisposition::OpaqueOmitted ||
      output[2].alpha != AlphaDisposition::EncodedFullRange || !output[0].color_is_idr ||
      !output[0].alpha_is_idr || !output[2].alpha_is_idr || output[1].alpha_stream.has_value() ||
      !output[2].alpha_stream.has_value()) {
    std::cerr << "NVENC smoke did not preserve paired metadata and alpha omission/IDR state\n";
    return 1;
  }
  if (!verify_alpha_software_decode(output, inputs, kWidth, kHeight, &error)) {
    std::cerr << "NVENC alpha software decode failed: " << error << '\n';
    return 1;
  }
  std::cout << "persistent paired NVENC Annex-B smoke passed: color="
            << output.front().color_annex_b.size() << " alpha=" << output.front().alpha_annex_b.size()
            << " (High 4:4:4 Predictive, bit-exact alpha software decode)\n";
  return 0;
}

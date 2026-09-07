#include "nvenc_encoder.hpp"

#include <algorithm>
#include <cstring>
#include <limits>
#include <map>
#include <optional>
#include <utility>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
}

namespace viewflow::nvenc {
namespace {

[[nodiscard]] std::string ffmpeg_error(int code) {
  char text[AV_ERROR_MAX_STRING_SIZE]{};
  av_strerror(code, text, sizeof(text));
  return text;
}

[[nodiscard]] bool valid_config(const EncoderConfig& config, std::string* error) {
  if (config.width == 0 || config.height == 0 || config.max_access_unit_bytes == 0 ||
      config.max_pending_frames == 0) {
    *error = "width, height, access-unit bound, and pending-frame bound must be nonzero";
    return false;
  }
  if (config.width > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
      config.height > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
      static_cast<std::size_t>(config.width) >
          std::numeric_limits<std::size_t>::max() / static_cast<std::size_t>(config.height) / 4 ||
      config.max_access_unit_bytes > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    *error = "geometry or access-unit bound exceeds FFmpeg's supported integer range";
    return false;
  }
  if (config.alpha_fidelity.kind == AlphaFidelityKind::BoundedLossy &&
      (config.alpha_fidelity.max_quantizer == 0 || config.alpha_fidelity.max_quantizer > 51)) {
    *error = "bounded alpha quantizer must be in 1..51";
    return false;
  }
  return true;
}

[[nodiscard]] bool has_annex_b_start_code(const AVPacket* packet) {
  if (packet->size < 4) return false;
  const auto* data = packet->data;
  return (data[0] == 0 && data[1] == 0 && data[2] == 1) ||
         (data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1);
}

[[nodiscard]] bool set_encoder_option(AVCodecContext* context, const char* name,
                                      const char* value, std::string* error) {
  const int result = av_opt_set(context->priv_data, name, value, 0);
  if (result >= 0) return true;
  *error = std::string("could not set NVENC option ") + name + "=" + value + ": " +
           ffmpeg_error(result);
  return false;
}

[[nodiscard]] bool set_encoder_option_int(AVCodecContext* context, const char* name,
                                          std::int64_t value, std::string* error) {
  const int result = av_opt_set_int(context->priv_data, name, value, 0);
  if (result >= 0) return true;
  *error = std::string("could not set NVENC option ") + name + ": " + ffmpeg_error(result);
  return false;
}

struct ContextDeleter {
  void operator()(AVCodecContext* context) const { avcodec_free_context(&context); }
};
using Context = std::unique_ptr<AVCodecContext, ContextDeleter>;

[[nodiscard]] Context make_context(const EncoderConfig& config, AVPixelFormat format,
                                   bool alpha, std::string* error) {
  const AVCodec* codec = avcodec_find_encoder_by_name("h264_nvenc");
  if (codec == nullptr) {
    *error = "h264_nvenc is unavailable in the installed libavcodec";
    return nullptr;
  }
  Context context(avcodec_alloc_context3(codec));
  if (!context) {
    *error = "could not allocate an NVENC codec context";
    return nullptr;
  }
  context->width = static_cast<int>(config.width);
  context->height = static_cast<int>(config.height);
  context->pix_fmt = format;
  context->time_base = AVRational{1, 1'000'000'000};
  context->framerate = AVRational{60, 1};
  context->max_b_frames = 0;
  context->gop_size = 120;
  context->flags |= AV_CODEC_FLAG_LOW_DELAY;
  // Do not request AV_CODEC_FLAG_GLOBAL_HEADER: packet output must be Annex B.
  if (!set_encoder_option(context.get(), "preset", alpha ? "p7" : "p1", error) ||
      !set_encoder_option(context.get(), "tune",
                          alpha && config.alpha_fidelity.kind == AlphaFidelityKind::Lossless
                              ? "lossless"
                              : "ull",
                          error) ||
      !set_encoder_option(context.get(), "zerolatency", "1", error) ||
      !set_encoder_option(context.get(), "delay", "0", error) ||
      !set_encoder_option(context.get(), "rc-lookahead", "0", error) ||
      !set_encoder_option(context.get(), "forced-idr", "1", error) ||
      !set_encoder_option(context.get(), "multipass", "disabled", error)) {
    return nullptr;
  }
  if (!alpha) {
    if (!set_encoder_option(context.get(), "profile", "high", error) ||
        !set_encoder_option(context.get(), "rgb_mode", "yuv420", error)) {
      return nullptr;
    }
  }
  if (alpha) {
    context->color_range = AVCOL_RANGE_JPEG;
    context->color_primaries = AVCOL_PRI_UNSPECIFIED;
    context->color_trc = AVCOL_TRC_UNSPECIFIED;
    context->colorspace = AVCOL_SPC_UNSPECIFIED;
    if (!set_encoder_option(context.get(), "profile", "high444p", error) ||
        !set_encoder_option(context.get(), "rc", "constqp", error)) {
      return nullptr;
    }
    const int qp = config.alpha_fidelity.kind == AlphaFidelityKind::Lossless
                       ? 0
                       : config.alpha_fidelity.max_quantizer;
    if (!set_encoder_option_int(context.get(), "qp", qp, error)) return nullptr;
  }
  const int opened = avcodec_open2(context.get(), codec, nullptr);
  if (opened < 0) {
    *error = "could not open h264_nvenc: " + ffmpeg_error(opened);
    return nullptr;
  }
  return context;
}

[[nodiscard]] AVFrame* allocate_frame(const EncoderConfig& config, AVPixelFormat format,
                                      std::string* error) {
  AVFrame* frame = av_frame_alloc();
  if (!frame) {
    *error = "could not allocate an AVFrame";
    return nullptr;
  }
  frame->format = format;
  frame->width = static_cast<int>(config.width);
  frame->height = static_cast<int>(config.height);
  const int allocated = av_frame_get_buffer(frame, 32);
  if (allocated < 0) {
    *error = "could not allocate an AVFrame buffer: " + ffmpeg_error(allocated);
    av_frame_free(&frame);
    return nullptr;
  }
  return frame;
}

void free_frame(AVFrame*& frame) { av_frame_free(&frame); }

}  // namespace

AlphaPlanes split_straight_rgba_alpha(std::span<const std::uint8_t> rgba, std::uint32_t width,
                                      std::uint32_t height) {
  const std::size_t pixels = static_cast<std::size_t>(width) * height;
  AlphaPlanes result{std::vector<std::uint8_t>(pixels), std::vector<std::uint8_t>(pixels, 128),
                     std::vector<std::uint8_t>(pixels, 128), true};
  if (rgba.size() != pixels * 4) return {};
  for (std::size_t pixel = 0; pixel < pixels; ++pixel) {
    const auto alpha = rgba[pixel * 4 + 3];
    result.luma[pixel] = alpha;
    result.all_opaque = result.all_opaque && alpha == 255;
  }
  return result;
}

bool is_straight_rgba_opaque(std::span<const std::uint8_t> rgba) {
  if (rgba.size() % 4 != 0) return false;
  for (std::size_t alpha = 3; alpha < rgba.size(); alpha += 4) {
    if (rgba[alpha] != 255) return false;
  }
  return true;
}

struct Encoder::Impl {
  explicit Impl(EncoderConfig value) : config(value) {}
  EncoderConfig config;
  Context color;
  Context alpha;
  AVFrame* color_frame = nullptr;
  AVFrame* alpha_frame = nullptr;
  std::uint64_t next_pts = 0;
  bool alpha_needs_idr = true;
  bool failed = false;
  std::optional<FrameMetadata> last_metadata;
  std::map<std::int64_t, EncodedAccessUnit> pending;

  ~Impl() {
    free_frame(color_frame);
    free_frame(alpha_frame);
  }
};

Encoder::Encoder(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}
Encoder::~Encoder() = default;
Encoder::Encoder(Encoder&&) noexcept = default;
Encoder& Encoder::operator=(Encoder&&) noexcept = default;

std::unique_ptr<Encoder> Encoder::create(const EncoderConfig& config, std::string* error) {
  if (error == nullptr) return nullptr;
  if (!valid_config(config, error)) return nullptr;
  auto impl = std::make_unique<Impl>(config);
  impl->color = make_context(config, AV_PIX_FMT_RGBA, false, error);
  if (!impl->color) return nullptr;
  if (config.alpha_policy != AlphaPolicy::ColorOnlyExternalAlpha) {
    impl->alpha = make_context(config, AV_PIX_FMT_YUV444P, true, error);
    if (!impl->alpha) return nullptr;
  }
  impl->color_frame = allocate_frame(config, AV_PIX_FMT_RGBA, error);
  if (!impl->color_frame) return nullptr;
  if (config.alpha_policy != AlphaPolicy::ColorOnlyExternalAlpha) {
    impl->alpha_frame = allocate_frame(config, AV_PIX_FMT_YUV444P, error);
    if (!impl->alpha_frame) return nullptr;
  }
  return std::unique_ptr<Encoder>(new Encoder(std::move(impl)));
}

namespace {

[[nodiscard]] bool fill_color(Encoder::Impl* impl, std::span<const std::uint8_t> rgba,
                              std::int64_t pts, bool idr, std::string* error) {
  AVFrame* frame = impl->color_frame;
  const int writable = av_frame_make_writable(frame);
  if (writable < 0) {
    *error = "color frame is not writable: " + ffmpeg_error(writable);
    return false;
  }
  const std::size_t row_bytes = static_cast<std::size_t>(impl->config.width) * 4;
  for (std::uint32_t row = 0; row < impl->config.height; ++row) {
    std::memcpy(frame->data[0] + static_cast<std::ptrdiff_t>(row) * frame->linesize[0],
                rgba.data() + static_cast<std::size_t>(row) * row_bytes, row_bytes);
  }
  frame->pts = pts;
  frame->pict_type = idr ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
  return true;
}

[[nodiscard]] bool fill_alpha(Encoder::Impl* impl, const AlphaPlanes& planes,
                              std::int64_t pts, bool idr, std::string* error) {
  AVFrame* frame = impl->alpha_frame;
  const int writable = av_frame_make_writable(frame);
  if (writable < 0) {
    *error = "alpha frame is not writable: " + ffmpeg_error(writable);
    return false;
  }
  const std::size_t row_bytes = impl->config.width;
  for (std::uint32_t row = 0; row < impl->config.height; ++row) {
    const auto offset = static_cast<std::size_t>(row) * row_bytes;
    std::memcpy(frame->data[0] + static_cast<std::ptrdiff_t>(row) * frame->linesize[0],
                planes.luma.data() + offset, row_bytes);
    std::memcpy(frame->data[1] + static_cast<std::ptrdiff_t>(row) * frame->linesize[1],
                planes.chroma_u.data() + offset, row_bytes);
    std::memcpy(frame->data[2] + static_cast<std::ptrdiff_t>(row) * frame->linesize[2],
                planes.chroma_v.data() + offset, row_bytes);
  }
  frame->pts = pts;
  frame->pict_type = idr ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
  return true;
}

enum class Stream { Color, Alpha };

[[nodiscard]] bool drain_context(Encoder::Impl* impl, AVCodecContext* context, Stream stream,
                                 std::vector<EncodedAccessUnit>* output, std::string* error) {
  AVPacket* packet = av_packet_alloc();
  if (!packet) {
    *error = "could not allocate an AVPacket";
    return false;
  }
  bool success = true;
  for (;;) {
    const int received = avcodec_receive_packet(context, packet);
    if (received == AVERROR(EAGAIN) || received == AVERROR_EOF) break;
    if (received < 0) {
      *error = "could not receive NVENC packet: " + ffmpeg_error(received);
      success = false;
      break;
    }
    const auto found = impl->pending.find(packet->pts);
    if (found == impl->pending.end()) {
      *error = "NVENC produced a packet with no pending frame metadata";
      success = false;
      break;
    }
    if (packet->size <= 0 || static_cast<std::size_t>(packet->size) > impl->config.max_access_unit_bytes ||
        !has_annex_b_start_code(packet)) {
      *error = "NVENC produced a non-Annex-B or oversized access unit";
      success = false;
      break;
    }
    std::vector<std::uint8_t> data(packet->data, packet->data + packet->size);
    if (stream == Stream::Color) {
      if (!found->second.color_annex_b.empty()) {
        *error = "NVENC produced duplicate color output for one frame";
        success = false;
        break;
      }
      found->second.color_annex_b = std::move(data);
    } else {
      if (!found->second.alpha_annex_b.empty()) {
        *error = "NVENC produced duplicate alpha output for one frame";
        success = false;
        break;
      }
      found->second.alpha_annex_b = std::move(data);
    }
    av_packet_unref(packet);
  }
  av_packet_free(&packet);
  if (!success) return false;
  for (auto it = impl->pending.begin(); it != impl->pending.end();) {
    const bool alpha_ready = it->second.alpha == AlphaDisposition::OpaqueOmitted ||
                             it->second.alpha == AlphaDisposition::ExternalAlpha ||
                             !it->second.alpha_annex_b.empty();
    if (!it->second.color_annex_b.empty() && alpha_ready) {
      output->push_back(std::move(it->second));
      it = impl->pending.erase(it);
    } else {
      ++it;
    }
  }
  return true;
}

}  // namespace

bool Encoder::submit(std::span<const std::uint8_t> rgba, FrameMetadata metadata, bool force_idr,
                     std::vector<EncodedAccessUnit>* output, std::string* error) {
  if (output == nullptr || error == nullptr) return false;
  if (impl_->failed) {
    *error = "NVENC session is failed after an uncertain accepted-frame error; recreate it";
    return false;
  }
  const std::size_t expected = static_cast<std::size_t>(impl_->config.width) * impl_->config.height * 4;
  if (rgba.size() != expected) {
    *error = "straight RGBA input length does not match configured geometry";
    return false;
  }
  if (metadata.frame_id == 0 || metadata.geometry_epoch == 0) {
    *error = "frame ID and geometry epoch must be nonzero";
    return false;
  }
  if (impl_->last_metadata.has_value() &&
      (metadata.frame_id <= impl_->last_metadata->frame_id ||
       metadata.timestamp_ns < impl_->last_metadata->timestamp_ns ||
       metadata.geometry_epoch < impl_->last_metadata->geometry_epoch)) {
    *error = "frame ID must increase and timestamp/geometry epoch must not regress";
    return false;
  }
  if (impl_->next_pts > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    *error = "NVENC PTS space is exhausted; recreate the session";
    return false;
  }
  if (impl_->pending.size() >= impl_->config.max_pending_frames) {
    *error = "bounded NVENC pending-frame queue is full";
    return false;
  }
  // CompatibleEncoder has already made its input opaque.  Do not allocate and
  // initialize the 3x YUV444 alpha planes merely to discover that no alpha AU
  // is needed.  Non-opaque and Required paths retain split_straight_rgba_alpha
  // exactly as before.
  const bool external_alpha = impl_->config.alpha_policy == AlphaPolicy::ColorOnlyExternalAlpha;
  const bool omit_alpha = external_alpha ||
                          (impl_->config.alpha_policy == AlphaPolicy::OpaqueMayOmit &&
                           is_straight_rgba_opaque(rgba));
  std::optional<AlphaPlanes> alpha_planes;
  if (!omit_alpha) {
    alpha_planes = split_straight_rgba_alpha(rgba, impl_->config.width, impl_->config.height);
  }
  const std::int64_t pts = static_cast<std::int64_t>(impl_->next_pts);
  const bool idr = force_idr || pts == 0;
  const bool alpha_idr = !omit_alpha && (idr || impl_->alpha_needs_idr);
  auto [entry, inserted] = impl_->pending.emplace(
      pts, EncodedAccessUnit{metadata,
                             {},
                             {},
                             external_alpha ? AlphaDisposition::ExternalAlpha
                                            : (omit_alpha ? AlphaDisposition::OpaqueOmitted
                                                          : AlphaDisposition::EncodedFullRange),
                             idr,
                             alpha_idr,
                             color_descriptor(),
                             omit_alpha ? std::nullopt
                                        : std::optional<StreamDescriptor>(alpha_descriptor())});
  if (!inserted) {
    *error = "internal PTS collision";
    return false;
  }
  if (!fill_color(impl_.get(), rgba, pts, idr, error)) {
    impl_->pending.erase(pts);
    return false;
  }
  int sent = avcodec_send_frame(impl_->color.get(), impl_->color_frame);
  if (sent < 0) {
    *error = "could not submit color frame to NVENC: " + ffmpeg_error(sent);
    impl_->pending.erase(pts);
    return false;
  }
  if (!omit_alpha) {
    if (!fill_alpha(impl_.get(), *alpha_planes, pts, alpha_idr, error)) {
      impl_->failed = true;
      return false;
    }
    sent = avcodec_send_frame(impl_->alpha.get(), impl_->alpha_frame);
    if (sent < 0) {
      *error = "could not submit full-range alpha frame to NVENC: " + ffmpeg_error(sent);
      impl_->failed = true;
      return false;
    }
    impl_->alpha_needs_idr = false;
  } else {
    // No alpha AU crossed the stream boundary.  Force a fresh alpha IDR when
    // non-opaque input resumes so it cannot depend on an omitted reference.
    impl_->alpha_needs_idr = true;
  }
  ++impl_->next_pts;
  impl_->last_metadata = metadata;
  if (!drain(output, error)) {
    impl_->failed = true;
    return false;
  }
  return true;
}

bool Encoder::drain(std::vector<EncodedAccessUnit>* output, std::string* error) {
  if (output == nullptr || error == nullptr) return false;
  if (impl_->failed) {
    *error = "NVENC session is failed after an uncertain accepted-frame error; recreate it";
    return false;
  }
  const bool drained = drain_context(impl_.get(), impl_->color.get(), Stream::Color, output, error) &&
                       (impl_->config.alpha_policy == AlphaPolicy::ColorOnlyExternalAlpha ||
                        drain_context(impl_.get(), impl_->alpha.get(), Stream::Alpha, output, error));
  if (!drained) impl_->failed = true;
  return drained;
}

}  // namespace viewflow::nvenc

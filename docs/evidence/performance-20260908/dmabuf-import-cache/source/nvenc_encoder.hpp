// Persistent, Linux-only FFmpeg/NVENC H.264 encoder shim.
//
// The caller supplies straight (not premultiplied) RGBA pixels.  A frame is
// emitted as paired Annex-B H.264 access units: color and, unless explicitly
// omitted because the input is fully opaque, a full-range grayscale alpha
// stream.  This is an encoder boundary only; it does not create windows or
// consume a screen capture source.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace viewflow::nvenc {

struct FrameMetadata {
  std::uint64_t frame_id;
  std::uint64_t timestamp_ns;
  std::uint64_t geometry_epoch;
};

enum class AlphaPolicy {
  // Every input alpha channel is encoded as a paired alpha access unit.
  Required,
  // An all-255 input may omit the alpha access unit, and the output records it.
  OpaqueMayOmit,
  // Alpha is carried by a separately negotiated side channel. The native
  // color encoder ignores source alpha and never claims that it was opaque.
  ColorOnlyExternalAlpha,
};

enum class AlphaFidelityKind { Lossless, BoundedLossy };

struct AlphaFidelity {
  AlphaFidelityKind kind;
  // Only used for BoundedLossy. Valid values are 1..51. Lossless always uses
  // NVENC lossless tuning and QP 0; it never silently selects limited range.
  std::uint8_t max_quantizer = 0;
};

struct EncoderConfig {
  std::uint32_t width;
  std::uint32_t height;
  std::size_t max_access_unit_bytes;
  std::size_t max_pending_frames;
  AlphaPolicy alpha_policy;
  AlphaFidelity alpha_fidelity;
};

enum class AlphaDisposition { EncodedFullRange, OpaqueOmitted, ExternalAlpha };

// Decoder-facing stream identity. `High444Predictive8` is intentionally not
// reported as generic H.264: it carries the full-range alpha luma plane.
enum class H264Profile { High8, High444Predictive8 };

struct StreamDescriptor {
  H264Profile profile;
  bool full_range;
  bool luma_is_straight_alpha;
  bool chroma_is_neutral;
};

struct EncodedAccessUnit {
  FrameMetadata metadata;
  std::vector<std::uint8_t> color_annex_b;
  std::vector<std::uint8_t> alpha_annex_b;
  AlphaDisposition alpha;
  bool color_is_idr;
  bool alpha_is_idr;
  StreamDescriptor color_stream;
  // Empty only when the frame is explicitly reported as OpaqueOmitted.
  std::optional<StreamDescriptor> alpha_stream;
};

struct AlphaPlanes {
  std::vector<std::uint8_t> luma;
  std::vector<std::uint8_t> chroma_u;
  std::vector<std::uint8_t> chroma_v;
  bool all_opaque;
};

// Splits alpha from straight RGBA before any color conversion or
// premultiplication. Alpha planes use YUV444 with JPEG/full range: luma is
// byte-for-byte alpha and both chroma planes are neutral 128.
[[nodiscard]] AlphaPlanes split_straight_rgba_alpha(
    std::span<const std::uint8_t> straight_rgba, std::uint32_t width,
    std::uint32_t height);

// Returns true only for a pixel-aligned straight-RGBA buffer whose alpha byte
// is 255 for every pixel.  This deliberately performs no plane allocation:
// OpaqueMayOmit uses it to avoid preparing an alpha stream that will not be
// submitted.
[[nodiscard]] bool is_straight_rgba_opaque(std::span<const std::uint8_t> straight_rgba);

class Encoder {
 public:
  // Kept opaque; public only so implementation-local FFmpeg helpers can name
  // the state type without exposing its fields to callers.
  struct Impl;

  [[nodiscard]] static std::unique_ptr<Encoder> create(const EncoderConfig& config,
                                                        std::string* error);
  ~Encoder();
  Encoder(const Encoder&) = delete;
  Encoder& operator=(const Encoder&) = delete;
  Encoder(Encoder&&) noexcept;
  Encoder& operator=(Encoder&&) noexcept;

  // Submits one complete straight-RGBA frame to persistent NVENC contexts.
  // `force_idr` requests an IDR in each encoded stream present on the frame
  // (the first frame is always IDR). Successful calls may return zero or more
  // completed paired outputs while the bounded encoder queue drains.
  [[nodiscard]] bool submit(std::span<const std::uint8_t> straight_rgba,
                            FrameMetadata metadata, bool force_idr,
                            std::vector<EncodedAccessUnit>* output,
                            std::string* error);

  // Drains ready packets without flushing/end-of-stream. Contexts stay alive.
  [[nodiscard]] bool drain(std::vector<EncodedAccessUnit>* output,
                           std::string* error);

  [[nodiscard]] static constexpr StreamDescriptor color_descriptor() {
    return {H264Profile::High8, false, false, false};
  }
  [[nodiscard]] static constexpr StreamDescriptor alpha_descriptor() {
    return {H264Profile::High444Predictive8, true, true, true};
  }

 private:
  explicit Encoder(std::unique_ptr<Impl> impl);
  std::unique_ptr<Impl> impl_;
};

}  // namespace viewflow::nvenc

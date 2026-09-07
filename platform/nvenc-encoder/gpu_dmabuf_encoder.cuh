#pragma once
#include "sparse_atlas_plan.hpp"

#include "gpu_shadow_math.cuh"
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace viewflow::gpu {
struct FrameMetadata {
  std::uint64_t frameId = 0;
  std::uint64_t captureTimestampNs = 0;
  std::uint64_t geometryEpoch = 0;
};
struct DmabufFrame {
  int dmaBufFd = -1;
  int nativeFenceFd = -1; // borrowed sync_file; waited only to caller's
                          // absolute MONOTONIC deadline
  std::uint32_t imageWidth = 0, imageHeight = 0, stride = 0, offset = 0,
                fourcc = 0;
  std::uint64_t modifier = 0;
  int cropX = 0, cropY = 0, cropWidth = 0, cropHeight = 0;
  bool flipVertical = false;
  FrameMetadata metadata{};
  std::optional<ShadowSnapshot> shadow;
};
struct SparseSource {
  int64_t x{}, y{};
  uint32_t z{}, grid{};
  uint32_t clipEnabled{}, clipX{}, clipY{}, clipWidth{}, clipHeight{};
};
struct SparseOptions {
  bool prerender = false;
  uint32_t maxWidth{}, maxHeight{};
  std::vector<SparseSource> sources;
};
struct SparseResult {
  std::vector<SparsePatch> patches;
  uint32_t requiredWidth{}, requiredHeight{};
  uint64_t inputPixels{}, storedPixels{}, occludedPixels{}, emptyPixels{}, omittedPixels{};
};
struct EncodedDmabufFrame {
  std::vector<unsigned char> colorAnnexB;
  std::vector<unsigned char> rawAlpha;
  FrameMetadata metadata{};
  bool idr = false;
  std::optional<SparseResult> sparse;
};
struct DmabufAtlasTile {
  DmabufFrame frame;
  int x = 0, y = 0;
  // Original capture lease deadline; never renewed by atlas batching.
  std::int64_t absoluteMonotonicDeadlineNs = 0;
};
struct GpuDmabufEncoderConfig {
  int outputWidth = 0, outputHeight = 0;
  std::size_t maxAccessUnitBytes = 4U * 1024U * 1024U;
  std::uint32_t colorCodec = 2; // transport H264=2, AV1=4
};

enum class EncodeDisposition {
  Failed,
  Encoded,
  // GPU reads completed, imports cleaned, and no NVENC submission occurred.
  ExpiredBeforeSubmission,
  // Matching NVENC packet drained and all imports cleaned; next frame needs IDR.
  ExpiredAfterSubmission,
  NeedsCanvas,
};

// Construction, encode(), and destruction must all occur on one worker thread.
// output dimensions are immutable; make a new instance for resize. No fallback
// path exists: success means exactly one Annex-B access unit was admitted.
// A false return alone never proves capture/GPU cleanup has completed: HCGR callers
// must not send that frame and must disconnect/retire the capture path rather
// than automatically retrying it on this encoder instance. Opt-in callers may
// distinguish ExpiredBeforeSubmission via disposition: that exact outcome
// permits retiring this frame's capture lease without changing the codec chain.
// ExpiredAfterSubmission proves a drained matching packet and completed cleanup;
// discard the frame and reset companion references. The next encode forces IDR.
class GpuDmabufEncoder {
public:
  explicit GpuDmabufEncoder(const GpuDmabufEncoderConfig &,
                            std::string *error = nullptr);
  ~GpuDmabufEncoder();
  GpuDmabufEncoder(GpuDmabufEncoder &&) noexcept;
  GpuDmabufEncoder &operator=(GpuDmabufEncoder &&) noexcept;
  GpuDmabufEncoder(const GpuDmabufEncoder &) = delete;
  GpuDmabufEncoder &operator=(const GpuDmabufEncoder &) = delete;
  bool ready() const;
  bool encode(const DmabufFrame &, bool forceIdr,
              std::int64_t absoluteMonotonicDeadlineNs,
              EncodedDmabufFrame &, std::string *error = nullptr,
              EncodeDisposition *disposition = nullptr);
  // One codec submission for a nonoverlapping layout. All capture leases stay
  // borrowed through return. Output metadata identifies the atlas, not a tile;
  // callers separately transport the layout-to-window identity mapping.
  bool encodeAtlas(const std::vector<DmabufAtlasTile> &, FrameMetadata atlasMetadata,
                   bool forceIdr, std::int64_t absoluteMonotonicDeadlineNs,
                   EncodedDmabufFrame &, std::string *error = nullptr,
                   EncodeDisposition *disposition = nullptr,
                   const SparseOptions *sparse = nullptr);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
} // namespace viewflow::gpu

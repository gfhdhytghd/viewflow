#pragma once
#include "gpu_dmabuf_encoder.cuh"
namespace viewflow::gpu {
class CudaDmabufEncoder {
public:
  explicit CudaDmabufEncoder(const GpuDmabufEncoderConfig &,
                            std::string *error = nullptr);
  ~CudaDmabufEncoder();
  CudaDmabufEncoder(CudaDmabufEncoder &&) noexcept;
  CudaDmabufEncoder &operator=(CudaDmabufEncoder &&) noexcept;
  CudaDmabufEncoder(const CudaDmabufEncoder &) = delete;
  CudaDmabufEncoder &operator=(const CudaDmabufEncoder &) = delete;
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
}

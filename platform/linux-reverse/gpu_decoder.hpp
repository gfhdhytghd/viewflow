#pragma once
#include <cstdint>
#include <memory>
#include <span>
#include <vector>
#include "../reverse-common/progressive_storage.hpp"
struct AVFrame;
namespace viewflow::reverse {
struct SharedPixels;
struct RawUploadCache;
using DecodedFrame=std::shared_ptr<AVFrame>;
// Owner must keep an EGL/GLES context current on the selected rendering device; VA-API surfaces are imported through DMA-BUF.
class GpuDecoder {
public:
    static std::shared_ptr<RawUploadCache> make_upload_cache();
    explicit GpuDecoder(std::shared_ptr<RawUploadCache> cache={});
    ~GpuDecoder();
    void start(unsigned codec = 1);
    std::vector<DecodedFrame> submit(std::span<const std::uint8_t>, std::int64_t pts);
    DecodedFrame raw_bgra(std::shared_ptr<std::vector<std::uint8_t>>, unsigned width, unsigned height, std::int64_t pts);
    DecodedFrame raw_bgra(std::shared_ptr<SharedPixels>, unsigned width, unsigned height, std::int64_t pts);
    void upload(const DecodedFrame&);
    // Current rendering context only. Poll even when no new frames arrive, so
    // completed raw DMA-BUF snapshot copies return their shared-slot leases.
    std::size_t poll_raw_dma();
    std::size_t raw_dma_pending() const;
    bool last_upload_raw_dma() const;
    // Rendering thread/current EGL context only. Keep the previous texture
    // visible until the complete new frame is uploaded; never expose a prefix.
    enum class ProgressiveStatus { pending, complete, aborted };
    static bool progressive_available();
    static void prepare_upload(const std::shared_ptr<RawUploadCache>&);
    // Optional nonblocking eventfd stays valid until cancel/destruction drains CUDA.
    void begin_progressive(std::shared_ptr<shm::ProgressiveStorage::Read>, int completion_fd=-1, std::int64_t trace_pts=0);
    ProgressiveStatus poll_progressive();
    void cancel_progressive();
    unsigned y_texture() const;
    unsigned uv_texture() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}

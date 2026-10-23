#pragma once
#include <cstdint>
#include <memory>
#include <span>
#include <vector>
struct AVFrame;
namespace viewflow::reverse {
using DecodedFrame=std::shared_ptr<AVFrame>;
// Owner must keep an EGL/GLES context current on the selected NVIDIA device.
class GpuDecoder {
public:
    GpuDecoder();
    ~GpuDecoder();
    void start(unsigned codec = 1);
    std::vector<DecodedFrame> submit(std::span<const std::uint8_t>, std::int64_t pts);
    void upload(const DecodedFrame&);
    unsigned y_texture() const;
    unsigned uv_texture() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}

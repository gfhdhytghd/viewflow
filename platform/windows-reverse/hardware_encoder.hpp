#pragma once
#include <d3d11.h>
#include <cstdint>
#include <memory>
#include <vector>

namespace viewflow::reverse {
struct EncodedFrame {
    std::int64_t timestamp{};
    bool keyframe{};
    std::vector<std::uint8_t> bytes;
};
// Single-owner, asynchronous hardware H264 encoder. Color remains on D3D11
// through conversion and submission. Busy encoders return S_FALSE so capture
// can replace the pending frame without blocking the UI or accumulating work.
class HardwareEncoder {
public:
    HardwareEncoder();
    ~HardwareEncoder();
    HRESULT start(ID3D11Device*, unsigned width, unsigned height, unsigned fps = 60, unsigned codec = 1);
    HRESULT submit(ID3D11Texture2D* bgra, std::int64_t timestamp, bool keyframe);
    HRESULT poll(std::vector<EncodedFrame>&);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}

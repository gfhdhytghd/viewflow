#pragma once
#include "hardware_encoder.hpp"
#include <d3d11.h>
#include <cstdint>
#include <memory>
#include <vector>

namespace viewflow::reverse {
// Single-owner, asynchronous hardware H264/HEVC encoder. Color remains on D3D11
// through conversion and submission. Busy encoders return S_FALSE so capture
// can replace the pending frame without blocking the UI or accumulating work.
class MediaFoundationEncoder {
public:
    MediaFoundationEncoder();
    ~MediaFoundationEncoder();
    HRESULT start(ID3D11Device*, unsigned width, unsigned height, unsigned fps = 60, unsigned codec = 1);
    HRESULT can_submit();
    HRESULT submit(ID3D11Texture2D* bgra, std::int64_t timestamp, bool keyframe);
    HRESULT poll(std::vector<EncodedFrame>&);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}

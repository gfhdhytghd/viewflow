#pragma once
#include "hardware_encoder.hpp"
#include <d3d11.h>
#include <cstdint>
#include <memory>
#include <vector>

namespace viewflow::reverse {
// Asynchronous Intel HEVC path. An owned NV12 texture remains valid until VPL
// releases it; completion polling requests a zero-millisecond wait. Two color
// tasks may run in parallel; draining finishes before fresh input is accepted.
class VplEncoder {
public:
    VplEncoder();
    ~VplEncoder();
    HRESULT start(ID3D11Device*, unsigned width, unsigned height, unsigned fps = 60, unsigned codec = 2);
    HRESULT can_submit();
    HRESULT submit(ID3D11Texture2D* bgra, std::int64_t timestamp, bool keyframe);
    HRESULT poll(std::vector<EncodedFrame>&);
    // Request buffered output when the producer cannot feed another frame.
    // This queues work without waiting or resetting the encoder.
    HRESULT request_output();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}

#pragma once
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <vector>
namespace viewflow::media {
// Hardware color encoding, with an explicit system-memory upload. Alpha is
// carried by the existing lossless side channel, never through chroma planes.
class VaapiEncoder {
public:
    VaapiEncoder(int width,int height,unsigned codec,const std::string& renderNode);
    ~VaapiEncoder();
    std::vector<uint8_t> encode(std::span<const uint8_t> rgba, bool idr, bool& keyframe);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}

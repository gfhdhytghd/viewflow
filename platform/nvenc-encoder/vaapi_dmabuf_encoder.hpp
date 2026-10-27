#pragma once
#include "gpu_dmabuf_encoder.cuh"
namespace viewflow::gpu {
class VaapiDmabufEncoder {
public:
    explicit VaapiDmabufEncoder(const GpuDmabufEncoderConfig&,const std::string& renderNode);
    ~VaapiDmabufEncoder();
    bool setBitrateKbps(uint32_t kbps,std::string* error);
    bool encodeAtlas(const std::vector<DmabufAtlasTile>&,FrameMetadata,bool,std::int64_t,
        EncodedDmabufFrame&,std::string*,EncodeDisposition*,const SparseOptions*);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}

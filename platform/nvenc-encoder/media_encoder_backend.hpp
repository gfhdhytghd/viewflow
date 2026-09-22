#pragma once
#include "gpu_dmabuf_encoder.cuh"
namespace viewflow::gpu {
// Private same-build plugin interface; this never crosses the frame protocol.
class MediaEncoderBackend {
public:
    virtual ~MediaEncoderBackend()=default;
    virtual bool ready()const=0;
    virtual bool encodeAtlas(const std::vector<DmabufAtlasTile>&,FrameMetadata,bool,int64_t,
        EncodedDmabufFrame&,std::string*,EncodeDisposition*,const SparseOptions*)=0;
};
using CreateCudaEncoder=MediaEncoderBackend* (*)(const GpuDmabufEncoderConfig*,std::string*);
}

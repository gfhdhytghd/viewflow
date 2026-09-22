#include "media_encoder_backend.hpp"
#include "cuda_dmabuf_encoder.hpp"
namespace viewflow::gpu {
class CudaBackend final:public MediaEncoderBackend {
    CudaDmabufEncoder encoder;
public:
    CudaBackend(const GpuDmabufEncoderConfig& config,std::string* error):encoder(config,error) {}
    bool ready()const override{return encoder.ready();}
    bool encodeAtlas(const std::vector<DmabufAtlasTile>& tiles,FrameMetadata metadata,bool idr,int64_t deadline,
        EncodedDmabufFrame& output,std::string* error,EncodeDisposition* disposition,const SparseOptions* sparse)override {
        return encoder.encodeAtlas(tiles,metadata,idr,deadline,output,error,disposition,sparse);
    }
};
}
extern "C" viewflow::gpu::MediaEncoderBackend* viewflow_create_cuda_encoder_v1(
    const viewflow::gpu::GpuDmabufEncoderConfig* config,std::string* error) {
    try {return new viewflow::gpu::CudaBackend(*config,error);}
    catch(const std::exception& failure) {if(error)*error=failure.what();return nullptr;}
}

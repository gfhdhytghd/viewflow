#include "gpu_dmabuf_encoder.cuh"
#include "vaapi_dmabuf_encoder.hpp"
#include "../linux-media/device_selection.hpp"
#include "media_encoder_backend.hpp"
#include <dlfcn.h>
#include <cstdio>
namespace viewflow::gpu {
struct GpuDmabufEncoder::Impl {
    GpuDmabufEncoderConfig config;
    std::unique_ptr<VaapiDmabufEncoder> vaapi;
    std::unique_ptr<MediaEncoderBackend> cuda;
};
GpuDmabufEncoder::GpuDmabufEncoder(const GpuDmabufEncoderConfig& config,std::string* error):impl_(std::make_unique<Impl>()) {
    impl_->config=config;
    try {
        auto device=media::selection(false);
        if(device.vaapi) {
            impl_->vaapi=std::make_unique<VaapiDmabufEncoder>(config,device.renderNode);
            std::fprintf(stderr,"Viewflow media backend=vaapi device=%s preparation=cpu initialization=ok\n",device.renderNode.c_str());
        } else {
            // Keep the module resident: CUDA may retain process-lifetime state.
            static void* module=dlopen("libviewflow-cuda-encoder.so",RTLD_NOW|RTLD_LOCAL);
            if(!module) throw std::runtime_error("NVIDIA media module or its CUDA driver dependency is unavailable");
            auto create=reinterpret_cast<CreateCudaEncoder>(dlsym(module,"viewflow_create_cuda_encoder_v1"));
            if(!create) throw std::runtime_error("NVIDIA media module has an incompatible interface");
            impl_->cuda.reset(create(&config,error));
            if(impl_->cuda && impl_->cuda->ready())
                std::fprintf(stderr,"Viewflow media backend=nvidia device=%s preparation=cuda initialization=ok\n",device.renderNode.c_str());
        }
    } catch(const std::exception& failure) {
        if(error) *error=failure.what();
    }
}
GpuDmabufEncoder::~GpuDmabufEncoder()=default;
GpuDmabufEncoder::GpuDmabufEncoder(GpuDmabufEncoder&&) noexcept=default;
GpuDmabufEncoder& GpuDmabufEncoder::operator=(GpuDmabufEncoder&&) noexcept=default;
bool GpuDmabufEncoder::ready()const {
    if(!impl_) return false;
    if(impl_->cuda) return impl_->cuda->ready();
    return bool(impl_->vaapi);
}
bool GpuDmabufEncoder::encode(const DmabufFrame& frame,bool idr,int64_t deadline,EncodedDmabufFrame& output,std::string* error,EncodeDisposition* disposition) {
    if(!impl_ || frame.cropWidth!=impl_->config.outputWidth || frame.cropHeight!=impl_->config.outputHeight) {
        output={};if(disposition) *disposition=EncodeDisposition::Failed;
        if(error) *error="single-frame crop must match output geometry";
        return false;
    }
    return encodeAtlas({{frame,0,0,deadline}},frame.metadata,idr,deadline,output,error,disposition);
}
bool GpuDmabufEncoder::encodeAtlas(const std::vector<DmabufAtlasTile>& tiles,FrameMetadata metadata,bool idr,int64_t deadline,
    EncodedDmabufFrame& output,std::string* error,EncodeDisposition* disposition,const SparseOptions* sparse) {
    if(impl_) {
        if(impl_->vaapi) return impl_->vaapi->encodeAtlas(tiles,metadata,idr,deadline,output,error,disposition,sparse);
        if(impl_->cuda) return impl_->cuda->encodeAtlas(tiles,metadata,idr,deadline,output,error,disposition,sparse);
    }
    output={};if(disposition) *disposition=EncodeDisposition::Failed;
    if(error) *error="media encoder is not initialized";
    return false;
}
}

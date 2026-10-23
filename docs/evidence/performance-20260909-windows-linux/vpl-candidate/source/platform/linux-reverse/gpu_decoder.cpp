#include "gpu_decoder.hpp"
#include <GLES3/gl3.h>
#include <cuda.h>
#include <cudaGL.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_cuda.h>
}
#include <stdexcept>
#include <cstring>
#include <string>
#include <climits>
namespace viewflow::reverse {
namespace {
void check(int value) {
    if(value>=0) return;
    char message[AV_ERROR_MAX_STRING_SIZE]{}; av_strerror(value,message,sizeof(message));
    throw std::runtime_error(std::string("reverse decoder: ")+message);
}
void cuda_check(CUresult value) {
    if(value==CUDA_SUCCESS) return;
    const char* message=nullptr; cuGetErrorString(value,&message);
    throw std::runtime_error(std::string("reverse GPU import: ")+(message?message:"unknown"));
}
struct CurrentCuda {
    explicit CurrentCuda(CUcontext context) { cuda_check(cuCtxPushCurrent(context)); }
    ~CurrentCuda() { CUcontext old{}; cuCtxPopCurrent(&old); }
};
AVPixelFormat format(AVCodecContext*,const AVPixelFormat* candidates) {
    for(;*candidates!=AV_PIX_FMT_NONE;++candidates) if(*candidates==AV_PIX_FMT_CUDA) return *candidates;
    return AV_PIX_FMT_NONE;
}
}
struct GpuDecoder::Impl {
    AVCodecContext* decoder{};
    AVBufferRef* device{};
    CUcontext context{};
    GLuint textures[2]{};
    CUgraphicsResource resources[2]{};
    unsigned width{},height{};
    void release_textures() noexcept {
        CUcontext old{};
        if(context) cuCtxPushCurrent(context);
        for(auto& resource:resources) { if(resource) cuGraphicsUnregisterResource(resource); resource=nullptr; }
        if(context) cuCtxPopCurrent(&old);
        glDeleteTextures(2,textures); textures[0]=textures[1]=0;
    }
    ~Impl() { release_textures(); avcodec_free_context(&decoder); av_buffer_unref(&device); }
};
GpuDecoder::GpuDecoder():impl_(std::make_unique<Impl>()) {}
GpuDecoder::~GpuDecoder()=default;
void GpuDecoder::start(unsigned codec_id) {
    auto& s=*impl_;
    if(s.decoder) throw std::runtime_error("reverse decoder already started");
    cuda_check(cuInit(0));
    CUdevice gpu{}; unsigned count{};
    cuda_check(cuGLGetDevices(&count,&gpu,1,CU_GL_DEVICE_LIST_CURRENT_FRAME));
    if(!count) throw std::runtime_error("EGL renderer has no CUDA device");
    const std::string ordinal=std::to_string(gpu);
    check(av_hwdevice_ctx_create(&s.device,AV_HWDEVICE_TYPE_CUDA,ordinal.c_str(),nullptr,AV_CUDA_USE_PRIMARY_CONTEXT));
    auto* hw=reinterpret_cast<AVHWDeviceContext*>(s.device->data);
    s.context=static_cast<AVCUDADeviceContext*>(hw->hwctx)->cuda_ctx;
    if(codec_id!=1 && codec_id!=2) throw std::runtime_error("unsupported reverse codec");
    const AVCodec* codec=avcodec_find_decoder(codec_id==2?AV_CODEC_ID_HEVC:AV_CODEC_ID_H264);
    if(!codec) throw std::runtime_error("H264 decoder unavailable");
    s.decoder=avcodec_alloc_context3(codec);
    if(!s.decoder) throw std::bad_alloc();
    s.decoder->hw_device_ctx=av_buffer_ref(s.device);
    if(!s.decoder->hw_device_ctx) throw std::bad_alloc();
    s.decoder->get_format=format; s.decoder->thread_count=1;
    s.decoder->pkt_timebase={1,10000000}; s.decoder->flags|=AV_CODEC_FLAG_LOW_DELAY;
    s.decoder->extra_hw_frames=4;
    check(avcodec_open2(s.decoder,codec,nullptr));
}
std::vector<DecodedFrame> GpuDecoder::submit(std::span<const std::uint8_t> bytes,std::int64_t pts) {
    auto& s=*impl_;
    if(!s.decoder || bytes.empty() || bytes.size()>INT_MAX) throw std::runtime_error("invalid reverse access unit");
    AVPacket* packet=av_packet_alloc(); if(!packet) throw std::bad_alloc();
    int status=av_new_packet(packet,static_cast<int>(bytes.size()));
    if(status>=0) {
        std::memcpy(packet->data,bytes.data(),bytes.size()); packet->pts=packet->dts=pts;
        status=avcodec_send_packet(s.decoder,packet);
    }
    av_packet_free(&packet); check(status);
    std::vector<DecodedFrame> frames;
    for(;;) {
        AVFrame* raw=av_frame_alloc(); if(!raw) throw std::bad_alloc();
        DecodedFrame frame(raw,[](AVFrame* ptr){ av_frame_free(&ptr); });
        status=avcodec_receive_frame(s.decoder,raw);
        if(status==AVERROR(EAGAIN)) break;
        check(status);
        if(raw->format!=AV_PIX_FMT_CUDA || !raw->hw_frames_ctx) throw std::runtime_error("reverse color must stay on GPU");
        const auto* hw=reinterpret_cast<AVHWFramesContext*>(raw->hw_frames_ctx->data);
        if(hw->sw_format!=AV_PIX_FMT_NV12) throw std::runtime_error("reverse decoder requires NV12");
        frames.push_back(std::move(frame));
    }
    return frames;
}
void GpuDecoder::upload(const DecodedFrame& frame) {
    auto& s=*impl_; const auto* f=frame.get();
    if(!f || f->width<=0 || f->height<=0 || f->format!=AV_PIX_FMT_CUDA) throw std::runtime_error("invalid reverse GPU frame");
    const unsigned width=static_cast<unsigned>(f->width),height=static_cast<unsigned>(f->height);
    if(width!=s.width || height!=s.height) {
        s.release_textures(); s.width=width;s.height=height;
        glGenTextures(2,s.textures);
        CurrentCuda current(s.context);
        for(unsigned i=0;i<2;++i) {
            glBindTexture(GL_TEXTURE_2D,s.textures[i]);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
            glTexStorage2D(GL_TEXTURE_2D,1,i?GL_RG8:GL_R8,i?(width+1)/2:width,i?(height+1)/2:height);
            cuda_check(cuGraphicsGLRegisterImage(&s.resources[i],s.textures[i],GL_TEXTURE_2D,CU_GRAPHICS_REGISTER_FLAGS_WRITE_DISCARD));
        }
    }
    CurrentCuda current(s.context);
    cuda_check(cuGraphicsMapResources(2,s.resources,nullptr));
    try {
        for(unsigned i=0;i<2;++i) {
            CUarray array{};cuda_check(cuGraphicsSubResourceGetMappedArray(&array,s.resources[i],0,0));
            CUDA_MEMCPY2D copy{};copy.srcMemoryType=CU_MEMORYTYPE_DEVICE;
            copy.srcDevice=reinterpret_cast<CUdeviceptr>(f->data[i]);copy.srcPitch=f->linesize[i];
            copy.dstMemoryType=CU_MEMORYTYPE_ARRAY;copy.dstArray=array;
            copy.WidthInBytes=i?((width+1)/2)*2:width;copy.Height=i?(height+1)/2:height;
            cuda_check(cuMemcpy2D(&copy));
        }
    } catch(...) { cuGraphicsUnmapResources(2,s.resources,nullptr);throw; }
    cuda_check(cuGraphicsUnmapResources(2,s.resources,nullptr));
}
unsigned GpuDecoder::y_texture() const {return impl_->textures[0];}
unsigned GpuDecoder::uv_texture() const {return impl_->textures[1];}
}

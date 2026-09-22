#include "gpu_decoder.hpp"
#include <GLES3/gl3.h>
#include "../linux-media/device_selection.hpp"
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#ifdef VIEWFLOW_HAVE_CUDA
#include <cuda.h>
#include <cudaGL.h>
#endif
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_drm.h>
#ifdef VIEWFLOW_HAVE_CUDA
#include <libavutil/hwcontext_cuda.h>
#endif
}
#include <stdexcept>
#include <cstring>
#include <string>
#include <climits>
#include <cstdio>
#include <dlfcn.h>
namespace viewflow::reverse {
namespace {
void check(int value) {
    if(value>=0) return;
    char message[AV_ERROR_MAX_STRING_SIZE]{}; av_strerror(value,message,sizeof(message));
    throw std::runtime_error(std::string("reverse decoder: ")+message);
}
#ifdef VIEWFLOW_HAVE_CUDA
struct CudaApi {
    void* module=dlopen("libcuda.so.1",RTLD_NOW|RTLD_LOCAL);
    template<typename T> T symbol(const char* name) {
        if(!module) throw std::runtime_error("NVIDIA decoder requires libcuda.so.1");
        auto value=reinterpret_cast<T>(dlsym(module,name));
        if(!value) throw std::runtime_error(std::string("missing CUDA driver symbol: ")+name);
        return value;
    }
    decltype(&::cuGetErrorString) GetErrorString=symbol<decltype(&::cuGetErrorString)>("cuGetErrorString");
    decltype(&::cuCtxPushCurrent) CtxPushCurrent=symbol<decltype(&::cuCtxPushCurrent)>("cuCtxPushCurrent_v2");
    decltype(&::cuCtxPopCurrent) CtxPopCurrent=symbol<decltype(&::cuCtxPopCurrent)>("cuCtxPopCurrent_v2");
    decltype(&::cuGraphicsUnregisterResource) GraphicsUnregisterResource=symbol<decltype(&::cuGraphicsUnregisterResource)>("cuGraphicsUnregisterResource");
    decltype(&::cuInit) Init=symbol<decltype(&::cuInit)>("cuInit");
    decltype(&::cuGLGetDevices) GLGetDevices=symbol<decltype(&::cuGLGetDevices)>("cuGLGetDevices_v2");
    decltype(&::cuGraphicsGLRegisterImage) GraphicsGLRegisterImage=symbol<decltype(&::cuGraphicsGLRegisterImage)>("cuGraphicsGLRegisterImage");
    decltype(&::cuGraphicsMapResources) GraphicsMapResources=symbol<decltype(&::cuGraphicsMapResources)>("cuGraphicsMapResources");
    decltype(&::cuGraphicsSubResourceGetMappedArray) GraphicsSubResourceGetMappedArray=symbol<decltype(&::cuGraphicsSubResourceGetMappedArray)>("cuGraphicsSubResourceGetMappedArray");
    decltype(&::cuMemcpy2D) Memcpy2D=symbol<decltype(&::cuMemcpy2D)>("cuMemcpy2D_v2");
    decltype(&::cuGraphicsUnmapResources) GraphicsUnmapResources=symbol<decltype(&::cuGraphicsUnmapResources)>("cuGraphicsUnmapResources");
};
CudaApi& cudaApi() { static CudaApi api;return api; }
void cuda_check(CUresult value) {
    if(value==CUDA_SUCCESS) return;
    const char* message=nullptr; cudaApi().GetErrorString(value,&message);
    throw std::runtime_error(std::string("reverse GPU import: ")+(message?message:"unknown"));
}
struct CurrentCuda {
    explicit CurrentCuda(CUcontext context) { cuda_check(cudaApi().CtxPushCurrent(context)); }
    ~CurrentCuda() { CUcontext old{}; cudaApi().CtxPopCurrent(&old); }
};
#endif
AVPixelFormat format(AVCodecContext* context,const AVPixelFormat* candidates) {
    const auto wanted=*static_cast<AVPixelFormat*>(context->opaque);
    for(;*candidates!=AV_PIX_FMT_NONE;++candidates) if(*candidates==wanted) return *candidates;
    return AV_PIX_FMT_NONE;
}
}
struct GpuDecoder::Impl {
    AVCodecContext* decoder{};
    AVBufferRef* device{};
    AVPixelFormat pixelFormat=AV_PIX_FMT_VAAPI;
    DecodedFrame imported;
#ifdef VIEWFLOW_HAVE_CUDA
    CUcontext context{};
    CUgraphicsResource resources[2]{};
#endif
    GLuint textures[2]{};
    unsigned width{},height{};
    void release_textures() noexcept {
        // Complete sampling before returning an imported VA surface to its pool.
        if(imported) { glFinish(); imported.reset(); }
#ifdef VIEWFLOW_HAVE_CUDA
        CUcontext old{};
        if(context) cudaApi().CtxPushCurrent(context);
        for(auto& resource:resources) { if(resource) cudaApi().GraphicsUnregisterResource(resource); resource=nullptr; }
        if(context) cudaApi().CtxPopCurrent(&old);
#endif
        glDeleteTextures(2,textures); textures[0]=textures[1]=0;
    }
    ~Impl() { release_textures(); avcodec_free_context(&decoder); av_buffer_unref(&device); }
};
GpuDecoder::GpuDecoder():impl_(std::make_unique<Impl>()) {}
GpuDecoder::~GpuDecoder()=default;
void GpuDecoder::start(unsigned codec_id) {
    auto& s=*impl_;
    if(s.decoder) throw std::runtime_error("reverse decoder already started");
    const auto selected=media::selection();
    if(selected.vaapi) {
        check(av_hwdevice_ctx_create(&s.device,AV_HWDEVICE_TYPE_VAAPI,selected.renderNode.c_str(),nullptr,0));
    } else {
#ifdef VIEWFLOW_HAVE_CUDA
        s.pixelFormat=AV_PIX_FMT_CUDA;
        cuda_check(cudaApi().Init(0));
        CUdevice gpu{}; unsigned count{};
        cuda_check(cudaApi().GLGetDevices(&count,&gpu,1,CU_GL_DEVICE_LIST_CURRENT_FRAME));
        if(!count) throw std::runtime_error("EGL renderer has no CUDA device");
        const std::string ordinal=std::to_string(gpu);
        check(av_hwdevice_ctx_create(&s.device,AV_HWDEVICE_TYPE_CUDA,ordinal.c_str(),nullptr,AV_CUDA_USE_PRIMARY_CONTEXT));
        auto* hw=reinterpret_cast<AVHWDeviceContext*>(s.device->data);
        s.context=static_cast<AVCUDADeviceContext*>(hw->hwctx)->cuda_ctx;
#else
        throw std::runtime_error("NVIDIA decoding was not compiled into this build");
#endif
    }
    if(codec_id!=1 && codec_id!=2) throw std::runtime_error("unsupported reverse codec");
    const AVCodec* codec=avcodec_find_decoder(codec_id==2?AV_CODEC_ID_HEVC:AV_CODEC_ID_H264);
    if(!codec) throw std::runtime_error("H264 decoder unavailable");
    s.decoder=avcodec_alloc_context3(codec);
    if(!s.decoder) throw std::bad_alloc();
    s.decoder->hw_device_ctx=av_buffer_ref(s.device);
    if(!s.decoder->hw_device_ctx) throw std::bad_alloc();
    s.decoder->opaque=&s.pixelFormat;
    s.decoder->get_format=format; s.decoder->thread_count=1;
    s.decoder->pkt_timebase={1,10000000}; s.decoder->flags|=AV_CODEC_FLAG_LOW_DELAY;
    s.decoder->extra_hw_frames=4;
    check(avcodec_open2(s.decoder,codec,nullptr));
    std::fprintf(stderr,"Viewflow decoder backend=%s device=%s codec=%u initialization=ok\n",selected.vaapi?"vaapi":"nvidia",selected.renderNode.c_str(),codec_id);
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
        if(raw->format!=s.pixelFormat || !raw->hw_frames_ctx) throw std::runtime_error("reverse color must stay on GPU");
        const auto* hw=reinterpret_cast<AVHWFramesContext*>(raw->hw_frames_ctx->data);
        if(hw->sw_format!=AV_PIX_FMT_NV12) throw std::runtime_error("reverse decoder requires NV12");
        frames.push_back(std::move(frame));
    }
    return frames;
}
void GpuDecoder::upload(const DecodedFrame& frame) {
    auto& s=*impl_; const auto* f=frame.get();
    if(!f || f->width<=0 || f->height<=0 || f->format!=s.pixelFormat) throw std::runtime_error("invalid reverse GPU frame");
    if(s.pixelFormat==AV_PIX_FMT_VAAPI) {
        auto raw=av_frame_alloc(); if(!raw) throw std::bad_alloc();
        DecodedFrame mapped(raw,[](AVFrame* ptr){ av_frame_free(&ptr); });
        raw->format=AV_PIX_FMT_DRM_PRIME;
        check(av_hwframe_map(raw,f,AV_HWFRAME_MAP_READ));
        const auto* desc=reinterpret_cast<const AVDRMFrameDescriptor*>(raw->data[0]);
        // VA exports separate R8/GR88 layers. Some drivers export one NV12 layer.
        const bool separate=desc && desc->nb_layers==2 && desc->layers[0].format==DRM_FORMAT_R8 &&
            (desc->layers[1].format==DRM_FORMAT_GR88 || desc->layers[1].format==DRM_FORMAT_RG88) && desc->layers[0].nb_planes>=1 && desc->layers[0].nb_planes<=4 &&
            desc->layers[1].nb_planes>=1 && desc->layers[1].nb_planes<=4;
        const bool combined=desc && desc->nb_layers==1 && desc->layers[0].format==DRM_FORMAT_NV12 && desc->layers[0].nb_planes==2;
        if(!separate && !combined) {
            std::string layout="VA-API exported an unsupported DRM NV12 layout";
            if(desc) for(int i=0;i<std::min(desc->nb_layers,4);++i)
                layout+=" layer="+std::to_string(i)+" format="+std::to_string(desc->layers[i].format)+" planes="+std::to_string(desc->layers[i].nb_planes);
            throw std::runtime_error(layout);
        }
        auto create=reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
        auto destroy=reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
        auto bind=reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
        if(!create || !destroy || !bind) throw std::runtime_error("EGL DMA-BUF import unavailable");
        s.release_textures();
        glGenTextures(2,s.textures);
        // Retain the mapping even on an import error; no recycled surface may be sampled.
        s.imported=std::move(mapped);
        for(unsigned i=0;i<2;++i) {
            std::vector<EGLint> attrs={EGL_WIDTH,i?(f->width+1)/2:f->width,EGL_HEIGHT,i?(f->height+1)/2:f->height,
                EGL_LINUX_DRM_FOURCC_EXT,static_cast<EGLint>(separate?desc->layers[i].format:(i?DRM_FORMAT_GR88:DRM_FORMAT_R8))};
            // Preserve auxiliary planes used by tiled/compressed Intel/AMD surfaces.
            constexpr EGLint fds[]={EGL_DMA_BUF_PLANE0_FD_EXT,EGL_DMA_BUF_PLANE1_FD_EXT,EGL_DMA_BUF_PLANE2_FD_EXT,EGL_DMA_BUF_PLANE3_FD_EXT};
            constexpr EGLint offsets[]={EGL_DMA_BUF_PLANE0_OFFSET_EXT,EGL_DMA_BUF_PLANE1_OFFSET_EXT,EGL_DMA_BUF_PLANE2_OFFSET_EXT,EGL_DMA_BUF_PLANE3_OFFSET_EXT};
            constexpr EGLint pitches[]={EGL_DMA_BUF_PLANE0_PITCH_EXT,EGL_DMA_BUF_PLANE1_PITCH_EXT,EGL_DMA_BUF_PLANE2_PITCH_EXT,EGL_DMA_BUF_PLANE3_PITCH_EXT};
            constexpr EGLint lows[]={EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT,EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT};
            constexpr EGLint highs[]={EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT,EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT};
            for(int j=0;j<(separate?desc->layers[i].nb_planes:1);++j) {
                const auto& plane=separate?desc->layers[i].planes[j]:desc->layers[0].planes[i];
                if(desc->nb_objects<1 || desc->nb_objects>AV_DRM_MAX_PLANES || plane.object_index<0 || plane.object_index>=desc->nb_objects ||
                    plane.pitch<=0 || plane.pitch>INT_MAX || plane.offset<0 || plane.offset>INT_MAX)
                    throw std::runtime_error("invalid VA-API DRM plane");
                const auto& object=desc->objects[plane.object_index];
                attrs.insert(attrs.end(),{fds[j],object.fd,offsets[j],static_cast<EGLint>(plane.offset),pitches[j],static_cast<EGLint>(plane.pitch)});
                if(object.format_modifier!=DRM_FORMAT_MOD_INVALID) {
                    attrs.insert(attrs.end(),{lows[j],static_cast<EGLint>(object.format_modifier),highs[j],static_cast<EGLint>(object.format_modifier>>32)});
                }
            }
            attrs.push_back(EGL_NONE);
            const auto display=eglGetCurrentDisplay();
            const auto image=create(display,EGL_NO_CONTEXT,EGL_LINUX_DMA_BUF_EXT,nullptr,attrs.data());
            if(image==EGL_NO_IMAGE_KHR) throw std::runtime_error("VA-API DRM plane import failed on the current EGL device");
            glBindTexture(GL_TEXTURE_2D,s.textures[i]);
            bind(GL_TEXTURE_2D,image);
            destroy(display,image);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
            if(i && separate && desc->layers[i].format==DRM_FORMAT_RG88) {
                // NVIDIA EGL accepts the exported RG88 plane but exposes its
                // NV12 bytes in sampler RG order (verified with a red fixture).
                // Other EGL implementations follow the fourcc channel order.
                const auto* vendor=reinterpret_cast<const char*>(glGetString(GL_VENDOR));
                if(!vendor || std::string(vendor).find("NVIDIA")==std::string::npos) {
                    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_SWIZZLE_R,GL_GREEN);
                    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_SWIZZLE_G,GL_RED);
                }
            }
            if(glGetError()!=GL_NO_ERROR) throw std::runtime_error("VA-API EGL texture binding failed");
        }
        return;
    }
#ifdef VIEWFLOW_HAVE_CUDA
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
            cuda_check(cudaApi().GraphicsGLRegisterImage(&s.resources[i],s.textures[i],GL_TEXTURE_2D,CU_GRAPHICS_REGISTER_FLAGS_WRITE_DISCARD));
        }
    }
    CurrentCuda current(s.context);
    cuda_check(cudaApi().GraphicsMapResources(2,s.resources,nullptr));
    try {
        for(unsigned i=0;i<2;++i) {
            CUarray array{};cuda_check(cudaApi().GraphicsSubResourceGetMappedArray(&array,s.resources[i],0,0));
            CUDA_MEMCPY2D copy{};copy.srcMemoryType=CU_MEMORYTYPE_DEVICE;
            copy.srcDevice=reinterpret_cast<CUdeviceptr>(f->data[i]);copy.srcPitch=f->linesize[i];
            copy.dstMemoryType=CU_MEMORYTYPE_ARRAY;copy.dstArray=array;
            copy.WidthInBytes=i?((width+1)/2)*2:width;copy.Height=i?(height+1)/2:height;
            cuda_check(cudaApi().Memcpy2D(&copy));
        }
    } catch(...) { cudaApi().GraphicsUnmapResources(2,s.resources,nullptr);throw; }
    cuda_check(cudaApi().GraphicsUnmapResources(2,s.resources,nullptr));
#endif
}
unsigned GpuDecoder::y_texture() const {return impl_->textures[0];}
unsigned GpuDecoder::uv_texture() const {return impl_->textures[1];}
}

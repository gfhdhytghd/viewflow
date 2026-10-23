#include <unistd.h>
#include <cerrno>
#include "../reverse-common/diagnostics.hpp"
#include "gpu_decoder.hpp"
#include "raw_dmabuf_upload.hpp"
#include "../reverse-common/wire.hpp"
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
#include <cstdlib>
#include <chrono>
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
    decltype(&::cuMemHostRegister) MemHostRegister=symbol<decltype(&::cuMemHostRegister)>("cuMemHostRegister_v2");
    decltype(&::cuMemHostUnregister) MemHostUnregister=symbol<decltype(&::cuMemHostUnregister)>("cuMemHostUnregister");
    decltype(&::cuMemcpy2D) Memcpy2D=symbol<decltype(&::cuMemcpy2D)>("cuMemcpy2D_v2");
    decltype(&::cuMemcpy2DAsync) Memcpy2DAsync=symbol<decltype(&::cuMemcpy2DAsync)>("cuMemcpy2DAsync_v2");
    decltype(&::cuStreamCreate) StreamCreate=symbol<decltype(&::cuStreamCreate)>("cuStreamCreate");
    decltype(&::cuStreamSynchronize) StreamSynchronize=symbol<decltype(&::cuStreamSynchronize)>("cuStreamSynchronize");
    decltype(&::cuStreamDestroy) StreamDestroy=symbol<decltype(&::cuStreamDestroy)>("cuStreamDestroy_v2");
    decltype(&::cuEventCreate) EventCreate=symbol<decltype(&::cuEventCreate)>("cuEventCreate");
    decltype(&::cuEventRecord) EventRecord=symbol<decltype(&::cuEventRecord)>("cuEventRecord");
    decltype(&::cuLaunchHostFunc) LaunchHostFunc=reinterpret_cast<decltype(&::cuLaunchHostFunc)>(dlsym(module,"cuLaunchHostFunc"));
    decltype(&::cuEventQuery) EventQuery=symbol<decltype(&::cuEventQuery)>("cuEventQuery");
    decltype(&::cuEventDestroy) EventDestroy=symbol<decltype(&::cuEventDestroy)>("cuEventDestroy_v2");
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
// Rendering-thread cache shared by active/spare decoders and activity lanes.
// Each in-flight upload keeps its own registration reference through DMA drain.
struct RawUploadCache {
#ifdef VIEWFLOW_HAVE_CUDA
    struct Pin {
        void* data{};std::size_t size{};std::shared_ptr<void> mapping;
        CUcontext context{};AVBufferRef* device{};bool registered{};
        ~Pin(){
            if(registered){CUcontext old{};cudaApi().CtxPushCurrent(context);cudaApi().MemHostUnregister(data);cudaApi().CtxPopCurrent(&old);}
            av_buffer_unref(&device);
        }
    };
    std::vector<std::shared_ptr<Pin>> pins;
    AVBufferRef* upload_device{};
    ~RawUploadCache(){pins.clear();av_buffer_unref(&upload_device);}
    AVBufferRef* device(){
        if(!upload_device){
            cuda_check(cudaApi().Init(0));CUdevice gpu{};unsigned count{};
            cuda_check(cudaApi().GLGetDevices(&count,&gpu,1,CU_GL_DEVICE_LIST_CURRENT_FRAME));
            if(!count)throw std::runtime_error("raw upload has no matching CUDA device");
            const auto name=std::to_string(gpu);
            check(av_hwdevice_ctx_create(&upload_device,AV_HWDEVICE_TYPE_CUDA,name.c_str(),nullptr,0));
        }
        return upload_device;
    }
    std::shared_ptr<Pin> acquire(void* data,std::size_t size,std::shared_ptr<void> mapping,CUcontext context,AVBufferRef* device){
        auto found=std::find_if(pins.begin(),pins.end(),[&](const auto& pin){return pin->data==data;});
        if(found!=pins.end()){
            if((*found)->size>=size)return *found;
            if(found->use_count()!=1)throw std::runtime_error("host registration resize while DMA active");
            pins.erase(found);
        }
        if(pins.size()>=4){
            auto idle=std::find_if(pins.begin(),pins.end(),[](const auto& pin){return pin.use_count()==1;});
            if(idle==pins.end())throw std::runtime_error("host registration cache busy");
            pins.erase(idle);
        }
        auto pin=std::make_shared<Pin>();pin->data=data;pin->size=size;pin->mapping=std::move(mapping);pin->context=context;
        pin->device=av_buffer_ref(device);if(!pin->device)throw std::bad_alloc();
        cuda_check(cudaApi().MemHostRegister(data,size,CU_MEMHOSTREGISTER_PORTABLE));pin->registered=true;
        pins.push_back(pin);return pin;
    }
#endif
};
struct GpuDecoder::Impl {
    AVCodecContext* decoder{};
    AVBufferRef* device{};
    AVBufferRef* upload_device{};
    AVPixelFormat pixelFormat=AV_PIX_FMT_VAAPI;
    DecodedFrame imported;
#ifdef VIEWFLOW_HAVE_CUDA
    CUcontext context{};
    CUgraphicsResource resources[2]{};
    const unsigned prefix_trace_stride=[] {
        const auto* value=std::getenv("VIEWFLOW_PROGRESSIVE_PREFIX_TRACE");
        return value && std::string_view(value)=="1"?1u:value && std::string_view(value)=="16"?16u:0u;
    }();
    unsigned prefix_trace_counter{};
    struct Progressive {
        std::shared_ptr<shm::ProgressiveStorage::Read> lease;
        GLuint texture{};CUgraphicsResource resource{};CUarray array{};
        CUstream stream{};CUevent done{},prefix_done{};bool prefix_pending{},trace_prefix{};unsigned prefix_rows{};void* pinned{};
        std::shared_ptr<RawUploadCache::Pin> registration;
        unsigned rows{},width{},height{};bool mapped{},finishing{},host_ready{};
        std::chrono::steady_clock::time_point started{},ready{},finished_submission{};
        double pin_ms{},submit_ms{};unsigned submissions{};
        int completion_fd=-1;std::int64_t trace_pts{};
    } progressive;
    void cancel_progressive(bool destroy=false) noexcept {
        auto& p=progressive;
        if(!p.lease && !destroy)return;
        if(!context)return;
        CUcontext old{};cudaApi().CtxPushCurrent(context);
        if(p.stream)cudaApi().StreamSynchronize(p.stream);
        if(p.mapped){
            cudaApi().GraphicsUnmapResources(1,&p.resource,p.stream);
            if(p.stream)cudaApi().StreamSynchronize(p.stream);
        }
        // A completed upload already unmapped before recording its event.
        // The first synchronization drains its optional host notification;
        // a second wait is needed only after the cancellation unmap above.
        if(p.pinned)cudaApi().MemHostUnregister(p.pinned);
        if(destroy){
            if(p.resource)cudaApi().GraphicsUnregisterResource(p.resource);
            if(p.done)cudaApi().EventDestroy(p.done);
            if(p.prefix_done)cudaApi().EventDestroy(p.prefix_done);
            if(p.stream)cudaApi().StreamDestroy(p.stream);
        }
        cudaApi().CtxPopCurrent(&old);
        if(destroy){if(p.texture)glDeleteTextures(1,&p.texture);p={};}
        else {
            // Keep the idle spare texture and synchronization objects reusable.
            p.registration.reset();p.lease.reset();p.array=nullptr;p.pinned=nullptr;p.rows=0;
            p.mapped=p.finishing=p.host_ready=false;p.prefix_pending=false;p.prefix_rows=0;
            p.pin_ms=p.submit_ms=0;p.submissions=0;
        }
    }
    std::shared_ptr<RawUploadCache> upload_cache=std::make_shared<RawUploadCache>();
#endif
    RawDmaBufUpload raw_dma;
    bool raw_dma_disabled{},last_raw_dma{},raw_dma_reported{};
    GLuint textures[2]{};
    unsigned width{},height{};bool raw_textures{},raw_cuda_disabled{};
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
    ~Impl() {
        raw_dma.drain();
#ifdef VIEWFLOW_HAVE_CUDA
        cancel_progressive(true);upload_cache.reset();
#endif
        release_textures(); avcodec_free_context(&decoder); av_buffer_unref(&device); av_buffer_unref(&upload_device); }
};
std::shared_ptr<RawUploadCache> GpuDecoder::make_upload_cache(){return std::make_shared<RawUploadCache>();}
GpuDecoder::GpuDecoder(std::shared_ptr<RawUploadCache> cache):impl_(std::make_unique<Impl>()) {
#ifdef VIEWFLOW_HAVE_CUDA
    if(cache)impl_->upload_cache=std::move(cache);
#else
    (void)cache;
#endif
}
GpuDecoder::~GpuDecoder()=default;
void GpuDecoder::start(unsigned codec_id) {
    auto& s=*impl_;
    if(s.decoder) throw std::runtime_error("reverse decoder already started");
    if(codec_id==3)return; // IVSHMEM BGRA needs no codec or hardware decode device.
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
DecodedFrame GpuDecoder::raw_bgra(std::shared_ptr<std::vector<std::uint8_t>> bytes,unsigned width,unsigned height,std::int64_t pts) {
    auto view=std::make_shared<SharedPixels>();if(bytes){view->bytes=*bytes;view->owner=std::move(bytes);}
    return raw_bgra(std::move(view),width,height,pts);
}
DecodedFrame GpuDecoder::raw_bgra(std::shared_ptr<SharedPixels> bytes,unsigned width,unsigned height,std::int64_t pts) {
    if(!bytes || !width || !height || width>shared_max_dimension || height>shared_max_dimension || bytes->size()!=std::size_t(width)*height*4)throw std::runtime_error("invalid shared BGRA extent");
    auto* raw=av_frame_alloc();if(!raw)throw std::bad_alloc();
    DecodedFrame frame(raw,[](AVFrame* ptr){av_frame_free(&ptr);});
    auto owner=std::make_unique<std::shared_ptr<SharedPixels>>(std::move(bytes));
    raw->buf[0]=av_buffer_create((*owner)->data(),(*owner)->size(),[](void* opaque,std::uint8_t*){delete static_cast<std::shared_ptr<SharedPixels>*>(opaque);},owner.get(),AV_BUFFER_FLAG_READONLY);
    if(!raw->buf[0])throw std::bad_alloc();
    raw->opaque=owner.get();owner.release();raw->data[0]=raw->buf[0]->data;raw->linesize[0]=width*4;
    raw->format=AV_PIX_FMT_BGRA;raw->width=width;raw->height=height;raw->pts=pts;return frame;
}
std::size_t GpuDecoder::poll_raw_dma(){return impl_->raw_dma.poll();}
std::size_t GpuDecoder::raw_dma_pending() const{return impl_->raw_dma.pending();}
bool GpuDecoder::last_upload_raw_dma() const{return impl_->last_raw_dma;}
void GpuDecoder::upload(const DecodedFrame& frame) {
    cancel_progressive();
    auto& s=*impl_; const auto* f=frame.get();
    s.raw_dma.poll();s.last_raw_dma=false;
    if(f && f->format==AV_PIX_FMT_BGRA) {
        if(f->width<=0 || f->height<=0 || f->linesize[0]!=f->width*4)throw std::runtime_error("invalid shared BGRA upload");
        const auto width=static_cast<unsigned>(f->width),height=static_cast<unsigned>(f->height);
        GLint max_texture{};glGetIntegerv(GL_MAX_TEXTURE_SIZE,&max_texture);
        if(width>unsigned(max_texture) || height>unsigned(max_texture))throw std::runtime_error("shared BGRA exceeds receiver GPU texture limit");
        if(!s.raw_textures){s.release_textures();s.width=s.height=0;s.raw_textures=true;}
        glActiveTexture(GL_TEXTURE0);
        if(width!=s.width || height!=s.height || !s.textures[0]) {
            s.release_textures();s.width=width;s.height=height;glGenTextures(1,s.textures);
            glBindTexture(GL_TEXTURE_2D,s.textures[0]);
            glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,width,height);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_SWIZZLE_R,GL_BLUE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_SWIZZLE_B,GL_RED);
        }
        const auto* shared=static_cast<const std::shared_ptr<SharedPixels>*>(f->opaque);
        const char* dma_mode=std::getenv("VIEWFLOW_RAW_DMABUF");
        if(dma_mode && std::string_view(dma_mode)=="1" && shared && *shared &&
           (*shared)->dma_buffer && !s.raw_dma_disabled){
            try{
                s.raw_dma.upload(*shared,s.textures[0],width,height);
                s.last_raw_dma=true;
                if(!s.raw_dma_reported){std::fprintf(stderr,"raw DMA-BUF upload selected=external-OES width=%u height=%u source=shared-bank snapshot=GPU-local lease=GPU-fence\n",width,height);s.raw_dma_reported=true;}
                return;
            }catch(const std::exception& error){
                // This frame keeps its CPU view. Unsupported import is a local
                // transport fallback, never a session or proxy failure.
                std::fprintf(stderr,"raw DMA-BUF upload fallback=existing reason=%s\n",error.what());
                s.raw_dma_disabled=true;
            }
        }
#ifdef VIEWFLOW_HAVE_CUDA
        // Opt-in measurement path; retain the portable GL upload by default.
        if(const auto* mode=std::getenv("VIEWFLOW_RAW_CUDA");mode && *mode && !s.raw_cuda_disabled) {
          try {
            if(!s.upload_device){
                s.upload_device=av_buffer_ref(s.upload_cache->device());if(!s.upload_device)throw std::bad_alloc();
                s.context=static_cast<AVCUDADeviceContext*>(reinterpret_cast<AVHWDeviceContext*>(s.upload_device->data)->hwctx)->cuda_ctx;
            }
            CurrentCuda current(s.context);
            if(!s.resources[0])cuda_check(cudaApi().GraphicsGLRegisterImage(&s.resources[0],s.textures[0],GL_TEXTURE_2D,CU_GRAPHICS_REGISTER_FLAGS_WRITE_DISCARD));
            const auto* owner=static_cast<const std::shared_ptr<SharedPixels>*>(f->opaque);
            const bool persistent=std::string(mode)=="persistent" && owner && (*owner)->storage_owner;
            std::shared_ptr<RawUploadCache::Pin> registration;
            if(persistent)registration=s.upload_cache->acquire(f->data[0],std::size_t(width)*height*4,(*owner)->storage_owner,s.context,s.upload_device);
            const bool pin=std::string(mode)=="pinned";
            if(pin)cuda_check(cudaApi().MemHostRegister(f->data[0],std::size_t(width)*height*4,0));
            bool mapped=false;
            const bool trace_upload=std::getenv("VIEWFLOW_CUDA_UPLOAD_TRACE")!=nullptr;
            using UploadClock=std::chrono::steady_clock;
            const auto upload_now=[&]{return trace_upload?UploadClock::now():UploadClock::time_point{};};
            try {
                const auto map_begin=upload_now();
                cuda_check(cudaApi().GraphicsMapResources(1,s.resources,nullptr));mapped=true;
                const auto map_end=upload_now();
                CUarray array{};cuda_check(cudaApi().GraphicsSubResourceGetMappedArray(&array,s.resources[0],0,0));
                CUDA_MEMCPY2D copy{};copy.srcMemoryType=CU_MEMORYTYPE_HOST;copy.srcHost=f->data[0];copy.srcPitch=width*4;
                copy.dstMemoryType=CU_MEMORYTYPE_ARRAY;copy.dstArray=array;copy.WidthInBytes=width*4;copy.Height=height;
                const auto copy_begin=upload_now();
                cuda_check(cudaApi().Memcpy2D(&copy));
                const auto copy_end=upload_now();
                cuda_check(cudaApi().GraphicsUnmapResources(1,s.resources,nullptr));mapped=false;
                const auto unmap_end=upload_now();
                if(trace_upload) {
                    const auto ms=[](auto a,auto b){return std::chrono::duration<double,std::milli>(b-a).count();};
                    std::fprintf(stderr,"ivshmem-cuda-upload pts=%lld width=%u height=%u map_ms=%.3f array_ms=%.3f copy_ms=%.3f unmap_ms=%.3f scope=CPU-wall-not-GPU-execution\n",static_cast<long long>(f->pts),width,height,ms(map_begin,map_end),ms(map_end,copy_begin),ms(copy_begin,copy_end),ms(copy_end,unmap_end));
                }
            }catch(...) {if(mapped)cudaApi().GraphicsUnmapResources(1,s.resources,nullptr);if(pin)cudaApi().MemHostUnregister(f->data[0]);throw;}
            if(pin)cuda_check(cudaApi().MemHostUnregister(f->data[0]));
            return;
          }catch(const std::exception& error) {
            std::fprintf(stderr,"raw CUDA upload fallback=GL reason=%s\n",error.what());
            s.raw_cuda_disabled=true;s.release_textures();s.width=s.height=0;
            upload(frame);return;
          }
        }
#endif
        glBindTexture(GL_TEXTURE_2D,s.textures[0]);glPixelStorei(GL_UNPACK_ALIGNMENT,4);
        glTexSubImage2D(GL_TEXTURE_2D,0,0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,f->data[0]);
        if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("shared BGRA texture upload failed");
        return;
    }
    if(!f || f->width<=0 || f->height<=0 || !f->hw_frames_ctx || (f->format!=AV_PIX_FMT_VAAPI && f->format!=AV_PIX_FMT_CUDA)) throw std::runtime_error("invalid reverse GPU frame");
    if(s.raw_textures){s.release_textures();s.width=s.height=0;s.raw_textures=false;}
    if(f->format==AV_PIX_FMT_VAAPI) {
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
    const auto* hw_frames=reinterpret_cast<const AVHWFramesContext*>(f->hw_frames_ctx->data);
    const auto frame_context=static_cast<AVCUDADeviceContext*>(hw_frames->device_ctx->hwctx)->cuda_ctx;
    if(s.context!=frame_context){s.release_textures();s.width=s.height=0;auto* retained=av_buffer_ref(hw_frames->device_ref);if(!retained)throw std::bad_alloc();av_buffer_unref(&s.upload_device);s.upload_device=retained;s.context=frame_context;}
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
void GpuDecoder::prepare_upload(const std::shared_ptr<RawUploadCache>& cache){
#ifdef VIEWFLOW_HAVE_CUDA
    if(!cache)throw std::runtime_error("missing upload cache");
    cache->device();
#else
    (void)cache;throw std::runtime_error("CUDA upload unavailable");
#endif
}
bool GpuDecoder::progressive_available(){
#ifdef VIEWFLOW_HAVE_CUDA
    try{cuda_check(cudaApi().Init(0));CUdevice device{};unsigned count{};
        cuda_check(cudaApi().GLGetDevices(&count,&device,1,CU_GL_DEVICE_LIST_CURRENT_FRAME));return count!=0;
    }catch(...){return false;}
#else
    return false;
#endif
}
void GpuDecoder::cancel_progressive() {
#ifdef VIEWFLOW_HAVE_CUDA
    impl_->cancel_progressive();
#endif
}
void GpuDecoder::begin_progressive(std::shared_ptr<shm::ProgressiveStorage::Read> lease, int completion_fd, std::int64_t trace_pts) {
#ifdef VIEWFLOW_HAVE_CUDA
    auto& s=*impl_;
    if(!lease)throw std::runtime_error("missing progressive lease");
    if(s.progressive.lease)throw std::runtime_error("progressive upload already active");
    const auto started=std::chrono::steady_clock::now();
    const auto ref=lease->identity();
    GLint limit{};glGetIntegerv(GL_MAX_TEXTURE_SIZE,&limit);
    if(ref.width>unsigned(limit) || ref.height>unsigned(limit))throw std::runtime_error("progressive texture limit");
    if(!s.upload_device){
        s.upload_device=av_buffer_ref(s.upload_cache->device());if(!s.upload_device)throw std::bad_alloc();
        s.context=static_cast<AVCUDADeviceContext*>(reinterpret_cast<AVHWDeviceContext*>(s.upload_device->data)->hwctx)->cuda_ctx;
    }
    auto& p=s.progressive;
    if(p.texture && (p.width!=ref.width || p.height!=ref.height))s.cancel_progressive(true);
    p.completion_fd=completion_fd;p.trace_pts=trace_pts;
    p.trace_prefix=s.prefix_trace_stride && (s.prefix_trace_counter++%s.prefix_trace_stride==0);
    p.lease=std::move(lease);p.width=ref.width;p.height=ref.height;p.started=started;
    try {
        CurrentCuda current(s.context);
        if(!p.texture){
        glGenTextures(1,&p.texture);glBindTexture(GL_TEXTURE_2D,p.texture);
        glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,p.width,p.height);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_SWIZZLE_R,GL_BLUE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_SWIZZLE_B,GL_RED);
        if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("progressive texture allocation");
        }
        if(!p.stream)cuda_check(cudaApi().StreamCreate(&p.stream,CU_STREAM_NON_BLOCKING));
        if(!p.done)cuda_check(cudaApi().EventCreate(&p.done,CU_EVENT_DISABLE_TIMING));
        if(!p.prefix_done && p.trace_prefix)cuda_check(cudaApi().EventCreate(&p.prefix_done,CU_EVENT_DISABLE_TIMING));
        if(!p.resource)cuda_check(cudaApi().GraphicsGLRegisterImage(&p.resource,p.texture,GL_TEXTURE_2D,CU_GRAPHICS_REGISTER_FLAGS_WRITE_DISCARD));
        cuda_check(cudaApi().GraphicsMapResources(1,&p.resource,p.stream));p.mapped=true;
        cuda_check(cudaApi().GraphicsSubResourceGetMappedArray(&p.array,p.resource,0,0));
        p.ready=std::chrono::steady_clock::now();
    }catch(...){s.cancel_progressive(true);throw;}
#else
    (void)lease;(void)completion_fd;(void)trace_pts;throw std::runtime_error("progressive CUDA upload unavailable");
#endif
}
GpuDecoder::ProgressiveStatus GpuDecoder::poll_progressive() {
#ifdef VIEWFLOW_HAVE_CUDA
    auto& s=*impl_;auto& p=s.progressive;
    if(!p.lease)throw std::runtime_error("no progressive upload");
    if(p.lease->aborted()){s.cancel_progressive();return ProgressiveStatus::aborted;}
    try {
        CurrentCuda current(s.context);
        if(p.prefix_pending){
            const auto ready=cudaApi().EventQuery(p.prefix_done);
            if(ready!=CUDA_ERROR_NOT_READY){
                cuda_check(ready);p.prefix_pending=false;
                const auto observed=std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
                vf_diag::trace("progressive-prefix-complete pts=%lld row_end=%u observed_monotonic_ns=%lld scope=CPU-observed-GPU-event-upper-bound\n",static_cast<long long>(p.trace_pts),p.prefix_rows,static_cast<long long>(observed));
            }
        }
        if(!p.finishing){
            const auto prefix=p.lease->prefix();const auto row_bytes=std::size_t(p.width)*4;
            const auto rows=unsigned(prefix.size()/row_bytes);
            if(rows>p.rows){
                if(!p.host_ready){
                    const auto pin_begin=std::chrono::steady_clock::now();
                    auto* data=const_cast<std::uint8_t*>(prefix.data());const auto bytes=row_bytes*p.height;
                    auto owner=p.lease->storage_owner();
                    if(owner)p.registration=s.upload_cache->acquire(data,bytes,std::move(owner),s.context,s.upload_device);
                    else{cuda_check(cudaApi().MemHostRegister(data,bytes,0));p.pinned=data;}
                    p.host_ready=true;p.pin_ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-pin_begin).count();
                }
                CUDA_MEMCPY2D copy{};copy.srcMemoryType=CU_MEMORYTYPE_HOST;
                copy.srcHost=prefix.data()+p.rows*row_bytes;copy.srcPitch=row_bytes;
                copy.dstMemoryType=CU_MEMORYTYPE_ARRAY;copy.dstArray=p.array;copy.dstY=p.rows;
                copy.WidthInBytes=row_bytes;copy.Height=rows-p.rows;
                const auto submit_begin=std::chrono::steady_clock::now();
                cuda_check(cudaApi().Memcpy2DAsync(&copy,p.stream));
                const auto submitted=std::chrono::steady_clock::now();
                if(p.trace_prefix && p.prefix_done && p.rows==0 && rows<p.height){
                    cuda_check(cudaApi().EventRecord(p.prefix_done,p.stream));p.prefix_pending=true;p.prefix_rows=rows;
                }
                p.submit_ms+=std::chrono::duration<double,std::milli>(submitted-submit_begin).count();
                if(std::getenv("VIEWFLOW_PROGRESSIVE_UPLOAD_TRACE")){
                    const auto end=submitted;
                    vf_diag::trace("progressive-submit pts=%lld row_begin=%u row_end=%u begin_monotonic_ns=%lld end_monotonic_ns=%lld scope=CPU-enqueue-not-DMA-completion\n",static_cast<long long>(p.trace_pts),p.rows,rows,static_cast<long long>(std::chrono::duration_cast<std::chrono::nanoseconds>(submit_begin.time_since_epoch()).count()),static_cast<long long>(std::chrono::duration_cast<std::chrono::nanoseconds>(end.time_since_epoch()).count()));
                }
                p.rows=rows;++p.submissions;
            }
            if(p.rows!=p.height || !p.lease->complete())return ProgressiveStatus::pending;
            cuda_check(cudaApi().GraphicsUnmapResources(1,&p.resource,p.stream));p.mapped=false;
            cuda_check(cudaApi().EventRecord(p.done,p.stream));p.finishing=true;p.finished_submission=std::chrono::steady_clock::now();
            if(p.completion_fd>=0 && cudaApi().LaunchHostFunc){
                // Notification only: CUDA APIs and ownership changes remain on
                // the rendering thread. cancel_progressive drains this callback
                // before reusing its storage; App closes eventfd after decoders.
                const auto result=cudaApi().LaunchHostFunc(p.stream,[](void* data){
                    const int fd=*static_cast<const int*>(data);const std::uint64_t one=1;
                    while(::write(fd,&one,sizeof(one))<0 && errno==EINTR){}
                },&p.completion_fd);
                if(result!=CUDA_SUCCESS)vf_diag::trace("progressive-notify fallback=poll cuda_result=%d\n",int(result));
            }
        }
        const auto status=cudaApi().EventQuery(p.done);
        if(status==CUDA_ERROR_NOT_READY)return ProgressiveStatus::pending;
        cuda_check(status);
        if(std::getenv("VIEWFLOW_PROGRESSIVE_UPLOAD_TRACE")) {
            const auto now=std::chrono::steady_clock::now();
            const auto ms=[](auto a,auto b){return std::chrono::duration<double,std::milli>(b-a).count();};
            vf_diag::trace("progressive-texture pts=%lld width=%u height=%u submissions=%u setup_ms=%.3f pin_ms=%.3f submit_cpu_ms=%.3f final_event_wait_ms=%.3f total_ms=%.3f scope=diagnostic-CPU-wall\n",static_cast<long long>(p.trace_pts),p.width,p.height,p.submissions,ms(p.started,p.ready),p.pin_ms,p.submit_ms,ms(p.finished_submission,now),ms(p.started,now));
        }
        // Publish only after CUDA has returned the completed texture to GL.
        if(!s.raw_textures || s.imported || s.textures[1] || s.width!=p.width || s.height!=p.height)s.release_textures();
        std::swap(p.texture,s.textures[0]);std::swap(p.resource,s.resources[0]);
        s.width=p.width;s.height=p.height;s.raw_textures=true;
        const bool trace_release=std::getenv("VIEWFLOW_PROGRESSIVE_UPLOAD_TRACE")!=nullptr;
        const auto release_begin=trace_release?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};
        const auto trace_pts=p.trace_pts;
        s.cancel_progressive();
        if(trace_release)vf_diag::trace("progressive-release pts=%lld cleanup_cpu_ms=%.3f scope=CPU-wall-includes-notification-drain\n",static_cast<long long>(trace_pts),std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-release_begin).count());
        return ProgressiveStatus::complete;
    }catch(...){s.cancel_progressive(true);throw;}
#else
    throw std::runtime_error("progressive CUDA upload unavailable");
#endif
}
unsigned GpuDecoder::y_texture() const {return impl_->textures[0];}
unsigned GpuDecoder::uv_texture() const {return impl_->textures[1];}
}

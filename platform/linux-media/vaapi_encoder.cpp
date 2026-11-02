#include "vaapi_encoder.hpp"
#include "../reverse-common/encoder_extent.hpp"
#include <stdexcept>
#include <chrono>
#include <cstdio>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
}
namespace viewflow::media {
namespace {
void check(int code,const char* operation) {
    if(code>=0) return;
    char error[AV_ERROR_MAX_STRING_SIZE]{}; av_strerror(code,error,sizeof(error));
    throw std::runtime_error(std::string(operation)+": "+error);
}
struct PacketFree { void operator()(AVPacket* p)const { av_packet_free(&p); } };
struct FrameFree { void operator()(AVFrame* f)const { av_frame_free(&f); } };
using Frame=std::unique_ptr<AVFrame,FrameFree>;
Frame frame() { Frame f(av_frame_alloc()); if(!f) throw std::bad_alloc(); return f; }
}
struct VaapiEncoder::Impl {
    AVBufferRef* device{};
    AVBufferRef* frames{};
    AVCodecContext* codec{};
    Frame staging;
    int64_t pts{};
    std::string node;
    unsigned codecId{};
    int sourceWidth{}, sourceHeight{};
    uint32_t bitrate{}, pending{};
    std::chrono::steady_clock::time_point rebuilt = std::chrono::steady_clock::now();
    ~Impl() { avcodec_free_context(&codec); av_buffer_unref(&frames); av_buffer_unref(&device); }
};
VaapiEncoder::VaapiEncoder(int width,int height,unsigned codec,const std::string& renderNode,uint32_t kbps):impl_(std::make_unique<Impl>()) {
    if(width<2 || height<2 || width%2 || height%2 || (codec!=2 && codec!=4) || renderNode.empty())
        throw std::invalid_argument("VA-API requires even dimensions, H264/AV1, and a render node");
    const int sourceWidth=width,sourceHeight=height;
    auto limit=encoderLimit(codec==2);
    for (;;) {
        impl_=std::make_unique<Impl>();
        auto& s=*impl_;
        s.sourceWidth=sourceWidth;s.sourceHeight=sourceHeight;
        const auto coded=fitExtent({unsigned(sourceWidth),unsigned(sourceHeight)},limit);
        width=coded.width;height=coded.height;
        s.node=renderNode; s.codecId=codec; s.bitrate=s.pending=kbps;
        check(av_hwdevice_ctx_create(&s.device,AV_HWDEVICE_TYPE_VAAPI,renderNode.c_str(),nullptr,0),"create VA-API device");
        if (auto* constraints=av_hwdevice_get_hwframe_constraints(s.device,nullptr)) {
            if (constraints->max_width>0) limit.width=std::min(limit.width,unsigned(constraints->max_width));
            if (constraints->max_height>0) limit.height=std::min(limit.height,unsigned(constraints->max_height));
            av_hwframe_constraints_free(&constraints);
            const auto supported=fitExtent({unsigned(sourceWidth),unsigned(sourceHeight)},limit);
            width=supported.width;height=supported.height;
        }
        s.frames=av_hwframe_ctx_alloc(s.device); if(!s.frames) throw std::bad_alloc();
        auto* pool=reinterpret_cast<AVHWFramesContext*>(s.frames->data);
        pool->format=AV_PIX_FMT_VAAPI; pool->sw_format=AV_PIX_FMT_NV12;
        pool->width=width; pool->height=height; pool->initial_pool_size=4;
        const int poolStatus=av_hwframe_ctx_init(s.frames);
        if (poolStatus<0 && width>192 && height>192) {
            limit={unsigned(width/2),unsigned(height/2)};
            continue;
        }
        check(poolStatus,"create VA-API NV12 surface pool");
        const auto* encoder=avcodec_find_encoder_by_name(codec==2?"h264_vaapi":"av1_vaapi");
        if(!encoder) throw std::runtime_error("requested VA-API encoder is absent from libavcodec");
        s.codec=avcodec_alloc_context3(encoder); if(!s.codec) throw std::bad_alloc();
        auto* c=s.codec;
        c->width=width; c->height=height; c->pix_fmt=AV_PIX_FMT_VAAPI;
        c->hw_frames_ctx=av_buffer_ref(s.frames); if(!c->hw_frames_ctx) throw std::bad_alloc();
        c->time_base={1,60}; c->framerate={60,1}; c->gop_size=120; c->max_b_frames=0;
        c->flags|=AV_CODEC_FLAG_LOW_DELAY;
        c->color_range=AVCOL_RANGE_MPEG; c->colorspace=AVCOL_SPC_BT709;
        c->color_primaries=AVCOL_PRI_BT709; c->color_trc=AVCOL_TRC_BT709;
        c->bit_rate=int64_t(kbps)*1000; c->rc_max_rate=c->bit_rate;
        check(av_opt_set(c->priv_data,"rc_mode",kbps?"VBR":"CQP",0),"set VA-API rate control");
        check(av_opt_set_int(c->priv_data,"qp",10,0),"set VA-API QP");
        check(av_opt_set_int(c->priv_data,"async_depth",1,0),"set VA-API async depth");
        if(codec==2) {
            check(av_opt_set(c->priv_data,"profile","high",0),"set VA-API H264 profile");
            check(av_opt_set_int(c->priv_data,"idr_interval",0,0),"set VA-API IDR interval");
        }
        const int opened=avcodec_open2(c,encoder,nullptr);
        if (opened<0 && width>192 && height>192) {
            limit={unsigned(width/2),unsigned(height/2)};
            continue; // Drop the failed context/pool; retain the capture canvas.
        }
        check(opened,"open hardware VA-API encoder");
        s.staging=frame(); s.staging->format=AV_PIX_FMT_NV12; s.staging->width=width; s.staging->height=height;
        check(av_frame_get_buffer(s.staging.get(),32),"allocate VA-API upload staging");
        if (width!=sourceWidth || height!=sourceHeight)
            std::fprintf(stderr,"encoder-size backend=vaapi canvas=%dx%d color=%dx%d\n",sourceWidth,sourceHeight,width,height);
        s.rebuilt=std::chrono::steady_clock::now();
        break;
    }
}
VaapiEncoder::~VaapiEncoder()=default;
void VaapiEncoder::setBitrateKbps(uint32_t kbps) {
    if (!kbps || kbps>1000000 || !impl_->bitrate) throw std::invalid_argument("VA-API update requires VBR");
    impl_->pending=kbps;
}
std::vector<uint8_t> VaapiEncoder::encode(std::span<const uint8_t> rgba,bool idr,bool& keyframe) {
    if (impl_->pending!=impl_->bitrate && std::chrono::steady_clock::now()-impl_->rebuilt>=std::chrono::seconds(1)) {
        // Replacement creates its own first-frame IDR. Failure retains the old stream.
        try {
            VaapiEncoder replacement(impl_->sourceWidth,impl_->sourceHeight,impl_->codecId,impl_->node,impl_->pending);
            impl_.swap(replacement.impl_);
            idr=true;
        } catch (const std::exception&) { impl_->rebuilt=std::chrono::steady_clock::now(); }
    }
    auto& s=*impl_; const int w=s.codec->width,h=s.codec->height;
    if(rgba.size()!=size_t(s.sourceWidth)*s.sourceHeight*4) throw std::invalid_argument("VA-API RGBA size mismatch");
    check(av_frame_make_writable(s.staging.get()),"writable VA-API staging");
    auto pixel=[&](int x,int y) { return rgba.data()+(size_t(h==s.sourceHeight ? y : uint64_t(y)*s.sourceHeight/h)*s.sourceWidth+(w==s.sourceWidth ? x : uint64_t(x)*s.sourceWidth/w))*4; };
    // Identical BT.709 limited-range conversion to the NVIDIA kernel.
    for(int y=0;y<h;++y) for(int x=0;x<w;++x) {
        const auto* p=pixel(x,y);
        s.staging->data[0][size_t(y)*s.staging->linesize[0]+x]=((47*p[0]+157*p[1]+16*p[2]+128)>>8)+16;
        if((x|y)&1) continue;
        int r=0,g=0,b=0;
        for(int dy=0;dy<2;++dy) for(int dx=0;dx<2;++dx) {
            const auto* q=pixel(x+dx,y+dy); r+=q[0];g+=q[1];b+=q[2];
        }
        auto* uv=s.staging->data[1]+size_t(y/2)*s.staging->linesize[1]+x;
        uv[0]=((-26*(r/4)-87*(g/4)+112*(b/4)+128)>>8)+128;
        uv[1]=((112*(r/4)-102*(g/4)-10*(b/4)+128)>>8)+128;
    }
    auto hardware=frame();
    check(av_hwframe_get_buffer(s.frames,hardware.get(),0),"get VA-API surface");
    check(av_hwframe_transfer_data(hardware.get(),s.staging.get(),0),"upload NV12 to VA-API");
    hardware->pts=s.pts++;
    hardware->pict_type=idr || hardware->pts==0?AV_PICTURE_TYPE_I:AV_PICTURE_TYPE_NONE;
    hardware->color_range=s.codec->color_range; hardware->colorspace=s.codec->colorspace;
    hardware->color_primaries=s.codec->color_primaries; hardware->color_trc=s.codec->color_trc;
    check(avcodec_send_frame(s.codec,hardware.get()),"submit VA-API frame");
    std::unique_ptr<AVPacket,PacketFree> packet(av_packet_alloc()); if(!packet) throw std::bad_alloc();
    check(avcodec_receive_packet(s.codec,packet.get()),"receive synchronous VA-API packet");
    if(packet->pts!=hardware->pts || packet->size<=0)
        throw std::runtime_error("VA-API packet identity mismatch");
    keyframe=(packet->flags&AV_PKT_FLAG_KEY)!=0;
    std::vector<uint8_t> bytes(packet->data,packet->data+packet->size);
    if(s.codec->codec_id==AV_CODEC_ID_H264 && !(bytes.size()>=4 && bytes[0]==0 && bytes[1]==0 &&
            (bytes[2]==1 || (bytes[2]==0 && bytes[3]==1))))
        throw std::runtime_error("VA-API H264 packet is not Annex B");
    if(idr && !keyframe) throw std::runtime_error("VA-API did not honor the keyframe request");
    return bytes;
}
}

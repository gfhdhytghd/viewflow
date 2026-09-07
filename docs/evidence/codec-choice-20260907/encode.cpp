extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
}
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>
static void check(int r,const char* s){if(r<0){char e[256];av_strerror(r,e,sizeof(e));throw std::runtime_error(std::string(s)+": "+e);}}
int main(int argc,char**argv){try{
if(argc!=5)return 2;const char*name=argv[1];int w=atoi(argv[2]),h=atoi(argv[3]);
AVBufferRef*dev=nullptr;check(av_hwdevice_ctx_create(&dev,AV_HWDEVICE_TYPE_CUDA,"0",nullptr,0),"device");
AVBufferRef*pool=av_hwframe_ctx_alloc(dev);auto*fc=(AVHWFramesContext*)pool->data;fc->format=AV_PIX_FMT_CUDA;fc->sw_format=AV_PIX_FMT_NV12;fc->width=w;fc->height=h;fc->initial_pool_size=16;check(av_hwframe_ctx_init(pool),"pool");
std::vector<AVFrame*>frames;
for(int k=0;k<16;k++){AVFrame*host=av_frame_alloc();host->format=AV_PIX_FMT_NV12;host->width=w;host->height=h;check(av_frame_get_buffer(host,32),"host");for(int y=0;y<h;y++)for(int x=0;x<w;x++){int tile=(x/64+y/48)%5;int text=(y%20<3 && (x+k*7)%37<23);host->data[0][y*host->linesize[0]+x]=text?32:80+tile*30;}for(int y=0;y<h/2;y++)for(int x=0;x<w;x++)host->data[1][y*host->linesize[1]+x]=128;AVFrame*gpu=av_frame_alloc();check(av_hwframe_get_buffer(pool,gpu,0),"gpu");check(av_hwframe_transfer_data(gpu,host,0),"upload");av_frame_free(&host);frames.push_back(gpu);}
const AVCodec*codec=avcodec_find_encoder_by_name(name);if(!codec)throw std::runtime_error("codec absent");AVCodecContext*ctx=avcodec_alloc_context3(codec);ctx->width=w;ctx->height=h;ctx->pix_fmt=AV_PIX_FMT_CUDA;ctx->time_base={1,60};ctx->framerate={60,1};ctx->max_b_frames=0;ctx->gop_size=120;ctx->hw_frames_ctx=av_buffer_ref(pool);
for(auto kv:std::vector<std::pair<const char*,const char*>>{{"preset","p1"},{"tune","ull"},{"zerolatency","1"},{"delay","0"},{"rc-lookahead","0"},{"rc","constqp"},{"qp","10"}})check(av_opt_set(ctx->priv_data,kv.first,kv.second,0),kv.first);
check(avcodec_open2(ctx,codec,nullptr),"open");std::ofstream out(argv[4],std::ios::binary);uint32_t magic=0x56464342,width=w,height=h;out.write((char*)&magic,4);out.write((char*)&width,4);out.write((char*)&height,4);std::vector<double>times;size_t bytes=0;
for(int i=0;i<330;i++){AVFrame*f=frames[i%frames.size()];f->pts=i;auto start=std::chrono::steady_clock::now();check(avcodec_send_frame(ctx,f),"send");AVPacket*p=av_packet_alloc();check(avcodec_receive_packet(ctx,p),"receive");auto end=std::chrono::steady_clock::now();if(i>=30){times.push_back(std::chrono::duration<double,std::micro>(end-start).count());bytes+=p->size;}uint32_t sz=p->size,flags=p->flags;out.write((char*)&sz,4);out.write((char*)&flags,4);out.write((char*)p->data,p->size);av_packet_free(&p);}
std::sort(times.begin(),times.end());printf("codec=%s width=%d height=%d measured=300 gpu_resident=true host_send_receive_us p50=%.1f p95=%.1f p99=%.1f mean_bytes=%zu\n",name,w,h,times[150],times[285],times[297],bytes/300);avcodec_free_context(&ctx);for(auto f:frames)av_frame_free(&f);av_buffer_unref(&pool);av_buffer_unref(&dev);return 0;
}catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 1;}}

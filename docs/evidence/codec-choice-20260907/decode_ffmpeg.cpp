#include <windows.h>
#include <d3d11.h>
#include <d3d10.h>
#include <wrl/client.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>
}
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>
using Microsoft::WRL::ComPtr;using Clock=std::chrono::steady_clock;
static void ck(int r,const char*s){if(r<0){char e[256];av_strerror(r,e,sizeof(e));throw std::runtime_error(std::string(s)+": "+e);}}
static AVPixelFormat fmt(AVCodecContext*,const AVPixelFormat*f){while(*f!=AV_PIX_FMT_NONE){if(*f==AV_PIX_FMT_D3D11)return *f;f++;}return AV_PIX_FMT_NONE;}
int main(int argc,char**argv){try{if(argc!=3)return 2;
std::ifstream f(argv[2],std::ios::binary);uint32_t magic,w,h;f.read((char*)&magic,4);f.read((char*)&w,4);f.read((char*)&h,4);if(!f||magic!=0x56464342)throw std::runtime_error("fixture header");std::vector<std::vector<BYTE>>packets;std::vector<uint32_t>flags;for(;;){uint32_t n,fl;f.read((char*)&n,4);if(!f)break;f.read((char*)&fl,4);if(n>32*1024*1024)throw std::runtime_error("packet bound");std::vector<BYTE>p(n);f.read((char*)p.data(),n);if(!f)throw std::runtime_error("short packet");packets.push_back(std::move(p));flags.push_back(fl);}
ComPtr<ID3D11Device>device;ComPtr<ID3D11DeviceContext>context;D3D_FEATURE_LEVEL level;if(FAILED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_VIDEO_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,&level,&context)))throw std::runtime_error("device");ComPtr<ID3D10Multithread>mt;device.As(&mt);mt->SetMultithreadProtected(TRUE);
AVBufferRef*hw=av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);auto*d=(AVD3D11VADeviceContext*)((AVHWDeviceContext*)hw->data)->hwctx;d->device=device.Get();d->device->AddRef();ck(av_hwdevice_ctx_init(hw),"hwinit");const AVCodec*codec=avcodec_find_decoder_by_name(argv[1]);if(!codec)throw std::runtime_error("decoder absent");AVCodecContext*c=avcodec_alloc_context3(codec);c->hw_device_ctx=av_buffer_ref(hw);c->get_format=fmt;c->thread_count=1;c->flags|=AV_CODEC_FLAG_LOW_DELAY;c->pkt_timebase={1,60};c->extra_hw_frames=4;ck(avcodec_open2(c,codec,nullptr),"open");D3D11_QUERY_DESC qd{D3D11_QUERY_EVENT,0};ComPtr<ID3D11Query>query;device->CreateQuery(&qd,&query);std::vector<Clock::time_point>starts(packets.size());std::vector<double>times;size_t outputs=0;AVFrame*out=av_frame_alloc();
auto drain=[&](){for(;;){int r=avcodec_receive_frame(c,out);if(r==AVERROR(EAGAIN)||r==AVERROR_EOF)return;ck(r,"receive");if(out->format!=AV_PIX_FMT_D3D11)throw std::runtime_error("non GPU frame");auto*tex=(ID3D11Texture2D*)out->data[0];D3D11_TEXTURE2D_DESC td{};tex->GetDesc(&td);if(td.Format!=DXGI_FORMAT_NV12)throw std::runtime_error("non NV12");context->End(query.Get());context->Flush();auto wait=Clock::now();while(context->GetData(query.Get(),nullptr,0,0)==S_FALSE){if(Clock::now()-wait>std::chrono::seconds(3))throw std::runtime_error("GPU timeout");SwitchToThread();}size_t idx=(size_t)out->pts;if(idx>=starts.size())throw std::runtime_error("PTS invalid");if(idx>=30)times.push_back(std::chrono::duration<double,std::micro>(Clock::now()-starts[idx]).count());outputs++;av_frame_unref(out);}};
for(size_t i=0;i<packets.size();i++){AVPacket*p=av_packet_alloc();ck(av_new_packet(p,(int)packets[i].size()),"packet");memcpy(p->data,packets[i].data(),packets[i].size());p->pts=p->dts=i;p->flags=flags[i];starts[i]=Clock::now();ck(avcodec_send_packet(c,p),"send");av_packet_free(&p);drain();}ck(avcodec_send_packet(c,nullptr),"drain");drain();if(times.empty())throw std::runtime_error("no decoded frames");std::sort(times.begin(),times.end());printf("codec=%s outputs=%zu measured=%zu all_gpu=true host_input_to_output_gpu_fence_us p50=%.1f p95=%.1f p99=%.1f\n",argv[1],outputs,times.size(),times[times.size()/2],times[times.size()*95/100],times[times.size()*99/100]);av_frame_free(&out);avcodec_free_context(&c);av_buffer_unref(&hw);return outputs==packets.size()?0:1;
}catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 1;}}

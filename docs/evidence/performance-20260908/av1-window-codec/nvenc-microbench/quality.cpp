extern "C" {
#include <libavcodec/avcodec.h>
}
#include <cmath>
#include <cstdio>
#include <fstream>
#include <vector>
#include <stdexcept>
#include <algorithm>
static void ck(int r){if(r<0){char b[256];av_strerror(r,b,sizeof b);throw std::runtime_error(b);}}
int main(int argc,char**argv)try{
 if(argc!=2)return 2;std::ifstream f(argv[1],std::ios::binary);uint32_t magic,w,h;f.read((char*)&magic,4);f.read((char*)&w,4);f.read((char*)&h,4);if(!f||magic!=0x56464342)throw std::runtime_error("header");
 auto*codec=avcodec_find_decoder_by_name("libdav1d");if(!codec)throw std::runtime_error("no decoder");auto*c=avcodec_alloc_context3(codec);c->thread_count=4;ck(avcodec_open2(c,codec,nullptr));auto*out=av_frame_alloc();unsigned inputs=0,outputs=0;uint64_t sse=0,n=0,changed=0,chroma_error=0;unsigned max_error=0;std::vector<bool> seen(330);
 auto drain=[&](){for(;;){int r=avcodec_receive_frame(c,out);if(r==AVERROR(EAGAIN)||r==AVERROR_EOF)return;ck(r);if(out->format!=AV_PIX_FMT_YUV420P||out->width!=int(w)||out->height!=int(h)||out->pts<0||out->pts>=330||seen[out->pts])throw std::runtime_error("decoded identity or format");seen[out->pts]=true;++outputs;unsigned k=unsigned(out->pts)%16;if(out->pts>=30){for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x){unsigned tile=(x/64+y/48)%5;unsigned ref=(y%20<3&&(x+k*7)%37<23)?32:80+tile*30;int e=int(out->data[0][size_t(y)*out->linesize[0]+x])-int(ref);sse+=uint64_t(e*e);changed+=e!=0;++n;max_error=std::max(max_error,unsigned(std::abs(e)));}for(unsigned p=1;p<3;++p)for(unsigned y=0;y<h/2;++y)for(unsigned x=0;x<w/2;++x)chroma_error+=out->data[p][size_t(y)*out->linesize[p]+x]!=128;}av_frame_unref(out);}};
 for(;;){uint32_t sz,flags;f.read((char*)&sz,4);if(!f)break;f.read((char*)&flags,4);if(!sz||sz>32*1024*1024)throw std::runtime_error("size");auto*p=av_packet_alloc();ck(av_new_packet(p,int(sz)));f.read((char*)p->data,sz);if(!f)throw std::runtime_error("short input");p->pts=p->dts=inputs++;p->flags=flags;ck(avcodec_send_packet(c,p));av_packet_free(&p);drain();}ck(avcodec_send_packet(c,nullptr));drain();if(inputs!=330||outputs!=inputs)throw std::runtime_error("missing output");printf("{\"inputs\":%u,\"outputs\":%u,\"measured_frames\":300,\"luma_samples\":%llu,\"luma_sse\":%llu,\"luma_psnr\":%.9f,\"changed_luma\":%llu,\"max_luma_error\":%u,\"chroma_error_samples\":%llu}\n",inputs,outputs,(unsigned long long)n,(unsigned long long)sse,10*log10(255.*255.*double(n)/double(sse)),(unsigned long long)changed,max_error,(unsigned long long)chroma_error);av_frame_free(&out);avcodec_free_context(&c);return 0;
}catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 1;}

#include "wlr-screencopy-client-protocol.h"
#include <wayland-client.h>
#include <sys/mman.h>
#include <unistd.h>
#include <poll.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include <stdexcept>
long long mono(){return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();}
struct Output{wl_output* object{};std::string name;};
struct App{
 wl_display* display{};wl_shm* shm{};zwlr_screencopy_manager_v1* manager{};std::vector<std::unique_ptr<Output>> outputs;
 wl_buffer* buffer{};void* pixels=MAP_FAILED;size_t bytes{};unsigned width{},height{},stride{},format{},flags{};bool done{};std::string error;unsigned captures{},valid{},previous{},distinct{};
 static void geometry(void*,wl_output*,int32_t,int32_t,int32_t,int32_t,int32_t,const char*,const char*,int32_t){}static void mode(void*,wl_output*,uint32_t,int32_t,int32_t,int32_t){}static void output_done(void*,wl_output*){}static void scale(void*,wl_output*,int32_t){}static void name(void* p,wl_output*,const char* n){static_cast<Output*>(p)->name=n;}static void desc(void*,wl_output*,const char*){}
 static constexpr wl_output_listener ol{geometry,mode,output_done,scale,name,desc};
 static void global(void* p,wl_registry* r,uint32_t id,const char* iface,uint32_t version){auto& a=*static_cast<App*>(p);if(!strcmp(iface,"wl_shm"))a.shm=static_cast<wl_shm*>(wl_registry_bind(r,id,&wl_shm_interface,1));else if(!strcmp(iface,"zwlr_screencopy_manager_v1"))a.manager=static_cast<zwlr_screencopy_manager_v1*>(wl_registry_bind(r,id,&zwlr_screencopy_manager_v1_interface,1));else if(!strcmp(iface,"wl_output")){auto o=std::make_unique<Output>();o->object=static_cast<wl_output*>(wl_registry_bind(r,id,&wl_output_interface,std::min(version,4u)));wl_output_add_listener(o->object,&ol,o.get());a.outputs.push_back(std::move(o));}}
 static void removed(void*,wl_registry*,uint32_t){}static constexpr wl_registry_listener rl{global,removed};
 static void dimensions(void* p,zwlr_screencopy_frame_v1* frame,uint32_t format,uint32_t w,uint32_t h,uint32_t stride){auto& a=*static_cast<App*>(p);
  if(w!=3072 || h!=128 || stride<w*4 || stride>1u<<20 || (format!=WL_SHM_FORMAT_XRGB8888 && format!=WL_SHM_FORMAT_ARGB8888 && format!=WL_SHM_FORMAT_XBGR8888 && format!=WL_SHM_FORMAT_ABGR8888)){a.error="unexpected ROI format or dimensions";a.done=true;return;}
  if(!a.buffer || a.width!=w || a.height!=h || a.stride!=stride || a.format!=format){
   if(a.buffer)wl_buffer_destroy(a.buffer);if(a.pixels!=MAP_FAILED)munmap(a.pixels,a.bytes);a.bytes=size_t(stride)*h;
   int fd=memfd_create("viewflow-marker-observer",MFD_CLOEXEC);if(fd<0 || ftruncate(fd,a.bytes)){a.error="observer buffer allocation failed";a.done=true;if(fd>=0)close(fd);return;}
   a.pixels=mmap(nullptr,a.bytes,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(a.pixels==MAP_FAILED){a.error="observer mmap failed";a.done=true;close(fd);return;}
   auto pool=wl_shm_create_pool(a.shm,fd,a.bytes);a.buffer=wl_shm_pool_create_buffer(pool,0,w,h,stride,format);wl_shm_pool_destroy(pool);close(fd);a.width=w;a.height=h;a.stride=stride;a.format=format;
   std::fprintf(stderr,"observer_roi width=%u height=%u stride=%u format=%u\n",w,h,stride,format);
  }
  zwlr_screencopy_frame_v1_copy(frame,a.buffer);
 }
 static void frame_flags(void* p,zwlr_screencopy_frame_v1*,uint32_t f){static_cast<App*>(p)->flags=f;}
 static void ready(void* p,zwlr_screencopy_frame_v1*,uint32_t hi,uint32_t lo,uint32_t ns){auto& a=*static_cast<App*>(p);auto observed=mono();a.done=true;++a.captures;
  if(a.captures==1){if(const auto path=std::getenv("VIEWFLOW_TOPOLOGY_SNAPSHOT")){if(auto file=std::fopen(path,"wb")){std::fprintf(file,"P6\n%u %u\n255\n",a.width,a.height);for(unsigned y=0;y<a.height;++y)for(unsigned x=0;x<a.width;++x){auto pixel=static_cast<unsigned char*>(a.pixels)+size_t((a.flags&ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT)?a.height-1-y:y)*a.stride+x*4;const unsigned char rgb[]={pixel[2],pixel[1],pixel[0]};std::fwrite(rgb,1,3,file);}std::fclose(file);}}}unsigned marker=0;bool valid=true;
  auto sample=[&](unsigned x,unsigned y){if(a.flags&ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT)y=a.height-1-y;return static_cast<unsigned char*>(a.pixels)[size_t(y)*a.stride+x*4];};
  for(unsigned bit=0;bit<24;++bit){auto top=sample(bit*128+64,32),bottom=sample(bit*128+64,96);if(!((top<70 && bottom>180)||(top>180 && bottom<70))){valid=false;break;}if(top>180)marker|=1u<<bit;}
  valid=valid && marker>0;if(valid){++a.valid;if(marker<a.previous)a.error="desktop marker regressed";if(marker!=a.previous)++a.distinct;a.previous=marker;}
  std::printf("desktop_marker mono=%lld ready_ns=%llu marker=%u valid=%u\n",observed,((uint64_t(hi)<<32)|lo)*1000000000ull+ns,marker,unsigned(valid));
 }
 static void failed(void* p,zwlr_screencopy_frame_v1*){auto& a=*static_cast<App*>(p);a.error="screencopy failed";a.done=true;}
 static void damage(void*,zwlr_screencopy_frame_v1*,uint32_t,uint32_t,uint32_t,uint32_t){}static void dma(void*,zwlr_screencopy_frame_v1*,uint32_t,uint32_t,uint32_t){}static void buffers(void*,zwlr_screencopy_frame_v1*){}
 static constexpr zwlr_screencopy_frame_v1_listener fl{dimensions,frame_flags,ready,failed,damage,dma,buffers};
 void run(const std::string& selected,int duration){display=wl_display_connect(nullptr);if(!display)throw std::runtime_error("Wayland connect failed");auto reg=wl_display_get_registry(display);wl_registry_add_listener(reg,&rl,this);wl_display_roundtrip(display);wl_display_roundtrip(display);if(!shm || !manager)throw std::runtime_error("screencopy globals missing");auto it=std::find_if(outputs.begin(),outputs.end(),[&](auto& o){return o->name==selected;});if(it==outputs.end())throw std::runtime_error("selected output missing");const auto end=mono()+duration*1000000ll;
  while(mono()<end){done=false;flags=0;auto frame=zwlr_screencopy_manager_v1_capture_output_region(manager,0,(*it)->object,0,128,1536,64);zwlr_screencopy_frame_v1_add_listener(frame,&fl,this);const auto deadline=mono()+2000000000ll;
   while(!done){if(wl_display_dispatch_pending(display)<0)throw std::runtime_error("dispatch failed");if(done)break;wl_display_flush(display);pollfd fd{wl_display_get_fd(display),POLLIN,0};if(poll(&fd,1,100)>0){if(wl_display_dispatch(display)<0)throw std::runtime_error("display failed");}if(mono()>deadline)throw std::runtime_error("observer frame timeout");}
   zwlr_screencopy_frame_v1_destroy(frame);if(!error.empty())throw std::runtime_error(error);
  }
  std::fprintf(stderr,"observer_complete captures=%u valid=%u distinct=%u\n",captures,valid,distinct);if(!valid)throw std::runtime_error("no valid desktop markers");
 }
 ~App(){if(buffer)wl_buffer_destroy(buffer);if(pixels!=MAP_FAILED)munmap(pixels,bytes);if(display)wl_display_disconnect(display);}
};
int main(int argc,char** argv){try{if(argc!=3)return 2;App a;a.run(argv[1],std::stoi(argv[2]));return 0;}catch(const std::exception& e){std::fprintf(stderr,"observer_error %s\n",e.what());return 1;}}

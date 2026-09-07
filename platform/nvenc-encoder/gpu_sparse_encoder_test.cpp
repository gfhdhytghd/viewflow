// Owned EGL textures only. This probe never captures or injects desktop input.
#include "gpu_dmabuf_encoder_cabi.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <ctime>
#include <unistd.h>
namespace {
struct Egl {
  EGLDisplay d = EGL_NO_DISPLAY;
  EGLSurface s = EGL_NO_SURFACE;
  EGLContext c = EGL_NO_CONTEXT;
  ~Egl() {
    if (d != EGL_NO_DISPLAY) {
      eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      if (c != EGL_NO_CONTEXT)
        eglDestroyContext(d, c);
      if (s != EGL_NO_SURFACE)
        eglDestroySurface(d, s);
      eglTerminate(d);
    }
  }
  bool init() {
    d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint a, b;
    if (d == EGL_NO_DISPLAY || eglInitialize(d, &a, &b) != EGL_TRUE) {
      auto query = reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(
          eglGetProcAddress("eglQueryDevicesEXT"));
      auto get = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
          eglGetProcAddress("eglGetPlatformDisplayEXT"));
      EGLDeviceEXT device{};
      EGLint count = 0;
      if (!query || !get || query(1, &device, &count) != EGL_TRUE ||
          count != 1 ||
          (d = get(EGL_PLATFORM_DEVICE_EXT, device, nullptr)) ==
              EGL_NO_DISPLAY ||
          eglInitialize(d, &a, &b) != EGL_TRUE)
        return false;
    }
    if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE)
      return false;
    const EGLint x[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE,
                        EGL_OPENGL_ES3_BIT_KHR, EGL_NONE},
                 p[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE},
                 ca[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLConfig q{};
    EGLint n = 0;
    if (eglChooseConfig(d, x, &q, 1, &n) != EGL_TRUE || n != 1)
      return false;
    s = eglCreatePbufferSurface(d, q, p);
    c = eglCreateContext(d, q, EGL_NO_CONTEXT, ca);
    return s != EGL_NO_SURFACE && c != EGL_NO_CONTEXT &&
           eglMakeCurrent(d, s, s, c) == EGL_TRUE;
  }
};
struct Export {
  int fd = -1, fence = -1;
  EGLint stride = 0, offset = 0;
  EGLuint64KHR modifier = 0;
  EGLImageKHR image = EGL_NO_IMAGE_KHR;
  Egl *e = nullptr;
  ~Export() {
    if (fd >= 0)
      close(fd);
    if (fence >= 0)
      close(fence);
    if (image != EGL_NO_IMAGE_KHR) {
      auto f = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
          eglGetProcAddress("eglDestroyImageKHR"));
      if (f)
        f(e->d, image);
    }
  }
};
bool exportFrame(Egl &e, GLuint tex, Export &out) {
  auto create = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
      eglGetProcAddress("eglCreateImageKHR"));
  auto query = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC>(
      eglGetProcAddress("eglExportDMABUFImageQueryMESA"));
  auto ex = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEMESAPROC>(
      eglGetProcAddress("eglExportDMABUFImageMESA"));
  auto syncCreate = reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(
      eglGetProcAddress("eglCreateSyncKHR"));
  auto syncDup = reinterpret_cast<PFNEGLDUPNATIVEFENCEFDANDROIDPROC>(
      eglGetProcAddress("eglDupNativeFenceFDANDROID"));
  if (!create || !query || !ex || !syncCreate || !syncDup)
    return false;
  const EGLint a[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
  out.e = &e;
  out.image = create(e.d, e.c, EGL_GL_TEXTURE_2D_KHR,
                     reinterpret_cast<EGLClientBuffer>(uintptr_t(tex)), a);
  int fourcc = 0, planes = 0, fds[4] = {-1, -1, -1, -1};
  EGLint stride[4]{}, offset[4]{};
  EGLuint64KHR mods[4]{};
  if (out.image == EGL_NO_IMAGE_KHR ||
      query(e.d, out.image, &fourcc, &planes, mods) != EGL_TRUE ||
      ex(e.d, out.image, fds, stride, offset) != EGL_TRUE || planes != 1 ||
      fourcc != 0x34324241)
    return false;
  out.fd = fds[0];
  out.stride = stride[0];
  out.offset = offset[0];
  out.modifier = mods[0];
  for (int i = 1; i < 4; i++)
    if (fds[i] >= 0)
      close(fds[i]);
  EGLSyncKHR sync = syncCreate(e.d, EGL_SYNC_NATIVE_FENCE_ANDROID, nullptr);
  glFlush();
  out.fence = sync == EGL_NO_SYNC_KHR ? -1 : syncDup(e.d, sync);
  return out.fd >= 0 && out.fence >= 0;
}

}
static void require(bool condition,const char* reason) {
  if(!condition){std::fprintf(stderr,"FAIL %s\n",reason);std::exit(1);}
}
static int64_t nowNs(){timespec t{};clock_gettime(CLOCK_MONOTONIC,&t);return int64_t(t.tv_sec)*1000000000+t.tv_nsec;}
static void writeFile(const std::string& path,const std::vector<unsigned char>& bytes) {
  auto* f=std::fopen(path.c_str(),"wb");require(f,"open fixture");
  require(std::fwrite(bytes.data(),1,bytes.size(),f)==bytes.size(),"write fixture");std::fclose(f);
}
int main(int argc,char** argv) {
  Egl egl;require(egl.init(),"owned producer EGL");
  GLuint textures[2]{};glGenTextures(2,textures);
  constexpr unsigned size=256;
  std::vector<unsigned char> colors[2]={std::vector<unsigned char>(size*size*4),std::vector<unsigned char>(size*size*4)};
  for(unsigned y=0;y<size;++y)for(unsigned x=0;x<size;++x) {
    const auto i=(y*size+x)*4;
    colors[0][i+(x<128?2:1)]=y<128?255:128;colors[0][i+3]=255;
    colors[1][i]=128;colors[1][i+3]=128; // producer pixels are premultiplied
  }
  for(unsigned i=0;i<2;++i) {
    glBindTexture(GL_TEXTURE_2D,textures[i]);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,size,size,0,GL_RGBA,GL_UNSIGNED_BYTE,colors[i].data());
  }
  Export exports[2];for(unsigned i=0;i<2;++i)require(exportFrame(egl,textures[i],exports[i]),"export owned texture");
  for(unsigned mode:{1u,2u}) {
    vf_gpu_dmabuf_encoder_config config{256,256,4U<<20};vf_gpu_dmabuf_encoder* encoder=nullptr;
    require(vf_gpu_dmabuf_encoder_create_with_codec(&config,4,&encoder)==VF_GPU_DMABUF_OK,"AV1 encoder");
    vf_gpu_dmabuf_atlas_tile tiles[2]{};
    auto stamp=nowNs();
    for(unsigned i=0;i<2;++i) {
      auto& f=tiles[i].frame;const auto& e=exports[i];
      f.dma_buf_fd=e.fd;f.native_fence_fd=e.fence;f.image_width=size;f.image_height=size;
      f.stride=e.stride;f.offset=e.offset;f.modifier=e.modifier;f.fourcc=0x34324241;
      f.crop_width=size;f.crop_height=size;f.frame_id=mode;f.capture_timestamp_ns=stamp;f.geometry_epoch=1;
      tiles[i].deadline_monotonic_ns=stamp+10000000000LL;
    }
    vf_gpu_dmabuf_atlas atlas{sizeof(vf_gpu_dmabuf_atlas),1,2,0,tiles,mode,uint64_t(stamp),1};
    vf_gpu_dmabuf_sparse_source scene_sources[2]={{0,0,1,1},{0,0,2,1}};
    vf_gpu_dmabuf_sparse_scene scene{mode,512,256,2,scene_sources};
    vf_gpu_dmabuf_output* output=nullptr;
    auto status=vf_gpu_dmabuf_encoder_encode_sparse_recoverable(encoder,&atlas,&scene,1,stamp+10000000000LL,&output);
    vf_gpu_dmabuf_sparse_info sparse{};
    if(status==VF_GPU_DMABUF_NEEDS_CANVAS) {
      require(mode==1 && output,"opaque mode needs capacity for both translucent contributors");
      require(vf_gpu_dmabuf_output_get_sparse_info(output,&sparse)==0 && sparse.required_width==512 && sparse.required_height==256,"resize result");
      require(vf_gpu_dmabuf_output_destroy(output)==0 && vf_gpu_dmabuf_encoder_destroy(encoder)==0,"clean resize ownership");
      output=nullptr;encoder=nullptr;config.width=512;
      require(vf_gpu_dmabuf_encoder_create_with_codec(&config,4,&encoder)==0,"grown AV1 encoder");
      status=vf_gpu_dmabuf_encoder_encode_sparse_recoverable(encoder,&atlas,&scene,1,stamp+10000000000LL,&output);
    }
    if(status!=0){char error[256]{};size_t count{};vf_gpu_dmabuf_encoder_copy_last_error(encoder,error,sizeof(error),&count);std::fprintf(stderr,"native sparse status=%u %s\n",unsigned(status),error);}
    require(status==0 && output,"sparse encode completion");
    require(vf_gpu_dmabuf_output_get_sparse_info(output,&sparse)==0,"sparse info");
    require(sparse.patch_count==(mode==1?8:4) && sparse.stored_pixels==(mode==1?131072:65536),"actual encoded residency");
    vf_gpu_dmabuf_output_info info{};require(vf_gpu_dmabuf_output_get_info(output,&info)==0 && info.idr==1,"paired keyframe");
    std::vector<unsigned char> color(info.color_annex_b_bytes),alpha(info.raw_alpha_bytes);size_t required{};
    require(vf_gpu_dmabuf_output_copy_color(output,color.data(),color.size(),&required)==0,"color output");
    require(vf_gpu_dmabuf_output_copy_raw_alpha(output,alpha.data(),alpha.size(),&required)==0,"alpha output");
    std::vector<vf_gpu_dmabuf_sparse_patch> patches(sparse.patch_count);
    require(vf_gpu_dmabuf_output_copy_sparse_patches(output,patches.data(),patches.size(),&required)==0 && required==patches.size(),"patch output");
    for(const auto& p:patches)for(unsigned y=0;y<p.height;++y)for(unsigned x=0;x<p.width;++x)
      require(alpha[(p.y+y)*config.width+p.x+x]==(mode==1 && p.source==1?128:255),"exact composed alpha");
    if(argc==2) {
      const std::string prefix=std::string(argv[1])+"/mode-"+std::to_string(mode);
      writeFile(prefix+".av1",color);writeFile(prefix+".alpha",alpha);
      auto* f=std::fopen((prefix+".json").c_str(),"w");require(f,"metadata output");
      std::fprintf(f,"{\"width\":%u,\"height\":%u,\"patches\":[",config.width,config.height);
      for(size_t i=0;i<patches.size();++i) { const auto& p=patches[i];
        std::fprintf(f,"%s[%u,%u,%u,%u,%u,%u,%u]",i?",":"",p.source,p.source_x,p.source_y,p.x,p.y,p.width,p.height); }
      std::fputs("]}\n",f);std::fclose(f);
    }
    require(vf_gpu_dmabuf_output_destroy(output)==0,"initial output cleanup");
    // Scroll out, stop at a partial boundary, then scroll fully back. The
    // same encoder and source geometry survive all three residency changes.
    for(unsigned visibleWidth: {0u, 64u, 256u}) {
      for(auto& source:scene_sources) {
        source.clip_enabled=1;source.clip_x=256-visibleWidth;source.clip_y=0;
        source.clip_width=visibleWidth;source.clip_height=256;
      }
      output=nullptr;
      status=vf_gpu_dmabuf_encoder_encode_sparse_recoverable(encoder,&atlas,&scene,1,stamp+10000000000LL,&output);
      require(status==0 && output,"viewport encode completion");
      require(vf_gpu_dmabuf_output_get_sparse_info(output,&sparse)==0,"viewport info");
      require(sparse.stored_pixels==uint64_t(visibleWidth)*256*(mode==1?2:1),"viewport residency exact");
      require(vf_gpu_dmabuf_output_get_info(output,&info)==0 && info.idr==1,"viewport paired keyframe");
      alpha.resize(info.raw_alpha_bytes);
      require(vf_gpu_dmabuf_output_copy_raw_alpha(output,alpha.data(),alpha.size(),&required)==0,"viewport alpha");
      if(!visibleWidth) for(auto a:alpha) require(a==0,"off-screen atlas completely cleared");
      require(vf_gpu_dmabuf_output_destroy(output)==0,"viewport output cleanup");
    }
    require(vf_gpu_dmabuf_encoder_destroy(encoder)==0,"owned cleanup");
    std::printf("PASS native sparse mode=%u canvas=%ux%u stored_pixels=%llu patches=%u\n",mode,config.width,config.height,
      static_cast<unsigned long long>(sparse.stored_pixels),sparse.patch_count);
  }
}

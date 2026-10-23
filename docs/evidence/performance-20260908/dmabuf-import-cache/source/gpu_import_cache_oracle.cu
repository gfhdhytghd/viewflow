// Reuse the synthetic EGL exporter and independent H.264 decoder helpers.
#define main original_integration_main
#include "gpu_dmabuf_encoder_integration_test.cu"
#undef main
#include <algorithm>
#include <sys/stat.h>

int main(int argc, char** argv) {
  if (argc != 2) { std::fprintf(stderr, "usage: import-cache-oracle output.h264\n"); return 2; }
  W=3840; H=2400;
  Egl e;
  if (!ck(e.init(), "oracle EGL")) return 1;
  std::array<GLuint,5> textures{};
  glGenTextures(GLsizei(textures.size()),textures.data());
  std::vector<unsigned char> pixels(size_t(W)*H*4);
  for (auto tex:textures) {
    glBindTexture(GL_TEXTURE_2D,tex);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,W,H,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels.data());
  }
  std::array<Export,5> persistent;
  for(unsigned i=0;i<textures.size();++i)
    if (!ck(exportFrame(e,textures[i],persistent[i]),"export persistent storage")) return 1;
  std::FILE* dump=std::fopen(argv[1],"wb");
  const int routed=open("/dev/null",O_RDONLY|O_CLOEXEC);
  if (!ck(dump && routed>=0,"oracle output and reused fd")) return 1;
  {
    viewflow::gpu::GpuDmabufEncoder enc({W,H,4U*1024U*1024U});
    if (!ck(enc.ready(),"oracle encoder")) return 1;
    constexpr std::array<int,11> sequence{0,1,2,3,0,4,1,2,3,4,0};
    for (unsigned n=0;n<64;++n) {
      if (!ck(eglMakeCurrent(e.d,e.s,e.s,e.c)==EGL_TRUE,"restore producer")) return 1;
      const unsigned index=n<44 ? sequence[n%sequence.size()] : 0;
      const unsigned alpha=n%2 ? 192:128;
      const unsigned r=20+(n*7)%75,g=12+(n*11)%70,b=9+(n*13)%65;
      for(size_t i=0;i<pixels.size();i+=4){pixels[i]=r;pixels[i+1]=g;pixels[i+2]=b;pixels[i+3]=alpha;}
      glBindTexture(GL_TEXTURE_2D,textures[index]);
      glTexSubImage2D(GL_TEXTURE_2D,0,0,0,W,H,GL_RGBA,GL_UNSIGNED_BYTE,pixels.data());
      auto& x=persistent[index];
      const auto createSync=reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(eglGetProcAddress("eglCreateSyncKHR"));
      const auto dupSync=reinterpret_cast<PFNEGLDUPNATIVEFENCEFDANDROIDPROC>(eglGetProcAddress("eglDupNativeFenceFDANDROID"));
      const auto destroySync=reinterpret_cast<PFNEGLDESTROYSYNCKHRPROC>(eglGetProcAddress("eglDestroySyncKHR"));
      if (!ck(createSync && dupSync && destroySync,"native fence functions")) return 1;
      const auto sync=createSync(e.d,EGL_SYNC_NATIVE_FENCE_ANDROID,nullptr);
      glFlush();
      const int fence=sync==EGL_NO_SYNC_KHR ? -1 : dupSync(e.d,sync);
      if(sync!=EGL_NO_SYNC_KHR)destroySync(e.d,sync);
      if (!ck(fence>=0,"fresh fence for changed storage")) return 1;
      if(x.fence>=0)close(x.fence);
      x.fence=fence;
      if (!ck(dup2(x.fd,routed)==routed,"reuse the same numeric fd")) return 1;
      struct stat st{};
      if (!ck(fstat(routed,&st)==0,"storage inode")) return 1;
      viewflow::gpu::DmabufFrame in{};
      in.dmaBufFd=routed;in.nativeFenceFd=x.fence;in.imageWidth=W;in.imageHeight=H;
      in.stride=x.stride;in.offset=x.offset;in.modifier=x.modifier;in.fourcc=0x34324241U;
      in.cropWidth=W;in.cropHeight=H;in.metadata={n+1,1000+n,99};
      viewflow::gpu::EncodedDmabufFrame out;std::string error;
      auto disposition=viewflow::gpu::EncodeDisposition::Failed;
      if (!ck(enc.encode(in,true,deadlineNs(5000),out,&error,&disposition),error.c_str())) return 1;
      if (!ck(disposition==viewflow::gpu::EncodeDisposition::Encoded && out.metadata.frameId==n+1 && out.idr,"identity and IDR")) return 1;
      if (!ck(out.alpha().size()==size_t(W)*H && std::all_of(out.alpha().begin(),out.alpha().end(),[&](auto a){return a==alpha;}),"all alpha bytes exact")) return 1;
      if (!ck(decodedBt709LimitedMatches(out.colorAnnexB,r*255/alpha,g*255/alpha,b*255/alpha),"current texture color oracle")) return 1;
      if (!ck(std::fwrite(out.colorAnnexB.data(),1,out.colorAnnexB.size(),dump)==out.colorAnnexB.size(),"packet dump")) return 1;
      std::printf("cache-oracle frame=%u texture=%u fd=%d dev=%llu ino=%llu bytes=%zu alpha=%u correct=1\n",n+1,index,routed,(unsigned long long)st.st_dev,(unsigned long long)st.st_ino,out.colorAnnexB.size(),alpha);
    }
  }
  close(routed);std::fclose(dump);
  if (!ck(eglMakeCurrent(e.d,e.s,e.s,e.c)==EGL_TRUE,"final producer context")) return 1;
  glDeleteTextures(GLsizei(textures.size()),textures.data());
  std::printf("cache-oracle-result frames=64 textures=5 capacity_under_test=4 same_numeric_fd=1 alpha_bytes_checked=%llu color_frames_checked=64\n",(unsigned long long)64*W*H);
  return 0;
}

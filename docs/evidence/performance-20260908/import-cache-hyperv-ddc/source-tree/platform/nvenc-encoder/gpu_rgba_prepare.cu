#include "gpu_rgba_prepare.cuh"
#include <climits>
#include <cstdint>
#include <limits>
namespace viewflow::gpu {
namespace {
__device__ unsigned char up(unsigned char c, unsigned char a) {
  if (!a) return 0;
  return static_cast<unsigned char>(min((int(c)*255+a/2)/a,255));
}
__global__ void init(int* seam) { *seam=INT_MAX; }
__global__ void copyk(RgbaPrepare p) {
  size_t x=size_t(blockIdx.x)*blockDim.x+threadIdx.x, y=size_t(blockIdx.y)*blockDim.y+threadIdx.y;
  if(x>=size_t(p.width)||y>=size_t(p.height))return;
  size_t sy=p.cropY+(p.flipVertical?size_t(p.height)-1-y:y);
  auto s=p.src+sy*p.srcPitch+(p.cropX+x)*4;
  auto d=p.rgba+y*p.rgbaPitch+x*4;
  d[3]=s[3]; for(int i=0;i<3;i++)d[i]=up(s[i],s[3]);
  p.alpha[y*p.alphaPitch+x]=s[3];
}
__global__ void findk(RgbaPrepare p,int* seam) {
  int y=threadIdx.x;
  if(y<1||y>=min(p.height-1,96))return;
  int first=-1,last=-1,n=0;
  for(int x=0;x<p.width;x++) {
    auto a=[&](int yy){return p.rgba[size_t(yy)*p.rgbaPitch+size_t(x)*4+3];};
    if(a(y)<=4&&a(y-1)>=128&&a(y+1)>=128){if(first<0)first=x;last=x;n++;}
  }
  if(n>=max(16,p.width/3)&&first>=0&&last-first+1>=max(16,p.width/2))atomicMin(seam,y);
}
__global__ void repairk(RgbaPrepare p,const int* seam) {
  size_t x=size_t(blockIdx.x)*blockDim.x+threadIdx.x; int y=*seam;
  if(y==INT_MAX||x>=size_t(p.width))return;
  auto d=p.rgba+size_t(y)*p.rgbaPitch+x*4; auto s=d+p.rgbaPitch;
  if(d[3]<=4&&(d-p.rgbaPitch)[3]>=128&&s[3]>=128) {
    for(int i=0;i<4;i++)d[i]=s[i];p.alpha[size_t(y)*p.alphaPitch+x]=s[3];
  }
}
bool spanSize(size_t pitch,int height,size_t& bytes) {
  if(height<=0||pitch>SIZE_MAX/size_t(height))return false;
  bytes=pitch*size_t(height);return true;
}
bool overlap(const void* a,size_t as,const void* b,size_t bs) {
  auto av=reinterpret_cast<uintptr_t>(a),bv=reinterpret_cast<uintptr_t>(b);
  if(av>UINTPTR_MAX-as||bv>UINTPTR_MAX-bs)return true;
  return av<bv+bs&&bv<av+as;
}
}
cudaError_t prepareRgba(const RgbaPrepare& p,cudaStream_t stream) {
  if(!p.src||!p.rgba||!p.alpha||p.srcWidth<=0||p.srcHeight<=0||p.width<=0||p.height<=0||
     p.width>p.srcWidth||p.height>p.srcHeight||p.cropX<0||p.cropY<0||
     p.cropX>p.srcWidth-p.width||p.cropY>p.srcHeight-p.height||
     p.srcPitch<size_t(p.srcWidth)*4||p.rgbaPitch<size_t(p.width)*4||p.alphaPitch<size_t(p.width))
    return cudaErrorInvalidValue;
  size_t sb=0,rb=0,ab=0;
  if(!spanSize(p.srcPitch,p.srcHeight,sb)||!spanSize(p.rgbaPitch,p.height,rb)||
     !spanSize(p.alphaPitch,p.height,ab)||overlap(p.src,sb,p.rgba,rb)||
     overlap(p.src,sb,p.alpha,ab)||overlap(p.rgba,rb,p.alpha,ab))return cudaErrorInvalidValue;
  int* seam=nullptr;auto e=cudaMallocAsync(&seam,sizeof(int),stream);if(e)return e;
  init<<<1,1,0,stream>>>(seam);e=cudaGetLastError();
  if(e==cudaSuccess) {
    dim3 b(16,16),g((unsigned(p.width)+15)/16,(unsigned(p.height)+15)/16);
    copyk<<<g,b,0,stream>>>(p);e=cudaGetLastError();
  }
  if(e==cudaSuccess&&p.height>2) {
    findk<<<1,96,0,stream>>>(p,seam);e=cudaGetLastError();
    if(e==cudaSuccess){repairk<<<(unsigned(p.width)+255)/256,256,0,stream>>>(p,seam);e=cudaGetLastError();}
  }
  auto freed=cudaFreeAsync(seam,stream);
  return e==cudaSuccess?freed:e;
}
}

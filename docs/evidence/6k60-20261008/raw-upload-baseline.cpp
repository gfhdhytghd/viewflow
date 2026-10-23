#include <cuda.h>
#include <sys/mman.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
void check(CUresult r){if(r){const char* s=nullptr;cuGetErrorString(r,&s);fprintf(stderr,"CUDA: %s\n",s);exit(1);}}
int main(){check(cuInit(0));CUdevice dev;check(cuDeviceGet(&dev,0));CUcontext ctx;check(cuCtxCreate(&ctx,nullptr,0,dev));
constexpr size_t w=6144,h=3456,n=w*h*4;void* host=mmap(nullptr,n,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);if(host==MAP_FAILED)return 2;memset(host,0x5a,n);check(cuMemHostRegister(host,n,0));
CUdeviceptr dst;check(cuMemAlloc(&dst,n));CUDA_ARRAY_DESCRIPTOR desc{};desc.Width=w;desc.Height=h;desc.Format=CU_AD_FORMAT_UNSIGNED_INT8;desc.NumChannels=4;CUarray array;check(cuArrayCreate(&array,&desc));
for(int mode=0;mode<2;mode++){std::vector<double> times;CUDA_MEMCPY2D c{};c.srcMemoryType=CU_MEMORYTYPE_HOST;c.srcHost=host;c.srcPitch=w*4;c.dstMemoryType=mode?CU_MEMORYTYPE_ARRAY:CU_MEMORYTYPE_DEVICE;c.dstDevice=dst;c.dstArray=array;c.dstPitch=w*4;c.WidthInBytes=w*4;c.Height=h;
for(int i=0;i<140;i++){auto t=std::chrono::steady_clock::now();check(cuMemcpy2D(&c));check(cuCtxSynchronize());double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t).count();if(i>=20)times.push_back(ms);}std::sort(times.begin(),times.end());printf("%s bytes=%zu samples=%zu median_ms=%.4f p95_ms=%.4f median_GBps=%.3f\n",mode?"registered_host_to_array":"registered_host_to_linear",n,times.size(),times[60],times[114],n/times[60]/1e6);
std::vector<unsigned char> back(n);CUDA_MEMCPY2D r{};r.srcMemoryType=c.dstMemoryType;r.srcDevice=dst;r.srcArray=array;r.srcPitch=w*4;r.dstMemoryType=CU_MEMORYTYPE_HOST;r.dstHost=back.data();r.dstPitch=w*4;r.WidthInBytes=w*4;r.Height=h;check(cuMemcpy2D(&r));if(memcmp(host,back.data(),n))return 3;puts("byte_verification=pass");}
check(cuArrayDestroy(array));check(cuMemFree(dst));check(cuMemHostUnregister(host));munmap(host,n);check(cuCtxDestroy(ctx));}

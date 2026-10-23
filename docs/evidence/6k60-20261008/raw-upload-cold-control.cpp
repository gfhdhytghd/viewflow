#include <cuda.h>
#include <cudaGL.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <stdexcept>
#include <sys/mman.h>
#include <unistd.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <thread>
#include <immintrin.h>
void check(CUresult r){if(r){const char* s=nullptr;cuGetErrorString(r,&s);fprintf(stderr,"CUDA: %s\n",s);exit(1);}}
int main(int argc,char** argv){
const bool cold=argc>3 && !strcmp(argv[3],"--cold");printf("flush_before_transfer=%d\n",cold);
const bool paced=argc>2 && !strcmp(argv[2],"--paced");printf("cadence=%s\n",paced?"60Hz":"unpaced");
    auto query=reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
    auto get_display=reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    EGLDeviceEXT devices[8]{};EGLint count{};if(!query || !get_display || !query(8,devices,&count) || !count)throw std::runtime_error("probe EGL devices");
    auto display=get_display(EGL_PLATFORM_DEVICE_EXT,devices[0],nullptr);
    if(!eglInitialize(display,nullptr,nullptr) || !eglBindAPI(EGL_OPENGL_ES_API))throw std::runtime_error("probe EGL init");
    const EGLint attrs[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config{};if(!eglChooseConfig(display,attrs,&config,1,&count) || !count)throw std::runtime_error("probe EGL config");
    const EGLint size[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE},version[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    auto surface=eglCreatePbufferSurface(display,config,size);auto context=eglCreateContext(display,config,EGL_NO_CONTEXT,version);
    if(!eglMakeCurrent(display,surface,surface,context))throw std::runtime_error("probe EGL context");

 printf("renderer=%s\n",glGetString(GL_RENDERER));
 check(cuInit(0));CUdevice dev;unsigned device_count=0;check(cuGLGetDevices(&device_count,&dev,1,CU_GL_DEVICE_LIST_CURRENT_FRAME));if(!device_count)return 4;CUcontext ctx;check(cuCtxCreate(&ctx,nullptr,0,dev));
constexpr size_t w=6144,h=3456,n=w*h*4;int fd=-1;const bool shared=argc>1 && !strcmp(argv[1],"--tmpfs");
if(shared){char name[]="/dev/shm/viewflow-upload-probe-XXXXXX";fd=mkstemp(name);if(fd<0)return 5;unlink(name);if(ftruncate(fd,n))return 6;}
printf("source=%s\n",shared?"isolated_tmpfs_shared":"anonymous_private");
void* host=mmap(nullptr,n,PROT_READ|PROT_WRITE,shared?MAP_SHARED:MAP_PRIVATE|MAP_ANONYMOUS,fd,0);if(fd>=0)close(fd);if(host==MAP_FAILED)return 2;for(size_t j=0;j<n;j++)static_cast<unsigned char*>(host)[j]=static_cast<unsigned char>((j*17+(j/24576)*31+(j>>16))%251);check(cuMemHostRegister(host,n,0));
CUdeviceptr dst;check(cuMemAlloc(&dst,n));CUDA_ARRAY_DESCRIPTOR desc{};desc.Width=w;desc.Height=h;desc.Format=CU_AD_FORMAT_UNSIGNED_INT8;desc.NumChannels=4;CUarray array;check(cuArrayCreate(&array,&desc));
CUarray owned_array=array;GLuint texture;glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,w,h);glFinish();CUgraphicsResource resource;check(cuGraphicsGLRegisterImage(&resource,texture,GL_TEXTURE_2D,CU_GRAPHICS_REGISTER_FLAGS_WRITE_DISCARD));
CUstream private_stream;check(cuStreamCreate(&private_stream,CU_STREAM_NON_BLOCKING));
for(int strategy=0;strategy<3;strategy++){CUstream stream=strategy==2?private_stream:nullptr;printf("strategy=%s\n",strategy==0?"sync":strategy==1?"async_default_wait":"async_nonblocking_wait");
for(int mode=0;mode<3;mode++){array=owned_array;std::vector<double> times;CUDA_MEMCPY2D c{};c.srcMemoryType=CU_MEMORYTYPE_HOST;c.srcHost=host;c.srcPitch=w*4;c.dstMemoryType=mode?CU_MEMORYTYPE_ARRAY:CU_MEMORYTYPE_DEVICE;c.dstDevice=dst;c.dstArray=array;c.dstPitch=w*4;c.WidthInBytes=w*4;c.Height=h;
auto deadline=std::chrono::steady_clock::now();for(int i=0;i<140;i++){if(paced){deadline+=std::chrono::nanoseconds(16666667);std::this_thread::sleep_until(deadline);}if(cold){for(size_t j=0;j<n;j+=64)_mm_clflush(static_cast<char*>(host)+j);_mm_mfence();}auto t=std::chrono::steady_clock::now();if(mode==2){check(cuGraphicsMapResources(1,&resource,stream));check(cuGraphicsSubResourceGetMappedArray(&c.dstArray,resource,0,0));}if(strategy)check(cuMemcpy2DAsync(&c,stream));else check(cuMemcpy2D(&c));if(mode==2)check(cuGraphicsUnmapResources(1,&resource,stream));check(cuStreamSynchronize(stream));double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t).count();if(i>=20)times.push_back(ms);}std::sort(times.begin(),times.end());printf("%s bytes=%zu samples=%zu median_ms=%.4f p95_ms=%.4f median_GBps=%.3f\n",mode==2?"registered_host_to_GL_texture":mode?"registered_host_to_array":"registered_host_to_linear",n,times.size(),times[60],times[114],n/times[60]/1e6);
if(mode==2){check(cuGraphicsMapResources(1,&resource,stream));check(cuGraphicsSubResourceGetMappedArray(&array,resource,0,0));}
check(cuStreamSynchronize(stream));std::vector<unsigned char> back(n);CUDA_MEMCPY2D r{};r.srcMemoryType=c.dstMemoryType;r.srcDevice=dst;r.srcArray=array;r.srcPitch=w*4;r.dstMemoryType=CU_MEMORYTYPE_HOST;r.dstHost=back.data();r.dstPitch=w*4;r.WidthInBytes=w*4;r.Height=h;check(cuMemcpy2D(&r));if(memcmp(host,back.data(),n))return 3;puts("byte_verification=pass");if(mode==2)check(cuGraphicsUnmapResources(1,&resource,stream));}
check(cuStreamSynchronize(stream));}
check(cuStreamDestroy(private_stream));check(cuGraphicsUnregisterResource(resource));glDeleteTextures(1,&texture);check(cuArrayDestroy(owned_array));check(cuMemFree(dst));check(cuMemHostUnregister(host));munmap(host,n);check(cuCtxDestroy(ctx));}

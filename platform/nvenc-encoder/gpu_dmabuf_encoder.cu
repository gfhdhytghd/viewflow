#include "gpu_dmabuf_encoder.cuh"
#include "gpu_import_cleanup.hpp"
#include "gpu_rgba_prepare.cuh"
#include "gpu_shadow_repair.cuh"
#include "gpu_atlas_compose.cuh"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <atomic>
#include <cuda.h>
#include <cuda_gl_interop.h>
#include <cuda_runtime_api.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_cuda.h>
#include <libavutil/opt.h>
}
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <thread>
#include <unistd.h>

#ifdef VIEWFLOW_TEST_GPU_EXPIRY
static thread_local unsigned testExpiryStage = 0;
extern "C" void vf_test_expire_gpu_preparation(unsigned stage) { testExpiryStage = stage; }
#endif

namespace viewflow::gpu {
namespace {
constexpr std::uint32_t kAb24 = 0x34324241U;
std::atomic<unsigned> timingSamples{0};
bool before(std::int64_t deadline) {
  timespec t{};
  return clock_gettime(CLOCK_MONOTONIC, &t) == 0 &&
         (std::int64_t(t.tv_sec) * 1000000000LL + t.tv_nsec) < deadline;
}
void fail(std::string *out, const char *text) {
  if (out)
    *out = text;
}
bool injectedPreparationExpiry(unsigned stage) {
#ifdef VIEWFLOW_TEST_GPU_EXPIRY
  if (testExpiryStage == stage) {
    testExpiryStage = 0;
    return true;
  }
#else
  (void)stage;
#endif
  return false;
}
bool preparationBefore(std::int64_t deadline, unsigned stage) {
  return !injectedPreparationExpiry(stage) && before(deadline);
}
bool cudaOk(cudaError_t e, std::string *out, const char *op) {
  if (e == cudaSuccess)
    return true;
  if (out)
    *out = std::string(op) + ": " + cudaGetErrorString(e);
  return false;
}
bool avOk(int e, std::string *out, const char *op) {
  if (e >= 0)
    return true;
  char b[AV_ERROR_MAX_STRING_SIZE]{};
  av_strerror(e, b, sizeof(b));
  if (out)
    *out = std::string(op) + ": " + b;
  return false;
}
bool idr(const std::vector<unsigned char> &b) {
  for (size_t i = 0; i + 4 < b.size(); ++i) {
    size_t n = (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1)
                   ? i + 3
                   : (i + 4 < b.size() && b[i] == 0 && b[i + 1] == 0 &&
                              b[i + 2] == 0 && b[i + 3] == 1
                          ? i + 4
                          : b.size());
    if (n < b.size() && (b[n] & 31) == 5)
      return true;
  }
  return false;
}
__global__ void nv12(const unsigned char *rgba, size_t rp, unsigned char *y,
                     size_t yp, unsigned char *uv, size_t up, int w, int h) {
  const int x = int(blockIdx.x * blockDim.x + threadIdx.x),
            yy = int(blockIdx.y * blockDim.y + threadIdx.y);
  if (x >= w || yy >= h)
    return;
  const unsigned char *p = rgba + size_t(yy) * rp + size_t(x) * 4;
  const int r = p[0], g = p[1], b = p[2];
  // BT.709 limited-range Y'CbCr. These coefficients and the VUI below are the
  // transport colour contract; do not substitute the BT.601 capture-probe
  // matrix here.
  y[size_t(yy) * yp + x] =
      static_cast<unsigned char>((47 * r + 157 * g + 16 * b + 128) >> 8) + 16;
  if ((x & 1) || (yy & 1))
    return;
  const int sx = min(x + 1, w - 1), sy = min(yy + 1, h - 1);
  int sr = 0, sg = 0, sb = 0;
  for (int j = yy; j <= sy; ++j)
    for (int i = x; i <= sx; ++i) {
      const unsigned char *q = rgba + size_t(j) * rp + size_t(i) * 4;
      sr += q[0];
      sg += q[1];
      sb += q[2];
    }
  const int c = (sx - x + 1) * (sy - yy + 1);
  unsigned char *q = uv + size_t(yy / 2) * up + x;
  q[0] = static_cast<unsigned char>(
             (-26 * (sr / c) - 87 * (sg / c) + 112 * (sb / c) + 128) >> 8) +
         128;
  q[1] = static_cast<unsigned char>(
             (112 * (sr / c) - 102 * (sg / c) - 10 * (sb / c) + 128) >> 8) +
         128;
}
} // namespace

struct GpuDmabufEncoder::Impl {
  GpuDmabufEncoderConfig config;
  std::thread::id owner;
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLSurface surface = EGL_NO_SURFACE;
  EGLContext context = EGL_NO_CONTEXT;
  GLuint texture = 0;
  cudaStream_t stream = nullptr;
  unsigned char *src = nullptr, *rgba = nullptr, *alpha = nullptr;
  size_t srcPitch = 0, rgbaPitch = 0, alphaPitch = 0;
  AVBufferRef *device = nullptr, *frames = nullptr;
  AVCodecContext *encoder = nullptr;
  bool good = false;
  bool poisoned = false;
  bool recoveryIdr = false;
  bool timingsEnabled = false;
  ~Impl() {
    if (encoder)
      avcodec_free_context(&encoder);
    if (frames)
      av_buffer_unref(&frames);
    if (device)
      av_buffer_unref(&device);
    if (src)
      cudaFree(src);
    if (rgba)
      cudaFree(rgba);
    if (alpha)
      cudaFree(alpha);
    if (stream)
      cudaStreamDestroy(stream);
    if (display != EGL_NO_DISPLAY) {
      // EGLDisplay is process-lifetime shared state.  Only this context/surface
      // are owned; never eglTerminate a default/device display another encoder
      // may still be using.
      const EGLDisplay previousDisplay = eglGetCurrentDisplay();
      const EGLContext previousContext = eglGetCurrentContext();
      const EGLSurface previousDraw = eglGetCurrentSurface(EGL_DRAW);
      const EGLSurface previousRead = eglGetCurrentSurface(EGL_READ);
      const bool ownCurrent = context != EGL_NO_CONTEXT &&
                              eglMakeCurrent(display, surface, surface, context) == EGL_TRUE;
      // If our context cannot be made current, do not issue a name-based GL
      // delete into whichever context happens to be current. Context teardown
      // still reclaims its owned objects.
      if (texture && ownCurrent)
        glDeleteTextures(1, &texture);
      eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      if (context != EGL_NO_CONTEXT)
        eglDestroyContext(display, context);
      if (surface != EGL_NO_SURFACE)
        eglDestroySurface(display, surface);
      if (previousContext != EGL_NO_CONTEXT && previousContext != context)
        eglMakeCurrent(previousDisplay, previousDraw, previousRead,
                       previousContext);
    }
  }
  bool init(std::string *error) {
    owner = std::this_thread::get_id();
    const char *timings = std::getenv("VIEWFLOW_GPU_TIMINGS");
    timingsEnabled = timings && std::strcmp(timings, "1") == 0;
    if (config.outputWidth < 2 || config.outputHeight < 2 ||
        (config.outputWidth & 1) || (config.outputHeight & 1)) {
      fail(error, "output dimensions must be positive even");
      return false;
    }
    display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint ma = 0, mi = 0;
    if (display == EGL_NO_DISPLAY ||
        eglInitialize(display, &ma, &mi) != EGL_TRUE) {
      auto query = reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(
          eglGetProcAddress("eglQueryDevicesEXT"));
      auto get = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
          eglGetProcAddress("eglGetPlatformDisplayEXT"));
      EGLDeviceEXT device{};
      EGLint count = 0;
      if (!query || !get || query(1, &device, &count) != EGL_TRUE ||
          count != 1 ||
          (display = get(EGL_PLATFORM_DEVICE_EXT, device, nullptr)) ==
              EGL_NO_DISPLAY ||
          eglInitialize(display, &ma, &mi) != EGL_TRUE) {
        fail(error, "eglInitialize");
        return false;
      }
    }
    if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
      fail(error, "eglBindAPI");
      return false;
    }
    const EGLint a[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE,
                        EGL_OPENGL_ES3_BIT_KHR, EGL_NONE};
    EGLConfig c{};
    EGLint n = 0;
    if (eglChooseConfig(display, a, &c, 1, &n) != EGL_TRUE || n != 1) {
      fail(error, "eglChooseConfig");
      return false;
    }
    const EGLint p[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    const EGLint ca[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    surface = eglCreatePbufferSurface(display, c, p);
    context = eglCreateContext(display, c, EGL_NO_CONTEXT, ca);
    if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT ||
        eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
      fail(error, "EGL context");
      return false;
    }
    unsigned count = 0;
    int gpu = -1;
    if (!cudaOk(cudaGLGetDevices(&count, &gpu, 1, cudaGLDeviceListAll), error,
                "cudaGLGetDevices") ||
        count != 1 || !cudaOk(cudaSetDevice(gpu), error, "cudaSetDevice") ||
        !cudaOk(cudaFree(nullptr), error, "CUDA primary context") ||
        !cudaOk(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking),
                error, "cudaStreamCreate"))
      return false;
    if (!cudaOk(cudaMallocPitch(reinterpret_cast<void **>(&src), &srcPitch,
                                size_t(config.outputWidth) * 4,
                                config.outputHeight),
                error, "cudaMallocPitch src") ||
        !cudaOk(cudaMallocPitch(reinterpret_cast<void **>(&rgba), &rgbaPitch,
                                size_t(config.outputWidth) * 4,
                                config.outputHeight),
                error, "cudaMallocPitch rgba") ||
        !cudaOk(cudaMallocPitch(reinterpret_cast<void **>(&alpha), &alphaPitch,
                                config.outputWidth, config.outputHeight),
                error, "cudaMallocPitch alpha"))
      return false;
    CUcontext current = nullptr;
    if (cuCtxGetCurrent(&current) != CUDA_SUCCESS || !current) {
      fail(error, "CUDA primary context unavailable");
      return false;
    }
    device = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_CUDA);
    if (!device) {
      fail(error, "av_hwdevice_ctx_alloc");
      return false;
    }
    auto *dc = reinterpret_cast<AVHWDeviceContext *>(device->data);
    reinterpret_cast<AVCUDADeviceContext *>(dc->hwctx)->cuda_ctx = current;
    if (!avOk(av_hwdevice_ctx_init(device), error, "av_hwdevice_ctx_init"))
      return false;
    frames = av_hwframe_ctx_alloc(device);
    if (!frames) {
      fail(error, "av_hwframe_ctx_alloc");
      return false;
    }
    auto *fc = reinterpret_cast<AVHWFramesContext *>(frames->data);
    fc->format = AV_PIX_FMT_CUDA;
    fc->sw_format = AV_PIX_FMT_NV12;
    fc->width = config.outputWidth;
    fc->height = config.outputHeight;
    fc->initial_pool_size = 1;
    if (!avOk(av_hwframe_ctx_init(frames), error, "av_hwframe_ctx_init"))
      return false;
    const AVCodec *codec = avcodec_find_encoder_by_name(config.colorCodec == 4 ? "av1_nvenc" : "h264_nvenc");
    if (!codec) {
      fail(error, "requested NVENC encoder unavailable");
      return false;
    }
    encoder = avcodec_alloc_context3(codec);
    if (!encoder) {
      fail(error, "avcodec_alloc_context3");
      return false;
    }
    encoder->width = config.outputWidth;
    encoder->height = config.outputHeight;
    encoder->pix_fmt = AV_PIX_FMT_CUDA;
    encoder->time_base = {1, 1000000000};
    encoder->framerate = {60, 1};
    encoder->max_b_frames = 0;
    // Keep the stream decodable after a dropped AU without making every frame
    // an IDR.  With no B frames, this is a persistent low-latency P-frame GOP.
    encoder->gop_size = 120;
    encoder->profile = config.colorCodec == 4 ? AV_PROFILE_AV1_MAIN : AV_PROFILE_H264_HIGH;
    encoder->color_range = AVCOL_RANGE_MPEG;
    encoder->color_primaries = AVCOL_PRI_BT709;
    encoder->color_trc = AVCOL_TRC_BT709;
    encoder->colorspace = AVCOL_SPC_BT709;
    encoder->hw_frames_ctx = av_buffer_ref(frames);
    if (!encoder->hw_frames_ctx ||
        !avOk(av_opt_set(encoder->priv_data, "preset", "p1", 0), error,
              "NVENC preset") ||
        !avOk(av_opt_set(encoder->priv_data, "tune", "ull", 0), error,
              "NVENC tune") ||
        !avOk(av_opt_set(encoder->priv_data, "zerolatency", "1", 0), error,
              "NVENC zerolatency") ||
        !avOk(av_opt_set(encoder->priv_data, "delay", "0", 0), error,
              "NVENC delay") ||
        !avOk(av_opt_set(encoder->priv_data, "rc-lookahead", "0", 0), error,
              "NVENC lookahead") ||
        !avOk(av_opt_set(encoder->priv_data, "forced-idr", "1", 0), error,
              "NVENC forced IDR") ||
        !avOk(av_opt_set(encoder->priv_data, "rc", "constqp", 0), error,
              "NVENC rc") ||
        !avOk(av_opt_set(encoder->priv_data, "qp", "10", 0), error,
              "NVENC qp") ||
        (config.colorCodec == 2 && !avOk(av_opt_set(encoder->priv_data, "profile", "high", 0), error,
              "NVENC High profile")) ||
        !avOk(avcodec_open2(encoder, codec, nullptr), error, "avcodec_open2"))
      return false;
    glGenTextures(1, &texture);
    good = true;
    return true;
  }
};

GpuDmabufEncoder::GpuDmabufEncoder(const GpuDmabufEncoderConfig &c,
                                   std::string *e)
    : impl_(new Impl) {
  impl_->config = c;
  impl_->init(e);
}
GpuDmabufEncoder::~GpuDmabufEncoder() = default;
GpuDmabufEncoder::GpuDmabufEncoder(GpuDmabufEncoder &&) noexcept = default;
GpuDmabufEncoder &
GpuDmabufEncoder::operator=(GpuDmabufEncoder &&) noexcept = default;
bool GpuDmabufEncoder::ready() const { return impl_ && impl_->good; }
bool GpuDmabufEncoder::encode(const DmabufFrame &input, bool forceIdr,
                              std::int64_t deadline, EncodedDmabufFrame &output,
                              std::string *error, EncodeDisposition *disposition) {
  // Preserve the original single-window resize contract.
  if (!impl_ || input.cropWidth != impl_->config.outputWidth ||
      input.cropHeight != impl_->config.outputHeight) {
    output = {};
    if (disposition) *disposition = EncodeDisposition::Failed;
    fail(error, "unsupported DMA-BUF frame or resize; make a new encoder");
    return false;
  }
  return encodeAtlas({{input, 0, 0, deadline}}, input.metadata, forceIdr,
                     deadline, output, error, disposition);
}

bool GpuDmabufEncoder::encodeAtlas(const std::vector<DmabufAtlasTile>& inputs,
                              FrameMetadata metadata, bool forceIdr,
                              std::int64_t deadline, EncodedDmabufFrame &output,
                              std::string *error, EncodeDisposition *disposition) {
  if (disposition) *disposition = EncodeDisposition::Failed;
  output = {};
  if (!ready() || impl_->poisoned ||
      std::this_thread::get_id() != impl_->owner) {
    fail(error,
         "encoder must be created, used, and destroyed on one worker thread");
    return false;
  }
  forceIdr = forceIdr || impl_->recoveryIdr;
  if (inputs.size() > 4096 || metadata.frameId == 0 || metadata.geometryEpoch == 0 ||
      metadata.captureTimestampNs == 0 || metadata.captureTimestampNs > std::uint64_t(INT64_MAX)) {
    fail(error, "invalid atlas metadata or tile count");
    return false;
  }
  for (const auto& tile : inputs)
    if (tile.absoluteMonotonicDeadlineNs < deadline)
      deadline = tile.absoluteMonotonicDeadlineNs;
  if (!before(deadline)) {
    fail(error, "frame deadline expired before admission");
    // Nothing has imported/read a producer allocation at this point.
    if (disposition) *disposition = EncodeDisposition::ExpiredBeforeSubmission;
    return false;
  }
  if (eglMakeCurrent(impl_->display, impl_->surface, impl_->surface,
                     impl_->context) != EGL_TRUE) {
    fail(error, "encoder EGL context is not current");
    return false;
  }
  for (size_t i = 0; i < inputs.size(); ++i) {
  const auto& tile = inputs[i];
  const auto& input = tile.frame;
  if (input.dmaBufFd < 0 || input.nativeFenceFd < 0 || input.fourcc != kAb24 ||
      input.imageWidth == 0 || input.imageHeight == 0 ||
      input.imageWidth > INT_MAX || input.imageHeight > INT_MAX ||
      input.stride > INT_MAX || input.offset > INT_MAX ||
      size_t(input.stride) < size_t(input.imageWidth) * 4 || input.cropX < 0 ||
      input.cropY < 0 || input.cropWidth <= 0 || input.cropHeight <= 0 ||
      input.cropWidth > impl_->config.outputWidth || input.cropHeight > impl_->config.outputHeight ||
      tile.x < 0 || tile.y < 0 || tile.x > impl_->config.outputWidth - input.cropWidth ||
      tile.y > impl_->config.outputHeight - input.cropHeight ||
      input.cropX > int(input.imageWidth) - input.cropWidth ||
      input.cropY > int(input.imageHeight) - input.cropHeight ||
      input.metadata.frameId == 0 || input.metadata.geometryEpoch == 0 ||
      input.metadata.captureTimestampNs == 0 ||
      input.metadata.captureTimestampNs > std::uint64_t(INT64_MAX)) {
    fail(error, "unsupported DMA-BUF frame or resize; make a new encoder");
    return false;
  }
  for (size_t j = 0; j < i; ++j) {
    const auto& other = inputs[j];
    if (tile.x < other.x + other.frame.cropWidth && other.x < tile.x + input.cropWidth &&
        tile.y < other.y + other.frame.cropHeight && other.y < tile.y + input.cropHeight) {
      fail(error, "overlapping atlas tiles");
      return false;
    }
  }
  }
  const unsigned timingSample = impl_->timingsEnabled
                                    ? timingSamples.fetch_add(1)
                                    : 5;
  const bool logTimings = impl_->timingsEnabled && (timingSample < 5 || timingSample % 60 == 0);
  const auto totalStart = logTimings ? std::chrono::steady_clock::now()
                                     : std::chrono::steady_clock::time_point{};
  auto fenceDone = totalStart;
  auto importDone = totalStart;
  auto copyPrepareDone = totalStart;
  auto nv12ReadbackDone = totalStart;
  auto nvencDone = totalStart;
  auto outputDone = totalStart;
  const bool direct = inputs.size() == 1 && inputs[0].x == 0 && inputs[0].y == 0 &&
      inputs[0].frame.cropWidth == impl_->config.outputWidth && inputs[0].frame.cropHeight == impl_->config.outputHeight;
  struct PreparedTiles {
    std::vector<AtlasTile> tiles;
    ~PreparedTiles() { for (const auto& tile : tiles) cudaFree(const_cast<unsigned char*>(tile.rgba)); }
  } prepared;
  prepared.tiles.reserve(inputs.size());
  for (const auto& tile : inputs) {
  const auto& input = tile.frame;
  timespec now{};
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    fail(error, "read monotonic clock before fence wait");
    return false;
  }
  const std::int64_t remain =
      deadline - (std::int64_t(now.tv_sec) * 1000000000LL + now.tv_nsec);
  if (remain <= 0 || injectedPreparationExpiry(prepared.tiles.empty() ? 3 : 4)) {
    fail(error, "frame deadline expired before fence wait");
    // No resources for this tile have been imported. Every previous tile
    // completed its stream synchronization and imported-image cleanup before
    // the loop advanced; no source reads or NVENC submission remain pending.
    if (disposition) *disposition = EncodeDisposition::ExpiredBeforeSubmission;
    return false;
  }
  const int fenceFd = fcntl(input.nativeFenceFd, F_DUPFD_CLOEXEC, 3);
  if (fenceFd < 0) {
    fail(error, "dup native fence");
    return false;
  }
  const std::int64_t timeoutMs = (remain + 999999) / 1000000;
  pollfd fence{fenceFd, POLLIN, 0};
  if (poll(&fence, 1, timeoutMs > INT_MAX ? INT_MAX : int(timeoutMs)) != 1 ||
      (fence.revents & POLLIN) == 0 || (fence.revents & (POLLERR | POLLNVAL))) {
    close(fenceFd);
    fail(error, "native fence did not signal before deadline");
    return false;
  }
  close(fenceFd);
  if (!before(deadline)) {
    fail(error, "frame deadline expired after fence wait");
    return false;
  }
  if (logTimings)
    fenceDone = std::chrono::steady_clock::now();
  const int fd = fcntl(input.dmaBufFd, F_DUPFD_CLOEXEC, 3);
  if (fd < 0) {
    fail(error, "dup DMA-BUF");
    return false;
  }
  EGLImageKHR image = EGL_NO_IMAGE_KHR;
  cudaGraphicsResource_t resource = nullptr;
  AVFrame *frame = nullptr;
  bool mapped = false;
  auto destroyImage = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
      eglGetProcAddress("eglDestroyImageKHR"));
  auto cleanup = [&] {
    const bool cleaned = cleanupImportedImage(resource != nullptr, mapped,
        image != EGL_NO_IMAGE_KHR,
        [&] { return cudaGraphicsUnmapResources(1, &resource, impl_->stream) == cudaSuccess; },
        [&] { return cudaGraphicsUnregisterResource(resource) == cudaSuccess; },
        [&] { return destroyImage && destroyImage(impl_->display, image) == EGL_TRUE; },
        error);
    close(fd);
    av_frame_free(&frame);
    if (!cleaned) impl_->poisoned = true;
    return cleaned;
  };
  auto create = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
      eglGetProcAddress("eglCreateImageKHR"));
  auto target = reinterpret_cast<void (*)(GLenum, void *)>(
      eglGetProcAddress("glEGLImageTargetTexture2DOES"));
  const EGLint at[] = {EGL_WIDTH,
                       EGLint(input.imageWidth),
                       EGL_HEIGHT,
                       EGLint(input.imageHeight),
                       EGL_LINUX_DRM_FOURCC_EXT,
                       EGLint(input.fourcc),
                       EGL_DMA_BUF_PLANE0_FD_EXT,
                       fd,
                       EGL_DMA_BUF_PLANE0_OFFSET_EXT,
                       EGLint(input.offset),
                       EGL_DMA_BUF_PLANE0_PITCH_EXT,
                       EGLint(input.stride),
                       EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,
                       EGLint(input.modifier),
                       EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,
                       EGLint(input.modifier >> 32),
                       EGL_NONE};
  if (!create || !target ||
      (image = create(impl_->display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT,
                      nullptr, at)) == EGL_NO_IMAGE_KHR) {
    fail(error, "EGL DMA-BUF import");
    cleanup();
    return false;
  }
  // Isolate stale producer-side GL errors; only an error generated by this
  // import bind/target is authoritative for this frame identity.
  while (glGetError() != GL_NO_ERROR) {}
  glBindTexture(GL_TEXTURE_2D, impl_->texture);
  target(GL_TEXTURE_2D, image);
  if (glGetError() != GL_NO_ERROR) {
    fail(error, "EGLImage GL texture binding");
    cleanup();
    return false;
  }
  glFinish();
  if (!cudaOk(cudaGraphicsGLRegisterImage(&resource, impl_->texture,
                                          GL_TEXTURE_2D,
                                          cudaGraphicsRegisterFlagsReadOnly),
              error, "cuda register imported image") ||
      !cudaOk(cudaGraphicsMapResources(1, &resource, impl_->stream), error,
              "cuda map imported image")) {
    cleanup();
    return false;
  }
  mapped = true;
  if (logTimings)
    importDone = std::chrono::steady_clock::now();
  cudaArray_t array = nullptr;
  if (!cudaOk(cudaGraphicsSubResourceGetMappedArray(&array, resource, 0, 0),
              error, "cuda mapped array") ||
      !cudaOk(cudaMemcpy2DFromArrayAsync(
                  impl_->src, impl_->srcPitch, array, size_t(input.cropX) * 4,
                  input.cropY, size_t(input.cropWidth) * 4, input.cropHeight,
                  cudaMemcpyDeviceToDevice, impl_->stream),
              error, "copy imported RGBA")) {
    cudaGraphicsUnmapResources(1, &resource, impl_->stream);
    mapped = false;
    cleanup();
    return false;
  }
  if (!cudaOk(prepareRgba(
                  {impl_->src, impl_->srcPitch, input.cropWidth,
                   input.cropHeight, 0, 0, input.cropWidth,
                   input.cropHeight, input.flipVertical, impl_->rgba,
                   impl_->rgbaPitch, impl_->alpha, impl_->alphaPitch},
                  impl_->stream),
              error, "prepare RGBA")) {
    cudaGraphicsUnmapResources(1, &resource, impl_->stream);
    mapped = false;
    cleanup();
    return false;
  }
  if (input.shadow &&
      !cudaOk(repairShadow({impl_->rgba, impl_->rgbaPitch, impl_->alpha,
                            impl_->alphaPitch, input.cropWidth,
                            input.cropHeight, *input.shadow},
                           impl_->stream),
              error, "repair shadow")) {
    cudaGraphicsUnmapResources(1, &resource, impl_->stream);
    mapped = false;
    cleanup();
    return false;
  }
  const cudaError_t unmapResult =
      cudaGraphicsUnmapResources(1, &resource, impl_->stream);
  mapped = false;
  if (!cudaOk(unmapResult, error, "cuda unmap imported image") ||
      !cudaOk(cudaStreamSynchronize(impl_->stream), error,
              "import/prepare completion")) {
    // Preserve the CUDA operation and driver error. A failed preparation is
    // not evidence of a deadline miss, even when the deadline has also passed.
    cleanup();
    return false;
  }
  if (!preparationBefore(deadline, 1)) {
    fail(error, "frame deadline expired after GPU preparation");
    if (cleanup() && disposition)
      *disposition = EncodeDisposition::ExpiredBeforeSubmission;
    return false;
  }
  if (!direct) {
    unsigned char* pixels = nullptr;
    size_t pitch = 0;
    if (!cudaOk(cudaMallocPitch(&pixels, &pitch, size_t(input.cropWidth) * 4,
                               input.cropHeight), error, "allocate prepared atlas tile")) {
      cleanup();
      return false;
    }
    prepared.tiles.push_back({pixels, pitch, input.cropWidth, input.cropHeight, tile.x, tile.y});
    if (!cudaOk(cudaMemcpy2DAsync(pixels, pitch, impl_->rgba, impl_->rgbaPitch,
                                 size_t(input.cropWidth) * 4, input.cropHeight,
                                 cudaMemcpyDeviceToDevice, impl_->stream), error, "retain prepared atlas tile") ||
        !cudaOk(cudaStreamSynchronize(impl_->stream), error, "atlas tile copy completion")) {
      cleanup();
      return false;
    }
  }
  if (!cleanup()) return false;
  }
  AVFrame* frame = nullptr;
  bool ok = false;
  // Every imported image has been retired before composition/submission.
  auto cleanup = [&] { av_frame_free(&frame); return true; };
  if (!direct && (!cudaOk(composeAtlas(prepared.tiles.data(), prepared.tiles.size(),
                       {impl_->rgba, impl_->rgbaPitch, impl_->alpha, impl_->alphaPitch,
                        impl_->config.outputWidth, impl_->config.outputHeight}, impl_->stream),
                       error, "compose prepared atlas") ||
                  !cudaOk(cudaStreamSynchronize(impl_->stream), error, "atlas composition completion"))) {
    impl_->poisoned = true;
    return false;
  }
  if (!before(deadline)) {
    fail(error, "atlas deadline expired before NVENC preparation");
    if (disposition) *disposition = EncodeDisposition::ExpiredBeforeSubmission;
    return false;
  }
  if (logTimings)
    copyPrepareDone = std::chrono::steady_clock::now();
  frame = av_frame_alloc();
  if (!frame ||
      !avOk(av_hwframe_get_buffer(impl_->encoder->hw_frames_ctx, frame, 0),
            error, "NV12 frame")) {
    cleanup();
    return false;
  }
  frame->color_range = AVCOL_RANGE_MPEG;
  frame->color_primaries = AVCOL_PRI_BT709;
  frame->color_trc = AVCOL_TRC_BT709;
  frame->colorspace = AVCOL_SPC_BT709;
  dim3 b(16, 16), g((impl_->config.outputWidth + 15) / 16,
                    (impl_->config.outputHeight + 15) / 16);
  nv12<<<g, b, 0, impl_->stream>>>(
      impl_->rgba, impl_->rgbaPitch, frame->data[0], frame->linesize[0],
      frame->data[1], frame->linesize[1], impl_->config.outputWidth,
      impl_->config.outputHeight);
  std::vector<unsigned char> rawAlpha(size_t(impl_->config.outputWidth) *
                                      impl_->config.outputHeight);
  if (!cudaOk(cudaGetLastError(), error, "RGBA NV12 launch") ||
      !cudaOk(cudaMemcpy2DAsync(
                  rawAlpha.data(), size_t(impl_->config.outputWidth),
                  impl_->alpha, impl_->alphaPitch,
                  size_t(impl_->config.outputWidth), impl_->config.outputHeight,
                  cudaMemcpyDeviceToHost, impl_->stream),
              error, "alpha download") ||
      !cudaOk(cudaStreamSynchronize(impl_->stream), error,
              "NV12/alpha completion")) {
    cleanup();
    return false;
  }
  if (!preparationBefore(deadline, 2)) {
    fail(error, "frame deadline expired after GPU encode preparation");
    if (cleanup() && disposition)
      *disposition = EncodeDisposition::ExpiredBeforeSubmission;
    return false;
  }
  if (logTimings)
    nv12ReadbackDone = std::chrono::steady_clock::now();
  frame->pts = metadata.captureTimestampNs;
  frame->pict_type = forceIdr ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
  if (!avOk(avcodec_send_frame(impl_->encoder, frame), error,
            "NVENC force IDR")) {
    impl_->poisoned = true;
    cleanup();
    return false;
  }
  const bool submitted = true;
  av_frame_free(&frame);
  AVPacket *p = av_packet_alloc();
  if (!p) {
    fail(error, "packet allocation");
    cleanup();
    return false;
  }
  const int r = avcodec_receive_packet(impl_->encoder, p);
  if (!avOk(r, error, "NVENC access unit")) {
    av_packet_free(&p);
    if (submitted)
      impl_->poisoned = true;
    cleanup();
    return false;
  }
  if (logTimings)
    nvencDone = std::chrono::steady_clock::now();
  if (p->size <= 0 || std::size_t(p->size) > impl_->config.maxAccessUnitBytes) {
    av_packet_free(&p);
    impl_->poisoned = true;
    fail(error, "NVENC access unit exceeds configured bound");
    cleanup();
    return false;
  }
  if (p->pts != static_cast<std::int64_t>(metadata.captureTimestampNs)) {
    const auto returnedPts = p->pts;
    av_packet_free(&p);
    impl_->poisoned = true;
    if (error)
      *error = "NVENC access unit timestamp mismatch: expected=" +
               std::to_string(metadata.captureTimestampNs) + " actual=" +
               std::to_string(returnedPts);
    cleanup();
    return false;
  }
  if (!preparationBefore(deadline, 5)) {
    av_packet_free(&p);
    fail(error, "NVENC access unit deadline expired after submission (timestamp matched)");
    impl_->recoveryIdr = true;
    if (cleanup() && disposition)
      *disposition = EncodeDisposition::ExpiredAfterSubmission;
    return false;
  }
  const bool packetKey = (p->flags & AV_PKT_FLAG_KEY) != 0;
  std::vector<unsigned char> color(p->data, p->data + p->size);
  av_packet_free(&p);
  const bool actualIdr = impl_->config.colorCodec == 4 ? packetKey : idr(color);
  ok = !color.empty() && (!forceIdr || actualIdr);
  if (!ok)
    fail(error, "NVENC did not emit requested verified keyframe");
  if (!ok)
    impl_->poisoned = true;
  if (ok)
    impl_->recoveryIdr = false;
  if (ok)
    output = EncodedDmabufFrame{std::move(color), std::move(rawAlpha),
                                metadata, actualIdr};
  if (logTimings)
    outputDone = std::chrono::steady_clock::now();
  if (!cleanup()) {
    // A coded output cannot authorize source-buffer reuse when import cleanup
    // failed. Keep the C ABI's terminal-failure retirement path in force.
    output = {};
    ok = false;
  }
  if (logTimings) {
    const auto cleanupDone = std::chrono::steady_clock::now();
    const auto elapsedUs = [](auto start, auto end) {
      return std::chrono::duration_cast<std::chrono::microseconds>(end - start)
          .count();
    };
    std::fprintf(
        stderr,
        "GPU encode timing sample=%u host_us fence=%lld import=%lld "
        "copy_prepare=%lld nv12_alpha_readback=%lld nvenc=%lld output=%lld "
        "cleanup=%lld total=%lld (host elapsed; existing waits included; no GPU timestamps)\n",
        timingSample, static_cast<long long>(elapsedUs(totalStart, fenceDone)),
        static_cast<long long>(elapsedUs(fenceDone, importDone)),
        static_cast<long long>(elapsedUs(importDone, copyPrepareDone)),
        static_cast<long long>(elapsedUs(copyPrepareDone, nv12ReadbackDone)),
        static_cast<long long>(elapsedUs(nv12ReadbackDone, nvencDone)),
        static_cast<long long>(elapsedUs(nvencDone, outputDone)),
        static_cast<long long>(elapsedUs(outputDone, cleanupDone)),
        static_cast<long long>(elapsedUs(totalStart, cleanupDone)));
  }
  if (ok && disposition) *disposition = EncodeDisposition::Encoded;
  return ok;
}
} // namespace viewflow::gpu

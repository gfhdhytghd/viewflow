#include "gpu_sparse_atlas.cuh"
#include "alpha_copy_profile.hpp"
#include "gpu_dmabuf_encoder.cuh"
#include "gpu_import_cleanup.hpp"
#include "gpu_rgba_prepare.cuh"
#include "gpu_shadow_repair.cuh"
#include "gpu_atlas_compose.cuh"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <atomic>
#include <array>
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
  std::vector<SparsePatch> lastSparsePatches;
  GpuDmabufEncoderConfig config;
  std::thread::id owner;
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLSurface surface = EGL_NO_SURFACE;
  EGLContext context = EGL_NO_CONTEXT;
  GLuint texture = 0;
  cudaStream_t stream = nullptr;
  unsigned char *src = nullptr, *rgba = nullptr, *alpha = nullptr;
  size_t srcPitch = 0, rgbaPitch = 0, alphaPitch = 0;
  unsigned char *pinnedAlpha = nullptr;
  AVBufferRef *device = nullptr, *frames = nullptr;
  AVCodecContext *encoder = nullptr;
  bool good = false;
  bool poisoned = false;
  bool recoveryIdr = false;
  bool timingsEnabled = false;
  bool timingsAll = false;
  bool borrowPreparedTile = true;
  ~Impl() {
    if (pinnedAlpha) {
      // The persistent host destination must outlive any submitted DMA.
      if (stream) cudaStreamSynchronize(stream);
      cudaFreeHost(pinnedAlpha);
    }
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
    timingsAll = timings && std::strcmp(timings, "all") == 0;
    timingsEnabled = timingsAll || (timings && std::strcmp(timings, "1") == 0);
    const char* copyTile = std::getenv("VIEWFLOW_GPU_TILE_COPY");
    borrowPreparedTile = !copyTile || std::strcmp(copyTile, "1") != 0;
    if (timingsEnabled)
      std::fprintf(stderr, "GPU prepared-tile storage=%s\n",
                   borrowPreparedTile ? "scratch-swap" : "per-frame-copy");
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
    const char *pinned = std::getenv("VIEWFLOW_GPU_PINNED_ALPHA");
    if (!pinned || std::strcmp(pinned, "1") == 0) {
      // One fixed-size staging buffer per encoder, never a per-frame pin.
      // Failure retains the existing pageable readback path.
      cudaError_t allocation;
#ifdef VIEWFLOW_TEST_GPU_EXPIRY
      const char *forceFailure = std::getenv("VIEWFLOW_TEST_PINNED_ALPHA_ALLOC_FAIL");
      if (forceFailure && std::strcmp(forceFailure, "1") == 0)
        allocation = cudaErrorMemoryAllocation;
      else
#endif
        allocation = cudaHostAlloc(reinterpret_cast<void **>(&pinnedAlpha),
                                   size_t(config.outputWidth) * config.outputHeight,
                                   cudaHostAllocDefault);
      if (allocation != cudaSuccess) {
        pinnedAlpha = nullptr;
        cudaGetLastError();
      }
      if (timingsEnabled)
        std::fprintf(stderr, "GPU alpha readback pinned=%d\n", pinnedAlpha != nullptr);
    }
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
                              std::string *error, EncodeDisposition *disposition,
                              const SparseOptions *sparse) {
  if (disposition) *disposition = EncodeDisposition::Failed;
  output = {};
  if (!ready() || impl_->poisoned ||
      std::this_thread::get_id() != impl_->owner) {
    fail(error,
         "encoder must be created, used, and destroyed on one worker thread");
    return false;
  }
  forceIdr = forceIdr || impl_->recoveryIdr;
  if (sparse && (sparse->sources.size() != inputs.size() || sparse->maxWidth < uint32_t(impl_->config.outputWidth) ||
      sparse->maxHeight < uint32_t(impl_->config.outputHeight) || sparse->maxWidth > 8192 || sparse->maxHeight > 4096)) {
    fail(error, "invalid sparse scene capacity"); return false;
  }
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
      (!sparse && (tile.x < 0 || tile.y < 0 || tile.x > impl_->config.outputWidth - input.cropWidth ||
      tile.y > impl_->config.outputHeight - input.cropHeight)) ||
      input.cropX > int(input.imageWidth) - input.cropWidth ||
      input.cropY > int(input.imageHeight) - input.cropHeight ||
      input.metadata.frameId == 0 || input.metadata.geometryEpoch == 0 ||
      input.metadata.captureTimestampNs == 0 ||
      input.metadata.captureTimestampNs > std::uint64_t(INT64_MAX)) {
    fail(error, "unsupported DMA-BUF frame or resize; make a new encoder");
    return false;
  }
  for (size_t j = 0; !sparse && j < i; ++j) {
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
  const bool logTimings = impl_->timingsEnabled && (impl_->timingsAll || timingSample < 5 || timingSample % 60 == 0);
  const auto totalStart = logTimings ? std::chrono::steady_clock::now()
                                     : std::chrono::steady_clock::time_point{};
  // Declared before per-call resources: its final checkpoint includes their
  // destructors, including clean-expiry paths that return before the old log.
  struct TimingExit {
    bool enabled; uint64_t frame; std::chrono::steady_clock::time_point start;
    EncodeDisposition* disposition;
    struct Mark { const char* phase; long long us; };
    std::array<Mark,64> marks{}; size_t count=0; bool truncated=false;
    void mark(const char* phase) {
      if (!enabled) return;
      const auto us=std::chrono::duration_cast<std::chrono::microseconds>(
          std::chrono::steady_clock::now()-start).count();
      if (count<marks.size()) marks[count++]={phase,static_cast<long long>(us)};
      else truncated=true;
    }
    ~TimingExit() {
      if (!enabled) return;
      mark("return");
      char line[4096];
      size_t used=size_t(std::snprintf(line,sizeof(line),
          "GPU encode-detail frame=%llu disposition=%d truncated=%u marks=",
          static_cast<unsigned long long>(frame),disposition?int(*disposition):-1,unsigned(truncated)));
      for(size_t i=0;i<count && used<sizeof(line);++i) {
        const int n=std::snprintf(line+used,sizeof(line)-used,"%s%s:%lld",i?",":"",marks[i].phase,marks[i].us);
        if(n<0 || size_t(n)>=sizeof(line)-used) return;
        used+=size_t(n);
      }
      std::fprintf(stderr,"%s\n",line);
    }
  } timingExit{logTimings,metadata.frameId,totalStart,disposition};
  auto fenceDone = totalStart;
  auto importDone = totalStart;
  auto copyPrepareDone = totalStart;
  auto nv12ReadbackDone = totalStart;
  auto nvencDone = totalStart;
  auto outputDone = totalStart;
  const bool direct = !sparse && inputs.size() == 1 && inputs[0].x == 0 && inputs[0].y == 0 &&
      inputs[0].frame.cropWidth == impl_->config.outputWidth && inputs[0].frame.cropHeight == impl_->config.outputHeight;
  struct PreparedTiles {
    std::vector<AtlasTile> tiles;
    TimingExit* timing;
    const unsigned char* borrowed = nullptr;
    ~PreparedTiles() {
      for (const auto& tile : tiles) {
        if (tile.rgba == borrowed) continue;
        cudaFree(const_cast<unsigned char*>(tile.rgba));
        timing->mark("tile_free");
      }
    }
  } prepared{{}, &timingExit};
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
  timingExit.mark("fence");
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
  timingExit.mark("egl_image");
  while (glGetError() != GL_NO_ERROR) {}
  glBindTexture(GL_TEXTURE_2D, impl_->texture);
  target(GL_TEXTURE_2D, image);
  if (glGetError() != GL_NO_ERROR) {
    fail(error, "EGLImage GL texture binding");
    cleanup();
    return false;
  }
  timingExit.mark("egl_bind");
  glFinish();
  timingExit.mark("gl_finish");
  if (!cudaOk(cudaGraphicsGLRegisterImage(&resource, impl_->texture,
                                          GL_TEXTURE_2D,
                                          cudaGraphicsRegisterFlagsReadOnly),
              error, "cuda register imported image")) {
    cleanup();
    return false;
  }
  timingExit.mark("cuda_register");
  if (!cudaOk(cudaGraphicsMapResources(1, &resource, impl_->stream), error,
              "cuda map imported image")) {
    cleanup();
    return false;
  }
  mapped = true;
  if (logTimings)
    importDone = std::chrono::steady_clock::now();
  timingExit.mark("import");
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
    if (impl_->borrowPreparedTile && &tile == &inputs.back()) {
      // Both scratch allocations have full-canvas RGBA capacity. Preparation
      // has completed, and this is the last source: no subsequent import needs
      // src during this call. Keep the prepared pixels in that allocation and
      // compose into the other one, avoiding an allocation/copy/free per frame.
      // Swapping pitches with pointers also preserves differently padded rows.
      std::swap(impl_->src, impl_->rgba);
      std::swap(impl_->srcPitch, impl_->rgbaPitch);
      prepared.borrowed = impl_->src;
      prepared.tiles.push_back({impl_->src, impl_->srcPitch, input.cropWidth,
                                input.cropHeight, tile.x, tile.y});
      timingExit.mark("tile_borrow");
    } else {
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
  }
  if (!cleanup()) return false;
  }
  AVFrame* frame = nullptr;
  bool ok = false;
  // Opt-in owned-fixture witness. Read the already-retained source tile, before
  // atlas packing or encoding, to distinguish producer age from transport age.
  const auto* fixtureWitness = std::getenv("VIEWFLOW_GPU_FIXTURE_MARKER");
  if (fixtureWitness && std::strcmp(fixtureWitness, "1") == 0 && prepared.tiles.size() == 1 &&
      prepared.tiles[0].width == 3848 && prepared.tiles[0].height == 2408) {
    const auto started = std::chrono::steady_clock::now();
    const auto& tile = prepared.tiles[0];
    std::array<unsigned char, (63 * 32 + 1) * 4> marker;
    if (cudaMemcpy(marker.data(), tile.rgba + 68 * tile.pitch + 52 * 4,
                   marker.size(), cudaMemcpyDeviceToHost) == cudaSuccess) {
      uint64_t bits = 0;
      bool contrast = true;
      for (unsigned cell = 0; cell < 64; ++cell) {
        const auto* pixel = marker.data() + cell * 32 * 4;
        const unsigned luminance = (unsigned(pixel[0]) + pixel[1] + pixel[2]) / 3;
        contrast &= luminance < 64 || luminance > 191;
        bits = (bits << 1) | (luminance > 127);
      }
      const uint32_t fixture = uint32_t(bits >> 32);
      const uint16_t input = uint16_t(bits >> 16), check = uint16_t(bits);
      const bool valid = contrast && check == uint16_t(fixture ^ (fixture >> 16) ^ input ^ 0xA65Cu);
      std::fprintf(stderr, "GPU fixture-marker atlas_frame=%llu marker_frame=%u input=%u captured_ns=%llu copy_us=%lld valid=%u\n",
          static_cast<unsigned long long>(metadata.frameId), fixture, unsigned(input),
          static_cast<unsigned long long>(metadata.captureTimestampNs),
          static_cast<long long>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-started).count()), unsigned(valid));
    }
  }
  // Every imported image has been retired before composition/submission.
  auto cleanup = [&] { av_frame_free(&frame); return true; };
  std::optional<SparseResult> sparseResult;
  if (sparse) {
    std::vector<SparseCell> cells;
    uint64_t clippedPixels = 0;
    auto floorCell = [](int64_t x) { return x / 128 - (x % 128 < 0); };
    for (uint32_t i = 0; i < prepared.tiles.size(); ++i) {
      const auto& tile = prepared.tiles[i];
      const auto& scene = sparse->sources[i];
      if (scene.x < INT64_MIN + 8192 || scene.x > INT64_MAX - 8192 ||
          scene.y < INT64_MIN + 8192 || scene.y > INT64_MAX - 8192) {
        fail(error, "sparse scene coordinate overflow"); return false;
      }
      for (uint32_t sy = 0; sy < uint32_t(tile.height);) {
        const auto y = scene.y + sy;
        const uint32_t h = uint32_t(std::min<int64_t>(tile.height - sy, (floorCell(y)+1)*128-y));
        for (uint32_t sx = 0; sx < uint32_t(tile.width);) {
          const auto x = scene.x + sx;
          const uint32_t w = uint32_t(std::min<int64_t>(tile.width - sx, (floorCell(x)+1)*128-x));
          SparseCell cell{i,sx,sy,w,h,x,y,scene.z,CellAlpha::Mixed,scene.grid};
          if (!scene.clipEnabled || clipSparseCell(cell,scene.clipX,scene.clipY,scene.clipWidth,scene.clipHeight)) {
            cells.push_back(cell);
            clippedPixels += uint64_t(w)*h-uint64_t(cell.width)*cell.height;
          } else clippedPixels += uint64_t(w)*h;
          sx += w;
          if (cells.size() > 262144) { fail(error, "sparse cell resource limit"); return false; }
        }
        sy += h;
      }
    }
    if (!cudaOk(classifySparseCells(prepared.tiles.data(), prepared.tiles.size(), cells, impl_->stream),
                error, "classify sparse alpha")) return false;
    auto plan = planSparseAtlas(cells, impl_->config.outputWidth, impl_->config.outputHeight, sparse->prerender, 256);
    sparseResult = SparseResult{{}, plan.requiredWidth, plan.requiredHeight, plan.inputPixels + clippedPixels,
                               plan.storedPixels, plan.occludedPixels + clippedPixels, plan.emptyPixels, 0};
    if (!plan.fits) {
      uint32_t w = impl_->config.outputWidth, h = impl_->config.outputHeight;
      // Growth happens after source reads have finished and leases are released.
      // Prefer the smallest doubling candidate that accommodates the live cells.
      while (uint64_t(w/128)*(h/128) < plan.draws.size() &&
             (w < sparse->maxWidth || h < sparse->maxHeight)) {
        if (w < sparse->maxWidth && (w <= h*2 || h == sparse->maxHeight))
          w = std::min(sparse->maxWidth, w*2);
        else h = std::min(sparse->maxHeight, h*2);
      }
      if (w != uint32_t(impl_->config.outputWidth) || h != uint32_t(impl_->config.outputHeight)) {
        sparseResult->requiredWidth = w;
        sparseResult->requiredHeight = h;
        output.sparse = std::move(sparseResult);
        if (disposition) *disposition = EncodeDisposition::NeedsCanvas;
        return false;
      }
      // At the negotiated cap retain topmost visible cells first. A missing
      // patch is transparent residency, never removal of native window/input.
      const size_t capacity = size_t(w/128)*(h/128);
      std::stable_sort(plan.draws.begin(), plan.draws.end(), [](const auto& a, const auto& b) {
        return a.layers.back().z > b.layers.back().z;
      });
      for (size_t i=capacity; i<plan.draws.size(); ++i)
        sparseResult->omittedPixels += uint64_t(plan.draws[i].patch.width)*plan.draws[i].patch.height;
      plan.draws.resize(capacity);
      std::sort(plan.draws.begin(), plan.draws.end(), [](const auto& a, const auto& b) {
        return std::tie(a.patch.source,a.patch.sourceY,a.patch.sourceX) <
               std::tie(b.patch.source,b.patch.sourceY,b.patch.sourceX);
      });
      for(size_t i=0;i<plan.draws.size();++i) {
        plan.draws[i].patch.x=uint32_t(i%(w/128))*128;
        plan.draws[i].patch.y=uint32_t(i/(w/128))*128;
      }
      plan.fits=true;
      sparseResult->storedPixels -= sparseResult->omittedPixels;
    }
    sparseResult->requiredWidth = impl_->config.outputWidth;
    sparseResult->requiredHeight = impl_->config.outputHeight;
    for(const auto& draw:plan.draws) sparseResult->patches.push_back(draw.patch);
    const auto same = [](const SparsePatch& a,const SparsePatch& b) {
      return std::tie(a.source,a.sourceX,a.sourceY,a.x,a.y,a.width,a.height) ==
             std::tie(b.source,b.sourceX,b.sourceY,b.x,b.y,b.width,b.height);
    };
    forceIdr = forceIdr || sparseResult->patches.size()!=impl_->lastSparsePatches.size() ||
      !std::equal(sparseResult->patches.begin(), sparseResult->patches.end(), impl_->lastSparsePatches.begin(), same);
    if (!cudaOk(composeSparseAtlas(prepared.tiles.data(),prepared.tiles.size(),plan,
                  {impl_->rgba,impl_->rgbaPitch,impl_->alpha,impl_->alphaPitch,
                   impl_->config.outputWidth,impl_->config.outputHeight},impl_->stream),
                error,"compose sparse atlas") ||
        !cudaOk(cudaStreamSynchronize(impl_->stream),error,"sparse composition completion")) {
      impl_->poisoned=true; return false;
    }
  } else {
  if (!direct && (!cudaOk(composeAtlas(prepared.tiles.data(), prepared.tiles.size(),
                       {impl_->rgba, impl_->rgbaPitch, impl_->alpha, impl_->alphaPitch,
                        impl_->config.outputWidth, impl_->config.outputHeight}, impl_->stream),
                       error, "compose prepared atlas") ||
                  !cudaOk(cudaStreamSynchronize(impl_->stream), error, "atlas composition completion"))) {
    impl_->poisoned = true;
    return false;
  }
  }
  if (!before(deadline)) {
    fail(error, "atlas deadline expired before NVENC preparation");
    if (disposition) *disposition = EncodeDisposition::ExpiredBeforeSubmission;
    return false;
  }
  if (logTimings)
    copyPrepareDone = std::chrono::steady_clock::now();
  timingExit.mark("copy_prepare");
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
  const size_t alphaBytes = size_t(impl_->config.outputWidth) * impl_->config.outputHeight;
  std::vector<unsigned char> rawAlpha;
  if (!impl_->pinnedAlpha) rawAlpha.resize(alphaBytes);
  unsigned char *alphaDestination = impl_->pinnedAlpha ? impl_->pinnedAlpha : rawAlpha.data();
  if (!cudaOk(cudaGetLastError(), error, "RGBA NV12 launch") ||
      !cudaOk(cudaMemcpy2DAsync(
                  alphaDestination, size_t(impl_->config.outputWidth),
                  impl_->alpha, impl_->alphaPitch,
                  size_t(impl_->config.outputWidth), impl_->config.outputHeight,
                  cudaMemcpyDeviceToHost, impl_->stream),
              error, "alpha download") ||
      !cudaOk(cudaStreamSynchronize(impl_->stream), error,
              "NV12/alpha completion")) {
    cleanup();
    return false;
  }
  if (impl_->pinnedAlpha) {
    AlphaCopyProfile profile("pinned_to_vector", metadata.frameId, alphaBytes);
    rawAlpha.assign(impl_->pinnedAlpha, impl_->pinnedAlpha + alphaBytes);
  }
  if (!preparationBefore(deadline, 2)) {
    fail(error, "frame deadline expired after GPU encode preparation");
    if (cleanup() && disposition)
      *disposition = EncodeDisposition::ExpiredBeforeSubmission;
    return false;
  }
  if (logTimings)
    nv12ReadbackDone = std::chrono::steady_clock::now();
  timingExit.mark("nv12_alpha_readback");
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
  timingExit.mark("nvenc");
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
                                metadata, actualIdr, std::move(sparseResult)};
  if (ok && output.sparse) impl_->lastSparsePatches = output.sparse->patches;
  if (logTimings)
    outputDone = std::chrono::steady_clock::now();
  timingExit.mark("output");
  if (!cleanup()) {
    // A coded output cannot authorize source-buffer reuse when import cleanup
    // failed. Keep the C ABI's terminal-failure retirement path in force.
    output = {};
    ok = false;
  }
  if (logTimings) {
    const auto cleanupDone = std::chrono::steady_clock::now();
    timingExit.mark("cleanup");
    const auto elapsedUs = [](auto start, auto end) {
      return std::chrono::duration_cast<std::chrono::microseconds>(end - start)
          .count();
    };
    std::fprintf(
        stderr,
        "GPU encode timing sample=%u frame=%llu host_us fence=%lld import=%lld "
        "copy_prepare=%lld nv12_alpha_readback=%lld nvenc=%lld output=%lld "
        "cleanup=%lld total=%lld (host elapsed; existing waits included; no GPU timestamps)\n",
        timingSample, static_cast<unsigned long long>(metadata.frameId), static_cast<long long>(elapsedUs(totalStart, fenceDone)),
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

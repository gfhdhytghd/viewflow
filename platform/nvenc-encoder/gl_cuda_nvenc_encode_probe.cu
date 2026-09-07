// Manual capability probe only: an owned EGL/GLES texture is copied from its
// mapped CUDA array into device memory, converted to NV12 by this CUDA kernel,
// and submitted as an AV_PIX_FMT_CUDA frame to h264_nvenc.  No host pixels
// participate between the GL texture and AVCodec.  It is not product capture.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <cuda.h>
#include <cuda_gl_interop.h>
#include <cuda_runtime_api.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_cuda.h>
#include <libavutil/opt.h>
}

#include <array>
#include <charconv>
#include <chrono>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>
#include <vector>

namespace {
constexpr int kDefaultWidth = 256;
constexpr int kDefaultHeight = 256;
constexpr int kMaxProbeDimension = 8192;
constexpr int kFrames = 3;
constexpr std::array<std::int64_t, kFrames> kFrameIds{101, 202, 303};
constexpr std::array<std::array<unsigned char, 4>, kFrames> kColors{{{220, 20, 40, 0}, {30, 200, 70, 127}, {20, 80, 230, 254}}};
int g_width = kDefaultWidth;
int g_height = kDefaultHeight;

bool parse_probe_dimension(const char* text, int* value) {
  const char* end = text + std::strlen(text);
  const auto [parsed, error] = std::from_chars(text, end, *value);
  return error == std::errc{} && parsed == end && *value >= 2 && *value <= kMaxProbeDimension && (*value % 2) == 0;
}

bool cuda_ok(cudaError_t value, const char* op) {
  if (value == cudaSuccess) return true;
  std::cerr << "FAIL " << op << ": " << cudaGetErrorString(value) << '\n';
  return false;
}
bool cu_ok(CUresult value, const char* op) {
  if (value == CUDA_SUCCESS) return true;
  const char* text = nullptr;
  cuGetErrorString(value, &text);
  std::cerr << "FAIL " << op << ": " << (text ? text : "unknown CUDA driver error") << '\n';
  return false;
}
bool egl_ok(EGLBoolean value, const char* op) {
  if (value == EGL_TRUE) return true;
  std::cerr << "FAIL " << op << ": EGL 0x" << std::hex << eglGetError() << std::dec << '\n';
  return false;
}
bool av_ok(int value, const char* op) {
  if (value >= 0) return true;
  char text[AV_ERROR_MAX_STRING_SIZE]{};
  av_strerror(value, text, sizeof(text));
  std::cerr << "FAIL " << op << ": " << text << '\n';
  return false;
}

__global__ void rgba_to_nv12(const unsigned char* rgba, std::size_t rgba_pitch, unsigned char* y_plane,
                             std::size_t y_pitch, unsigned char* uv_plane, std::size_t uv_pitch,
                             int width, int height) {
  const int x = static_cast<int>(blockIdx.x * blockDim.x + threadIdx.x);
  const int y = static_cast<int>(blockIdx.y * blockDim.y + threadIdx.y);
  if (x >= width || y >= height) return;
  const auto* pixel = rgba + static_cast<std::size_t>(y) * rgba_pitch + static_cast<std::size_t>(x) * 4;
  const int r = pixel[0];
  const int g = pixel[1];
  const int b = pixel[2];
  y_plane[static_cast<std::size_t>(y) * y_pitch + x] = static_cast<unsigned char>((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
  if ((x & 1) != 0 || (y & 1) != 0) return;
  const int sx = min(x + 1, width - 1);
  const int sy = min(y + 1, height - 1);
  int sum_r = 0, sum_g = 0, sum_b = 0;
  for (int yy = y; yy <= sy; ++yy) for (int xx = x; xx <= sx; ++xx) {
    const auto* p = rgba + static_cast<std::size_t>(yy) * rgba_pitch + static_cast<std::size_t>(xx) * 4;
    sum_r += p[0]; sum_g += p[1]; sum_b += p[2];
  }
  const int count = (sx - x + 1) * (sy - y + 1);
  const int ar = sum_r / count, ag = sum_g / count, ab = sum_b / count;
  auto* uv = uv_plane + static_cast<std::size_t>(y / 2) * uv_pitch + x;
  uv[0] = static_cast<unsigned char>((-38 * ar - 74 * ag + 112 * ab + 128) >> 8) + 128;
  uv[1] = static_cast<unsigned char>((112 * ar - 94 * ag - 18 * ab + 128) >> 8) + 128;
}

struct EglScope {
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLSurface surface = EGL_NO_SURFACE;
  EGLContext context = EGL_NO_CONTEXT;
  ~EglScope() {
    if (display != EGL_NO_DISPLAY) {
      eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
      if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
      eglTerminate(display);
    }
  }
  bool create() {
    display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major = 0, minor = 0;
    if (display == EGL_NO_DISPLAY || eglInitialize(display, &major, &minor) != EGL_TRUE) {
      display = device_display();
      if (display == EGL_NO_DISPLAY || !egl_ok(eglInitialize(display, &major, &minor), "eglInitialize(platform-device)")) return false;
    }
    if (!egl_ok(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI")) return false;
    constexpr EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
                                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
    EGLConfig config{}; EGLint count = 0;
    if (!egl_ok(eglChooseConfig(display, attrs, &config, 1, &count), "eglChooseConfig") || count != 1) return false;
    const EGLint pbuffer[] = {EGL_WIDTH, g_width, EGL_HEIGHT, g_height, EGL_NONE};
    surface = eglCreatePbufferSurface(display, config, pbuffer);
    if (surface == EGL_NO_SURFACE) return false;
    constexpr EGLint context_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attrs);
    return context != EGL_NO_CONTEXT && egl_ok(eglMakeCurrent(display, surface, surface, context), "eglMakeCurrent");
  }
 private:
  static EGLDisplay device_display() {
    const auto query = reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
    const auto get = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if (!query || !get) return EGL_NO_DISPLAY;
    std::array<EGLDeviceEXT, 8> devices{};
    EGLint count = 0;
    if (query(static_cast<EGLint>(devices.size()), devices.data(), &count) != EGL_TRUE || count < 1) return EGL_NO_DISPLAY;
    for (EGLint i = 0; i < count; ++i) {
      const EGLDisplay candidate = get(EGL_PLATFORM_DEVICE_EXT, devices[static_cast<std::size_t>(i)], nullptr);
      if (candidate != EGL_NO_DISPLAY) return candidate;
    }
    return EGL_NO_DISPLAY;
  }
};

struct AvRefs {
  AVBufferRef* device = nullptr;
  AVBufferRef* frames = nullptr;
  AVCodecContext* encoder = nullptr;
  AVCodecContext* decoder = nullptr;
  ~AvRefs() {
    avcodec_free_context(&decoder); avcodec_free_context(&encoder);
    av_buffer_unref(&frames); av_buffer_unref(&device);
  }
};

bool set_opt(AVCodecContext* context, const char* key, const char* value) {
  return av_ok(av_opt_set(context->priv_data, key, value, 0), key);
}

bool create_encoder(AvRefs& refs) {
  // Attach FFmpeg's CUDA device to the same current CUDA primary context used
  // for GL interop; do not let it create a separate opaque CUDA context.
  CUcontext current = nullptr;
  if (!cu_ok(cuCtxGetCurrent(&current), "cuCtxGetCurrent") || current == nullptr) return false;
  refs.device = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_CUDA);
  if (refs.device == nullptr) { std::cerr << "FAIL av_hwdevice_ctx_alloc(CUDA)\n"; return false; }
  auto* device_ctx = reinterpret_cast<AVHWDeviceContext*>(refs.device->data);
  auto* cuda_ctx = reinterpret_cast<AVCUDADeviceContext*>(device_ctx->hwctx);
  cuda_ctx->cuda_ctx = current;
  if (!av_ok(av_hwdevice_ctx_init(refs.device), "av_hwdevice_ctx_init(same CUDA context)")) return false;
  refs.frames = av_hwframe_ctx_alloc(refs.device);
  if (refs.frames == nullptr) { std::cerr << "FAIL av_hwframe_ctx_alloc\n"; return false; }
  auto* frames_ctx = reinterpret_cast<AVHWFramesContext*>(refs.frames->data);
  frames_ctx->format = AV_PIX_FMT_CUDA;
  frames_ctx->sw_format = AV_PIX_FMT_NV12;  // queried/used mapping accepted by h264_nvenc's CUDA input.
  frames_ctx->width = g_width;
  frames_ctx->height = g_height;
  frames_ctx->initial_pool_size = 1;
  if (!av_ok(av_hwframe_ctx_init(refs.frames), "av_hwframe_ctx_init(CUDA/NV12)")) return false;
  const AVCodec* codec = avcodec_find_encoder_by_name("h264_nvenc");
  if (!codec) { std::cerr << "FAIL h264_nvenc unavailable\n"; return false; }
  refs.encoder = avcodec_alloc_context3(codec);
  if (!refs.encoder) return false;
  refs.encoder->width = g_width; refs.encoder->height = g_height; refs.encoder->pix_fmt = AV_PIX_FMT_CUDA;
  refs.encoder->time_base = AVRational{1, 1000}; refs.encoder->framerate = AVRational{60, 1};
  refs.encoder->max_b_frames = 0; refs.encoder->gop_size = kFrames;
  refs.encoder->color_range = AVCOL_RANGE_MPEG;
  refs.encoder->colorspace = AVCOL_SPC_SMPTE170M;
  refs.encoder->color_primaries = AVCOL_PRI_SMPTE170M;
  refs.encoder->color_trc = AVCOL_TRC_SMPTE170M;
  refs.encoder->hw_frames_ctx = av_buffer_ref(refs.frames);
  if (!refs.encoder->hw_frames_ctx || !set_opt(refs.encoder, "preset", "p1") || !set_opt(refs.encoder, "tune", "ull") ||
      !set_opt(refs.encoder, "zerolatency", "1") || !set_opt(refs.encoder, "delay", "0") ||
      !set_opt(refs.encoder, "rc-lookahead", "0") || !set_opt(refs.encoder, "rc", "constqp") || !set_opt(refs.encoder, "qp", "10")) return false;
  return av_ok(avcodec_open2(refs.encoder, codec, nullptr), "avcodec_open2(h264_nvenc CUDA)");
}

bool drain_packets(AVCodecContext* encoder, FILE* output, std::int64_t expected_pts, int* written) {
  AVPacket* packet = av_packet_alloc();
  if (!packet) return false;
  while (true) {
    const int result = avcodec_receive_packet(encoder, packet);
    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) break;
    if (!av_ok(result, "avcodec_receive_packet")) { av_packet_free(&packet); return false; }
    const bool flush_pts_is_identity = packet->pts == kFrameIds[0] || packet->pts == kFrameIds[1] || packet->pts == kFrameIds[2];
    if ((expected_pts != AV_NOPTS_VALUE && packet->pts != expected_pts) ||
        (expected_pts == AV_NOPTS_VALUE && !flush_pts_is_identity)) {
      std::cerr << "FAIL packet PTS " << packet->pts << " does not match frame identity " << expected_pts << '\n';
      av_packet_free(&packet); return false;
    }
    if (packet->size < 4 || std::fwrite(packet->data, 1, static_cast<std::size_t>(packet->size), output) != static_cast<std::size_t>(packet->size)) {
      std::cerr << "FAIL write Annex-B packet\n"; av_packet_free(&packet); return false;
    }
    ++*written; av_packet_unref(packet);
  }
  av_packet_free(&packet);
  return true;
}

bool verify_decoded_colors(const char* path) {
  std::ifstream input(path, std::ios::binary);
  std::vector<unsigned char> bitstream((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
  const bool empty_bitstream = bitstream.empty();
  bitstream.resize(bitstream.size() + AV_INPUT_BUFFER_PADDING_SIZE, 0);
  const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
  AVCodecParserContext* parser = av_parser_init(AV_CODEC_ID_H264);
  AVCodecContext* decoder = codec ? avcodec_alloc_context3(codec) : nullptr;
  AVPacket* packet = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  if (empty_bitstream || !parser || !decoder || !packet || !frame || !av_ok(avcodec_open2(decoder, codec, nullptr), "avcodec_open2(H264 fixture decoder)")) {
    av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&decoder); if (parser) av_parser_close(parser); return false;
  }
  bool ok = true; int decoded = 0;
  const auto drain = [&] {
    while (ok) {
      const int result = avcodec_receive_frame(decoder, frame);
      if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return;
      if (result < 0 || frame->format != AV_PIX_FMT_YUV420P || frame->width != g_width || frame->height != g_height || decoded >= kFrames) { ok = false; return; }
      const int expected_y = ((66 * kColors[decoded][0] + 129 * kColors[decoded][1] + 25 * kColors[decoded][2] + 128) >> 8) + 16;
      const int expected_u = ((-38 * kColors[decoded][0] - 74 * kColors[decoded][1] + 112 * kColors[decoded][2] + 128) >> 8) + 128;
      const int expected_v = ((112 * kColors[decoded][0] - 94 * kColors[decoded][1] - 18 * kColors[decoded][2] + 128) >> 8) + 128;
      const int observed_y = frame->data[0][static_cast<std::size_t>(g_height / 2) * frame->linesize[0] + g_width / 2];
      const int observed_u = frame->data[1][static_cast<std::size_t>(g_height / 4) * frame->linesize[1] + g_width / 4];
      const int observed_v = frame->data[2][static_cast<std::size_t>(g_height / 4) * frame->linesize[2] + g_width / 4];
      if (std::abs(observed_y - expected_y) > 4 || std::abs(observed_u - expected_u) > 4 || std::abs(observed_v - expected_v) > 4) {
        std::cerr << "FAIL decoded BT.601 limited YUV differs by more than QP10 tolerance\n"; ok = false; return;
      }
      ++decoded; av_frame_unref(frame);
    }
  };
  const unsigned char* data = bitstream.data(); int remaining = static_cast<int>(bitstream.size() - AV_INPUT_BUFFER_PADDING_SIZE);
  while (ok && remaining > 0) {
    unsigned char* parsed = nullptr; int parsed_size = 0;
    const int used = av_parser_parse2(parser, decoder, &parsed, &parsed_size, data, remaining, AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
    if (used < 0 || (used == 0 && parsed_size == 0)) { ok = false; break; }
    data += used; remaining -= used;
    if (parsed_size > 0) { packet->data = parsed; packet->size = parsed_size; ok = av_ok(avcodec_send_packet(decoder, packet), "avcodec_send_packet(decoded fixture)"); drain(); }
  }
  if (ok) {
    unsigned char* parsed = nullptr; int parsed_size = 0;
    if (av_parser_parse2(parser, decoder, &parsed, &parsed_size, nullptr, 0, AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0) < 0) ok = false;
    if (ok && parsed_size > 0) { packet->data = parsed; packet->size = parsed_size; ok = av_ok(avcodec_send_packet(decoder, packet), "avcodec_send_packet(final decoded fixture)"); drain(); }
  }
  if (ok) { avcodec_send_packet(decoder, nullptr); drain(); }
  av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&decoder); av_parser_close(parser);
  if (decoded != kFrames) std::cerr << "FAIL decoded fixture emitted " << decoded << " of " << kFrames << " frames\n";
  return ok && decoded == kFrames;
}

bool encode_from_texture(cudaGraphicsResource_t resource, AVCodecContext* encoder, FILE* output, int frame_index, int* written) {
  if (!cuda_ok(cudaGraphicsMapResources(1, &resource, nullptr), "cudaGraphicsMapResources")) return false;
  bool mapped = true;
  const auto unmap = [&] {
    if (!mapped) return true;
    mapped = false;
    return cuda_ok(cudaGraphicsUnmapResources(1, &resource, nullptr), "cudaGraphicsUnmapResources");
  };
  cudaArray_t array = nullptr;
  if (!cuda_ok(cudaGraphicsSubResourceGetMappedArray(&array, resource, 0, 0), "cudaGraphicsSubResourceGetMappedArray")) { unmap(); return false; }
  unsigned char* rgba = nullptr; std::size_t pitch = 0;
  if (!cuda_ok(cudaMallocPitch(reinterpret_cast<void**>(&rgba), &pitch, g_width * 4, g_height), "cudaMallocPitch(RGBA device)")) { unmap(); return false; }
  const bool copied = cuda_ok(cudaMemcpy2DFromArray(rgba, pitch, array, 0, 0, g_width * 4, g_height, cudaMemcpyDeviceToDevice),
                              "cudaMemcpy2DFromArray(GL array -> CUDA device)");
  if (!copied) { cudaFree(rgba); unmap(); return false; }
  AVFrame* frame = av_frame_alloc();
  if (!frame || !av_ok(av_hwframe_get_buffer(encoder->hw_frames_ctx, frame, 0), "av_hwframe_get_buffer")) { av_frame_free(&frame); cudaFree(rgba); unmap(); return false; }
  const dim3 block(16, 16), grid((g_width + 15) / 16, (g_height + 15) / 16);
  rgba_to_nv12<<<grid, block>>>(rgba, pitch, frame->data[0], frame->linesize[0], frame->data[1], frame->linesize[1], g_width, g_height);
  const bool kernel_ok = cuda_ok(cudaGetLastError(), "rgba_to_nv12 launch") && cuda_ok(cudaDeviceSynchronize(), "rgba_to_nv12 completion");
  cudaFree(rgba);
  if (!kernel_ok || !unmap()) { av_frame_free(&frame); return false; }
  frame->pts = kFrameIds[frame_index];
  frame->pict_type = frame_index == 0 ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
  if (!av_ok(avcodec_send_frame(encoder, frame), "avcodec_send_frame(AV_PIX_FMT_CUDA)")) { av_frame_free(&frame); return false; }
  av_frame_free(&frame);
  const int before = *written;
  if (!drain_packets(encoder, output, kFrameIds[frame_index], written)) return false;
  if (*written == before) { std::cerr << "FAIL frame " << kFrameIds[frame_index] << " emitted no Annex-B access unit\n"; return false; }
  return true;
}

bool verify_alpha_independently(cudaGraphicsResource_t resource, GLuint texture) {
  constexpr std::array<unsigned char, 16> pixels = {9, 8, 7, 0, 6, 5, 4, 63, 3, 2, 1, 127, 0, 1, 2, 254};
  glBindTexture(GL_TEXTURE_2D, texture); glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data()); glFinish();
  if (!cuda_ok(cudaGraphicsMapResources(1, &resource, nullptr), "cudaGraphicsMapResources(alpha verification)")) return false;
  cudaArray_t array = nullptr;
  if (!cuda_ok(cudaGraphicsSubResourceGetMappedArray(&array, resource, 0, 0), "cudaGraphicsSubResourceGetMappedArray(alpha verification)")) {
    cudaGraphicsUnmapResources(1, &resource, nullptr);
    return false;
  }
  std::array<unsigned char, pixels.size()> observed{};
  const bool copied = cuda_ok(cudaMemcpy2DFromArray(observed.data(), 2 * 4, array, 0, 0, 2 * 4, 2, cudaMemcpyDeviceToHost),
                              "cudaMemcpy2DFromArray(test-only alpha verification)");
  const bool unmapped = cuda_ok(cudaGraphicsUnmapResources(1, &resource, nullptr), "cudaGraphicsUnmapResources(alpha verification)");
  if (!copied || !unmapped) return false;
  for (std::size_t index = 3; index < pixels.size(); index += 4) if (observed[index] != pixels[index]) return false;
  return true;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc != 1 && argc != 3) {
    std::cerr << "usage: " << argv[0] << " [even-width even-height]\n";
    return EXIT_FAILURE;
  }
  if (argc == 3 && (!parse_probe_dimension(argv[1], &g_width) || !parse_probe_dimension(argv[2], &g_height))) {
    std::cerr << "FAIL dimensions must be even integers in 2.." << kMaxProbeDimension << " (test-only probe bounds)\n";
    return EXIT_FAILURE;
  }
  EglScope egl;
  if (!egl.create()) { std::cerr << "This probe needs an independent EGL GLES3 pbuffer display.\n"; return EXIT_FAILURE; }
  unsigned int cuda_devices = 0;
  int gl_cuda_device = -1;
  if (!cuda_ok(cudaGLGetDevices(&cuda_devices, &gl_cuda_device, 1, cudaGLDeviceListAll), "cudaGLGetDevices") || cuda_devices != 1 ||
      !cuda_ok(cudaSetDevice(gl_cuda_device), "cudaSetDevice(GL-associated device)") ||
      !cuda_ok(cudaFree(nullptr), "initialize CUDA primary context")) return EXIT_FAILURE;
  GLuint texture = 0; glGenTextures(1, &texture); glBindTexture(GL_TEXTURE_2D, texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, g_width, g_height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  cudaGraphicsResource_t resource = nullptr;
  if (!cuda_ok(cudaGraphicsGLRegisterImage(&resource, texture, GL_TEXTURE_2D, cudaGraphicsRegisterFlagsReadOnly), "cudaGraphicsGLRegisterImage")) return EXIT_FAILURE;
  AvRefs av;
  if (!create_encoder(av)) { cudaGraphicsUnregisterResource(resource); glDeleteTextures(1, &texture); return EXIT_FAILURE; }
  char output_path[] = "/tmp/viewflow-gl-cuda-nvenc-XXXXXX.h264";
  const int fd = mkstemps(output_path, 5);
  if (fd < 0) { std::cerr << "FAIL mkstemps: " << std::strerror(errno) << '\n'; cudaGraphicsUnregisterResource(resource); glDeleteTextures(1, &texture); return EXIT_FAILURE; }
  FILE* output = fdopen(fd, "wb");
  if (output == nullptr) { std::cerr << "FAIL fdopen: " << std::strerror(errno) << '\n'; close(fd); std::remove(output_path); cudaGraphicsUnregisterResource(resource); glDeleteTextures(1, &texture); return EXIT_FAILURE; }
  bool ok = true;
  int written = 0;
  std::chrono::nanoseconds steady_encode_host{};
  int steady_encode_samples = 0;
  for (int frame = 0; ok && frame < kFrames; ++frame) {
    std::vector<unsigned char> pixels(static_cast<std::size_t>(g_width) * g_height * 4);
    for (std::size_t pixel = 0; pixel < pixels.size(); pixel += 4) std::memcpy(pixels.data() + pixel, kColors[frame].data(), 4);
    glBindTexture(GL_TEXTURE_2D, texture); glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, g_width, g_height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data()); glFinish();
    const auto started = std::chrono::steady_clock::now();
    ok = encode_from_texture(resource, av.encoder, output, frame, &written);
    if (frame > 0) {
      steady_encode_host += std::chrono::steady_clock::now() - started;
      ++steady_encode_samples;
    }
  }
  if (ok) {
    ok = av_ok(avcodec_send_frame(av.encoder, nullptr), "avcodec_send_frame(flush)");
    while (ok) {
      const int before = written;
      ok = drain_packets(av.encoder, output, AV_NOPTS_VALUE, &written);
      if (!ok || written == before) break;
    }
  }
  const int flush_result = std::fflush(output);
  const int close_result = std::fclose(output);
  if (flush_result != 0 || close_result != 0) { std::cerr << "FAIL flush/close Annex-B artifact\n"; ok = false; }
  const bool color_ok = ok && verify_decoded_colors(output_path);
  const bool alpha_ok = color_ok && verify_alpha_independently(resource, texture);
  cudaGraphicsUnregisterResource(resource); glDeleteTextures(1, &texture);
  if (!ok || !color_ok || !alpha_ok || written != kFrames) { std::remove(output_path); std::cerr << "FAIL GPU resident encode or independent alpha verification\n"; return EXIT_FAILURE; }
  const auto steady_ms = std::chrono::duration<double, std::milli>(steady_encode_host).count() / steady_encode_samples;
  std::cout << "PASS " << g_width << 'x' << g_height << " AV_PIX_FMT_CUDA/NV12 h264_nvenc: " << kFrames
            << " Annex-B access units (frame identities 101,202,303), GL array -> CUDA device copy -> CUDA conversion -> NVENC; "
            << "steady frame submit host time=" << steady_ms << " ms (frames 202/303, includes GL upload/finish, CUDA map/copy/convert/sync, NVENC submit/packet); "
            << "independent alpha bytes exact; output=" << output_path << '\n';
  return EXIT_SUCCESS;
}

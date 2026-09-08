#include "gpu_dmabuf_encoder.cuh"
#include "gpu_dmabuf_encoder_cabi.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
extern "C" {
#include <libavcodec/avcodec.h>
}
#include <array>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

#ifdef VIEWFLOW_TEST_GPU_EXPIRY
extern "C" void vf_test_expire_gpu_preparation(unsigned stage);
#endif

namespace {
int W = 1936, H = 1732;
bool ck(bool v, const char *s) {
  if (!v)
    std::fprintf(stderr, "FAIL %s\n", s);
  return v;
}
bool hasIdrNal(const std::vector<unsigned char> &annexB) {
  for (size_t i = 0; i + 4 < annexB.size(); ++i) {
    const size_t nal = annexB[i] == 0 && annexB[i + 1] == 0 &&
                               annexB[i + 2] == 1
                           ? i + 3
                           : (annexB[i] == 0 && annexB[i + 1] == 0 &&
                                      annexB[i + 2] == 0 && annexB[i + 3] == 1
                                  ? i + 4
                                  : annexB.size());
    if (nal < annexB.size() && (annexB[nal] & 0x1f) == 5)
      return true;
  }
  return false;
}
std::int64_t deadlineNs(int ms) {
  timespec t{};
  clock_gettime(CLOCK_MONOTONIC, &t);
  return std::int64_t(t.tv_sec) * 1000000000LL + t.tv_nsec +
         std::int64_t(ms) * 1000000;
}
bool decodedBt709LimitedMatches(const std::vector<unsigned char> &annexB, int red,
                                int green, int blue) {
  const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
  AVCodecContext *ctx = codec ? avcodec_alloc_context3(codec) : nullptr;
  AVPacket *packet = av_packet_alloc();
  AVFrame *frame = av_frame_alloc();
  bool ok = ctx && packet && frame && avcodec_open2(ctx, codec, nullptr) >= 0 &&
            av_new_packet(packet, int(annexB.size())) >= 0;
  if (ok) {
    std::memcpy(packet->data, annexB.data(), annexB.size());
    ok = avcodec_send_packet(ctx, packet) >= 0 &&
         avcodec_send_packet(ctx, nullptr) >= 0;
  }
  if (ok) {
    const int r = avcodec_receive_frame(ctx, frame);
    const int wantY = ((47 * red + 157 * green + 16 * blue + 128) >> 8) + 16,
              wantU = ((-26 * red - 87 * green + 112 * blue + 128) >> 8) + 128,
              wantV = ((112 * red - 102 * green - 10 * blue + 128) >> 8) + 128;
    ok = r >= 0 && ctx->profile == AV_PROFILE_H264_HIGH &&
         frame->format == AV_PIX_FMT_YUV420P && frame->width == W &&
         frame->height == H && frame->color_range == AVCOL_RANGE_MPEG &&
         frame->color_primaries == AVCOL_PRI_BT709 &&
         frame->color_trc == AVCOL_TRC_BT709 && frame->colorspace == AVCOL_SPC_BT709 &&
         std::abs(
             int(frame->data[0][size_t(H / 2) * frame->linesize[0] + W / 2]) -
             wantY) <= 4 &&
         std::abs(
             int(frame->data[1][size_t(H / 4) * frame->linesize[1] + W / 4]) -
             wantU) <= 4 &&
         std::abs(
             int(frame->data[2][size_t(H / 4) * frame->linesize[2] + W / 4]) -
             wantV) <= 4 &&
         avcodec_receive_frame(ctx, frame) == AVERROR_EOF;
  }
  av_frame_free(&frame);
  av_packet_free(&packet);
  avcodec_free_context(&ctx);
  return ok;
}
bool decodedAtlasMatches(const std::vector<unsigned char>& annexB, int count) {
  const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
  AVCodecContext* ctx = codec ? avcodec_alloc_context3(codec) : nullptr;
  AVPacket* packet = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  bool ok = ctx && packet && frame && avcodec_open2(ctx, codec, nullptr) >= 0 &&
            av_new_packet(packet, int(annexB.size())) >= 0;
  if (ok) {
    std::memcpy(packet->data, annexB.data(), annexB.size());
    ok = avcodec_send_packet(ctx, packet) >= 0 && avcodec_send_packet(ctx, nullptr) >= 0 &&
         avcodec_receive_frame(ctx, frame) >= 0 && frame->format == AV_PIX_FMT_YUV420P &&
         frame->width == W && frame->height == H;
  }
  if (ok) {
    const int want1 = ((47 * 99 + 157 * 49 + 16 * 19 + 128) >> 8) + 16;
    const int want2 = ((47 * 63 + 157 * 127 + 16 * 191 + 128) >> 8) + 16;
    auto sample = [&](int x, int y, int want) {
      return std::abs(int(frame->data[0][size_t(y) * frame->linesize[0] + x]) - want) <= 4;
    };
    ok = sample(24, 24, count > 0 ? want1 : 16) && sample(128, 88, count == 2 ? want2 : 16) &&
         sample(W / 2, H / 2, 16) && avcodec_receive_frame(ctx, frame) == AVERROR_EOF;
  }
  av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&ctx);
  return ok;
}
bool decodedBt709LimitedGopMatches(
    const std::vector<std::vector<unsigned char>> &accessUnits,
    const std::vector<std::array<int, 3>> &straightRgb,
    const std::vector<bool> &expectIdr) {
  const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
  AVCodecContext *ctx = codec ? avcodec_alloc_context3(codec) : nullptr;
  AVPacket *packet = av_packet_alloc();
  AVFrame *frame = av_frame_alloc();
  size_t decoded = 0;
  bool ok = ctx && packet && frame && accessUnits.size() == straightRgb.size() &&
            accessUnits.size() == expectIdr.size() &&
            avcodec_open2(ctx, codec, nullptr) >= 0;
  auto drain = [&] {
    while (ok) {
      const int r = avcodec_receive_frame(ctx, frame);
      if (r == AVERROR(EAGAIN) || r == AVERROR_EOF)
        return;
      if (r < 0 || decoded == straightRgb.size()) {
        ok = false;
        return;
      }
      const auto [red, green, blue] = straightRgb[decoded];
      const int wantY = ((47 * red + 157 * green + 16 * blue + 128) >> 8) + 16,
                wantU = ((-26 * red - 87 * green + 112 * blue + 128) >> 8) + 128,
                wantV = ((112 * red - 102 * green - 10 * blue + 128) >> 8) + 128;
      ok = frame->format == AV_PIX_FMT_YUV420P && frame->width == W &&
           frame->height == H && frame->color_range == AVCOL_RANGE_MPEG &&
           frame->color_primaries == AVCOL_PRI_BT709 &&
           frame->color_trc == AVCOL_TRC_BT709 &&
           frame->colorspace == AVCOL_SPC_BT709 &&
           frame->pict_type == (expectIdr[decoded] ? AV_PICTURE_TYPE_I
                                                    : AV_PICTURE_TYPE_P) &&
           std::abs(int(frame->data[0][size_t(H / 2) * frame->linesize[0] + W / 2]) -
                    wantY) <= 4 &&
           std::abs(int(frame->data[1][size_t(H / 4) * frame->linesize[1] + W / 4]) -
                    wantU) <= 4 &&
           std::abs(int(frame->data[2][size_t(H / 4) * frame->linesize[2] + W / 4]) -
                    wantV) <= 4;
      ++decoded;
      av_frame_unref(frame);
    }
  };
  for (const auto &accessUnit : accessUnits) {
    if (!ok || av_new_packet(packet, int(accessUnit.size())) < 0) {
      ok = false;
      break;
    }
    std::memcpy(packet->data, accessUnit.data(), accessUnit.size());
    ok = avcodec_send_packet(ctx, packet) >= 0;
    av_packet_unref(packet);
    drain();
  }
  if (ok) {
    ok = avcodec_send_packet(ctx, nullptr) >= 0;
    drain();
  }
  ok = ok && decoded == accessUnits.size();
  av_frame_free(&frame);
  av_packet_free(&packet);
  avcodec_free_context(&ctx);
  return ok;
}
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
} // namespace
int main(int argc, char** argv) {
  if (argc == 2 && std::strcmp(argv[1], "--4k") == 0) {
    W = 3840; H = 2400;
  } else if (argc != 1) {
    std::fprintf(stderr, "usage: integration-test [--4k]\n");
    return 2;
  }
  Egl e;
  if (!ck(e.init(), "EGL"))
    return 1;
  GLuint tex = 0;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  std::vector<unsigned char> pixels(size_t(W) * H * 4);
  for (size_t i = 0; i < pixels.size(); i += 4) {
    pixels[i] = 50;
    pixels[i + 1] = 25;
    pixels[i + 2] = 10;
    pixels[i + 3] = 128;
  }
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE,
               pixels.data());
  viewflow::gpu::GpuDmabufEncoder enc({W, H, 4U * 1024U * 1024U});
  if (!ck(enc.ready(), "encoder"))
    return 1;
  // The first frame must naturally be an IDR even without a request.  The
  // next two deliberately cover identical and changed producer images; both
  // must remain P frames inside the persistent GOP.  The final request must
  // be a genuine H.264 IDR (NAL type 5), not merely packet metadata.
  constexpr std::array<bool, 4> forceIdr = {false, false, false, true};
  std::vector<std::vector<unsigned char>> gopAccessUnits;
  std::vector<std::array<int, 3>> gopStraightRgb;
  std::vector<bool> gopExpectIdr;
  for (int i = 0; i < int(forceIdr.size()); i++) {
    if (!ck(eglMakeCurrent(e.d, e.s, e.s, e.c) == EGL_TRUE,
            "restore producer EGL context after encoder construction"))
      return 1;
    for (size_t p = 0; p < pixels.size(); p += 4) {
      const int change = i < 2 ? 0 : i * 20;
      pixels[p] = static_cast<unsigned char>(50 + change);
      pixels[p + 1] = static_cast<unsigned char>(25 + change / 2);
      pixels[p + 2] = static_cast<unsigned char>(10 + change / 4);
      pixels[p + 3] = 128;
    }
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE,
                    pixels.data());
    Export x;
    if (!ck(exportFrame(e, tex, x), "export native fence DMA-BUF"))
      return 1;
    viewflow::gpu::DmabufFrame in{};
    in.dmaBufFd = x.fd;
    in.nativeFenceFd = x.fence;
    in.imageWidth = W;
    in.imageHeight = H;
    in.stride = x.stride;
    in.offset = x.offset;
    in.modifier = x.modifier;
    in.fourcc = 0x34324241U;
    in.cropWidth = W;
    in.cropHeight = H;
    in.metadata = {std::uint64_t(i + 1), std::uint64_t(700 + i), 99};
    std::string error;
    viewflow::gpu::EncodedDmabufFrame out;
    auto disposition = viewflow::gpu::EncodeDisposition::Failed;
    const bool encoded = enc.encode(in, forceIdr[i], deadlineNs(5000), out, &error, &disposition);
    if (!encoded)
      std::fprintf(stderr, "encoder error: %s\n", error.c_str());
    if (!ck(encoded, error.c_str()))
      return 1;
    if (!ck(disposition == viewflow::gpu::EncodeDisposition::Encoded, "encoded disposition"))
      return 1;
    const bool expectIdr = i == 0 || forceIdr[i];
    if (!ck(out.metadata.frameId == in.metadata.frameId &&
                out.metadata.geometryEpoch == 99 && out.idr == expectIdr &&
                hasIdrNal(out.colorAnnexB) == expectIdr && !out.colorAnnexB.empty(),
            i == 0 ? "first-frame H.264 IDR NAL" :
            (i == 1 ? "unchanged frame remains P" :
             (i == 2 ? "changed frame remains P" : "forced H.264 IDR NAL"))))
      return 1;
    if (!ck(out.rawAlpha.size() == size_t(W) * H && out.rawAlpha[0] == 128 &&
                out.rawAlpha.back() == 128,
            "alpha exact"))
      return 1;
    const int change = i < 2 ? 0 : i * 20;
    const int straightRed = (50 + change) * 255 / 128,
              straightGreen = (25 + change / 2) * 255 / 128,
              straightBlue = (10 + change / 4) * 255 / 128;
    gopAccessUnits.push_back(out.colorAnnexB);
    gopStraightRgb.push_back({std::min(255, straightRed),
                               std::min(255, straightGreen),
                               std::min(255, straightBlue)});
    gopExpectIdr.push_back(expectIdr);
    if (!ck(!expectIdr ||
                decodedBt709LimitedMatches(out.colorAnnexB, std::min(255, straightRed),
                                           std::min(255, straightGreen),
                                           std::min(255, straightBlue)),
            "BT.709 limited VUI/color oracle from premultiplied input"))
      return 1;
  }
  if (!ck(decodedBt709LimitedGopMatches(gopAccessUnits, gopStraightRgb,
                                        gopExpectIdr),
          "continuous H.264 decoder validates unchanged/changed P frames"))
    return 1;
  std::printf("GOP AU bytes: first-IDR=%zu unchanged-P=%zu changed-P=%zu forced-IDR=%zu\n",
              gopAccessUnits[0].size(), gopAccessUnits[1].size(),
              gopAccessUnits[2].size(), gopAccessUnits[3].size());
  // Exercise the public C ABI with two distinct producer frames. This remains
  // a bounded synthetic fixture: the five-second deadline is not live-path
  // acceptance criteria.
  vf_gpu_dmabuf_encoder *cabi = nullptr;
  std::vector<std::vector<unsigned char>> cabiUnits;
  std::vector<vf_gpu_dmabuf_output*> retainedOutputs;
  std::vector<const uint8_t*> retainedViews;
  std::vector<std::vector<unsigned char>> retainedAlphas;
  std::vector<std::array<int, 3>> cabiRgb;
  const vf_gpu_dmabuf_encoder_config cabiConfig{
      static_cast<uint32_t>(W), static_cast<uint32_t>(H), 4U * 1024U * 1024U};
  if (!ck(vf_gpu_dmabuf_encoder_create(&cabiConfig, &cabi) == VF_GPU_DMABUF_OK,
          "C ABI encoder create"))
    return 1;
  for (int i = 0; i < 3; ++i) {
    if (!ck(eglMakeCurrent(e.d, e.s, e.s, e.c) == EGL_TRUE,
            "restore producer EGL context for C ABI"))
      return 1;
    const int change = i == 1 ? 0 : i * 20;
    const int red = 60 + change, green = 30 + change / 2, blue = 15 + change / 4;
    for (size_t p = 0; p < pixels.size(); p += 4) {
      pixels[p] = static_cast<unsigned char>(red);
      pixels[p + 1] = static_cast<unsigned char>(green);
      pixels[p + 2] = static_cast<unsigned char>(blue);
      pixels[p + 3] = 128;
    }
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE,
                    pixels.data());
    Export exported;
    if (!ck(exportFrame(e, tex, exported), "C ABI export native fence DMA-BUF"))
      return 1;
    vf_gpu_dmabuf_frame input{};
    input.dma_buf_fd = exported.fd;
    input.native_fence_fd = exported.fence;
    input.image_width = W;
    input.image_height = H;
    input.stride = static_cast<uint32_t>(exported.stride);
    input.offset = static_cast<uint32_t>(exported.offset);
    input.fourcc = 0x34324241U;
    input.modifier = exported.modifier;
    input.crop_width = W;
    input.crop_height = H;
    input.frame_id = static_cast<uint64_t>(100 + 2 * i);
    input.capture_timestamp_ns = static_cast<uint64_t>(900 + 2 * i);
    input.geometry_epoch = 99;
    vf_gpu_dmabuf_output *output = nullptr;
    uint32_t requestIdr = i == 2;
#ifdef VIEWFLOW_TEST_GPU_EXPIRY
    {
      auto dropped = input;
      --dropped.frame_id;
      --dropped.capture_timestamp_ns;
      vf_test_expire_gpu_preparation(i == 0 ? 3U : static_cast<unsigned>(i));
      output = reinterpret_cast<vf_gpu_dmabuf_output *>(uintptr_t{1});
      if (!ck(vf_gpu_dmabuf_encoder_encode_recoverable(cabi, &dropped, requestIdr,
                  deadlineNs(5000), &output) == VF_GPU_DMABUF_EXPIRED_CLEAN && output == nullptr,
              "injected pre-submission expiry cleaned without output"))
        return 1;
    }
    if (i == 2) {
      auto dropped = input;
      --dropped.frame_id;
      --dropped.capture_timestamp_ns;
      vf_test_expire_gpu_preparation(5);
      output = reinterpret_cast<vf_gpu_dmabuf_output *>(uintptr_t{1});
      if (!ck(vf_gpu_dmabuf_encoder_encode_recoverable(cabi, &dropped, 0,
                  deadlineNs(5000), &output) == VF_GPU_DMABUF_EXPIRED_AFTER_SUBMISSION &&
                  output == nullptr, "C ABI drained late packet reports distinct cleanup status")) return 1;
      requestIdr = 0; // Native recovery must force IDR even without caller request.
    }
#endif
    const auto encodeCall = i == 1 ? vf_gpu_dmabuf_encoder_encode_recoverable : vf_gpu_dmabuf_encoder_encode;
    if (!ck(encodeCall(cabi, &input, requestIdr, deadlineNs(5000), &output) ==
                VF_GPU_DMABUF_OK && output != nullptr,
            "C ABI encode"))
      return 1;
    vf_gpu_dmabuf_output_info info{};
    if (!ck(vf_gpu_dmabuf_output_get_info(output, &info) == VF_GPU_DMABUF_OK &&
                info.frame_id == input.frame_id &&
                info.capture_timestamp_ns == input.capture_timestamp_ns &&
                info.geometry_epoch == input.geometry_epoch && info.idr == (i != 1) &&
                info.color_annex_b_bytes != 0 && info.raw_alpha_bytes == size_t(W) * H,
            "C ABI output info"))
      return 1;
    size_t colorBytes = 0, alphaBytes = 0;
    if (!ck(vf_gpu_dmabuf_output_copy_color(output, nullptr, 0, &colorBytes) ==
                VF_GPU_DMABUF_BUFFER_TOO_SMALL &&
                vf_gpu_dmabuf_output_copy_raw_alpha(output, nullptr, 0, &alphaBytes) ==
                    VF_GPU_DMABUF_BUFFER_TOO_SMALL &&
                colorBytes == info.color_annex_b_bytes && alphaBytes == info.raw_alpha_bytes,
            "C ABI output sizes"))
      return 1;
    std::vector<unsigned char> color(colorBytes), alpha(alphaBytes);
    if (!ck(vf_gpu_dmabuf_output_copy_color(output, color.data(), color.size(), &colorBytes) ==
                VF_GPU_DMABUF_OK &&
                vf_gpu_dmabuf_output_copy_raw_alpha(output, alpha.data(), alpha.size(), &alphaBytes) ==
                    VF_GPU_DMABUF_OK &&
                alpha.front() == 128 && alpha.back() == 128 &&
                hasIdrNal(color) == (i != 1) &&
                ((i == 1) || decodedBt709LimitedMatches(color, red * 255 / 128,
                                                         green * 255 / 128,
                                                         blue * 255 / 128)),
            "C ABI copied BT.709 color/VUI and alpha"))
      return 1;
    cabiUnits.push_back(color);
    cabiRgb.push_back({red * 255 / 128, green * 255 / 128, blue * 255 / 128});
    const uint8_t* view = nullptr;
    size_t viewLength = 0;
    if (!ck(vf_gpu_dmabuf_output_view_raw_alpha(output, &view, &viewLength) == VF_GPU_DMABUF_OK &&
                view && viewLength == alpha.size() &&
                std::equal(alpha.begin(), alpha.end(), view), "C ABI immutable alpha view")) return 1;
    retainedOutputs.push_back(output);
    retainedViews.push_back(view);
    retainedAlphas.push_back(std::move(alpha));
  }
  if (!ck(decodedBt709LimitedGopMatches(cabiUnits, cabiRgb, {true, false, true}),
          "C ABI GOP decodes across clean expiry without missing references"))
    return 1;
  if (!ck(vf_gpu_dmabuf_encoder_destroy(cabi) == VF_GPU_DMABUF_OK,
          "C ABI encoder destroy"))
    return 1;
  // Earlier immutable outputs survive later encodes and encoder destruction.
  for (size_t i = 0; i < retainedOutputs.size(); ++i) {
    const uint8_t* view = nullptr;
    size_t length = 0;
    if (!ck(vf_gpu_dmabuf_output_view_raw_alpha(retainedOutputs[i], &view, &length) == VF_GPU_DMABUF_OK &&
                view == retainedViews[i] && length == retainedAlphas[i].size() &&
                std::equal(retainedAlphas[i].begin(), retainedAlphas[i].end(), view),
            "retained alpha snapshot independent of encoder lifetime")) return 1;
    if (!ck(vf_gpu_dmabuf_output_destroy(retainedOutputs[i]) == VF_GPU_DMABUF_OK,
            "retained C ABI output destroy")) return 1;
  }
  // Prove a destroyed peer releases only its own EGL objects: the existing
  // encoder and the producer context both remain functional.
  if (!ck(eglMakeCurrent(e.d, e.s, e.s, e.c) == EGL_TRUE,
          "restore producer for peer"))
    return 1;
  {
    Export peerExport;
    if (!ck(exportFrame(e, tex, peerExport), "export peer frame"))
      return 1;
    viewflow::gpu::DmabufFrame peerInput{};
    peerInput.dmaBufFd = peerExport.fd;
    peerInput.nativeFenceFd = peerExport.fence;
    peerInput.imageWidth = W;
    peerInput.imageHeight = H;
    peerInput.stride = peerExport.stride;
    peerInput.offset = peerExport.offset;
    peerInput.modifier = peerExport.modifier;
    peerInput.fourcc = 0x34324241U;
    peerInput.cropWidth = W;
    peerInput.cropHeight = H;
    peerInput.metadata = {20, 800, 99};
    {
      viewflow::gpu::GpuDmabufEncoder peer({W, H, 4U * 1024U * 1024U});
      viewflow::gpu::EncodedDmabufFrame peerOut;
      std::string peerError;
      if (!ck(peer.ready() && peer.encode(peerInput, true, deadlineNs(5000),
                                          peerOut, &peerError),
              "peer encoder frame"))
        return 1;
    }
  }
  if (!ck(eglMakeCurrent(e.d, e.s, e.s, e.c) == EGL_TRUE,
          "producer survives peer destruction"))
    return 1;
  {
    Export survivorExport;
    if (!ck(exportFrame(e, tex, survivorExport), "export survivor frame"))
      return 1;
    viewflow::gpu::DmabufFrame survivorInput{};
    survivorInput.dmaBufFd = survivorExport.fd;
    survivorInput.nativeFenceFd = survivorExport.fence;
    survivorInput.imageWidth = W;
    survivorInput.imageHeight = H;
    survivorInput.stride = survivorExport.stride;
    survivorInput.offset = survivorExport.offset;
    survivorInput.modifier = survivorExport.modifier;
    survivorInput.fourcc = 0x34324241U;
    survivorInput.cropWidth = W;
    survivorInput.cropHeight = H;
    survivorInput.metadata = {21, 801, 99};
    viewflow::gpu::EncodedDmabufFrame survivorOut;
    std::string survivorError;
    if (!ck(enc.encode(survivorInput, true, deadlineNs(5000), survivorOut,
                       &survivorError),
            "surviving encoder after peer destruction"))
      return 1;
  }
  if (!ck(eglMakeCurrent(e.d, e.s, e.s, e.c) == EGL_TRUE,
          "restore producer for atlas fixture"))
    return 1;
  {
    // Two independently exported owned producer images. No desktop capture.
    for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
      auto* p = pixels.data() + (size_t(y) * W + x) * 4;
      p[0] = x < 64 ? 50 : 16; p[1] = x < 64 ? 25 : 32;
      p[2] = x < 64 ? 10 : 48; p[3] = x < 64 ? 128 : 64;
    }
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    Export atlasExport;
    if (!ck(exportFrame(e, tex, atlasExport), "export atlas fixture")) return 1;
    GLuint secondTexture = 0;
    glGenTextures(1, &secondTexture);
    glBindTexture(GL_TEXTURE_2D, secondTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    Export secondExport;
    if (!ck(exportFrame(e, secondTexture, secondExport), "export second independent atlas fixture")) return 1;
    viewflow::gpu::DmabufFrame in{};
    in.dmaBufFd = atlasExport.fd; in.nativeFenceFd = atlasExport.fence;
    in.imageWidth = W; in.imageHeight = H; in.stride = atlasExport.stride;
    in.offset = atlasExport.offset; in.modifier = atlasExport.modifier;
    in.fourcc = 0x34324241U; in.cropWidth = 64; in.cropHeight = 48;
    in.metadata = {22, 802, 99};
    const auto leaseDeadline = deadlineNs(5000);
    std::vector<viewflow::gpu::DmabufAtlasTile> tiles = {
        {in, 0, 0, leaseDeadline}, {in, 96, 64, leaseDeadline}};
    tiles[1].frame.cropX = 64;
    tiles[1].frame.dmaBufFd = secondExport.fd;
    tiles[1].frame.nativeFenceFd = secondExport.fence;
    tiles[1].frame.stride = secondExport.stride;
    tiles[1].frame.offset = secondExport.offset;
    tiles[1].frame.modifier = secondExport.modifier;
    tiles[1].frame.metadata = {23, 803, 100};
    viewflow::gpu::EncodedDmabufFrame out;
    std::string error;
    auto disposition = viewflow::gpu::EncodeDisposition::Encoded;
    auto rejected = tiles;
    rejected[1].x = 32; rejected[1].y = 0;
    if (!ck(!enc.encodeAtlas(rejected, {24, 804, 101}, true, deadlineNs(5000), out, &error, &disposition) &&
            disposition == viewflow::gpu::EncodeDisposition::Failed && out.colorAnnexB.empty(),
            "atlas overlap rejected before submission")) return 1;
    rejected = tiles; rejected[1].absoluteMonotonicDeadlineNs = deadlineNs(-1);
    if (!ck(!enc.encodeAtlas(rejected, {24, 804, 101}, true, deadlineNs(5000), out, &error),
            "batch cannot renew expired tile lease")) return 1;
    vf_gpu_dmabuf_encoder_config atlasConfig{static_cast<uint32_t>(W), static_cast<uint32_t>(H), 4U * 1024U * 1024U};
#ifdef VIEWFLOW_TEST_GPU_EXPIRY
    for (const unsigned stage : {3U, 4U, 2U, 5U}) {
      vf_test_expire_gpu_preparation(stage);
      if (!ck(!enc.encodeAtlas(tiles, {24, 804, 101}, true, deadlineNs(5000), out,
                               &error, &disposition) &&
              disposition == (stage == 5U ? viewflow::gpu::EncodeDisposition::ExpiredAfterSubmission :
                                           viewflow::gpu::EncodeDisposition::ExpiredBeforeSubmission) &&
              out.colorAnnexB.empty() && out.rawAlpha.empty(),
              "atlas expiry before import or after scratch borrowing is clean")) return 1;
    }
#endif
    vf_gpu_dmabuf_encoder* atlasEncoder = nullptr;
    if (!ck(vf_gpu_dmabuf_encoder_create(&atlasConfig, &atlasEncoder) == VF_GPU_DMABUF_OK,
            "create C ABI atlas encoder")) return 1;
    const auto allTiles = tiles;
    std::uint64_t atlasFrame = 24;
    // Re-enter after empty and partial frames: the two scratch buffers exchange
    // roles only when a final tile is borrowed, so parity must not affect pixels.
    for (int count : {2, 1, 0, 1, 2, 0, 2}) {
      tiles.assign(allTiles.begin(), allTiles.begin() + count);
      const auto frameId = atlasFrame++;
      if (!enc.encodeAtlas(tiles, {frameId, frameId + 780, 101},
                           true, deadlineNs(5000), out, &error, &disposition)) {
        std::fprintf(stderr, "atlas encoding failed: %s\n", error.c_str()); return 1;
      }
      bool alphaOk = out.rawAlpha.size() == size_t(W) * H;
      for (int y = 0; alphaOk && y < H; ++y) for (int x = 0; x < W; ++x) {
        const int want = count > 0 && x < 64 && y < 48 ? 128 :
            count == 2 && x >= 96 && x < 160 && y >= 64 && y < 112 ? 64 : 0;
        if (out.rawAlpha[size_t(y) * W + x] != want) { alphaOk = false; break; }
      }
      if (!ck(alphaOk && out.metadata.frameId == frameId &&
              out.metadata.geometryEpoch == 101 && out.idr &&
              disposition == viewflow::gpu::EncodeDisposition::Encoded &&
              decodedAtlasMatches(out.colorAnnexB, count),
              "atlas decoded colors and exact paired alpha including retired tile")) return 1;
      std::vector<vf_gpu_dmabuf_atlas_tile> ctiles;
      for (const auto& tile : tiles) {
        vf_gpu_dmabuf_atlas_tile mapped{};
        mapped.frame.dma_buf_fd = tile.frame.dmaBufFd;
        mapped.frame.native_fence_fd = tile.frame.nativeFenceFd;
        mapped.frame.image_width = tile.frame.imageWidth;
        mapped.frame.image_height = tile.frame.imageHeight;
        mapped.frame.stride = tile.frame.stride;
        mapped.frame.offset = tile.frame.offset;
        mapped.frame.fourcc = tile.frame.fourcc;
        mapped.frame.modifier = tile.frame.modifier;
        mapped.frame.crop_x = tile.frame.cropX;
        mapped.frame.crop_y = tile.frame.cropY;
        mapped.frame.crop_width = tile.frame.cropWidth;
        mapped.frame.crop_height = tile.frame.cropHeight;
        mapped.frame.frame_id = tile.frame.metadata.frameId;
        mapped.frame.capture_timestamp_ns = tile.frame.metadata.captureTimestampNs;
        mapped.frame.geometry_epoch = tile.frame.metadata.geometryEpoch;
        mapped.x = tile.x; mapped.y = tile.y;
        mapped.deadline_monotonic_ns = tile.absoluteMonotonicDeadlineNs;
        ctiles.push_back(mapped);
      }
      vf_gpu_dmabuf_atlas atlas{sizeof(vf_gpu_dmabuf_atlas), VF_GPU_DMABUF_ATLAS_VERSION,
          uint32_t(ctiles.size()), 0, ctiles.data(), out.metadata.frameId,
          out.metadata.captureTimestampNs, out.metadata.geometryEpoch};
      vf_gpu_dmabuf_output* coutput = nullptr;
      if (!ck(vf_gpu_dmabuf_encoder_encode_atlas_recoverable(atlasEncoder, &atlas, 1,
                  deadlineNs(5000), &coutput) == VF_GPU_DMABUF_OK, "C ABI atlas encode")) return 1;
      vf_gpu_dmabuf_output_info info{};
      if (!ck(vf_gpu_dmabuf_output_get_info(coutput, &info) == VF_GPU_DMABUF_OK &&
              info.frame_id == atlas.frame_id && info.capture_timestamp_ns == atlas.capture_timestamp_ns &&
              info.geometry_epoch == atlas.geometry_epoch && info.idr == 1 &&
              info.raw_alpha_bytes == size_t(W) * H && info.color_annex_b_bytes > 0 &&
              info.color_annex_b_bytes <= atlasConfig.max_access_unit_bytes,
              "C ABI atlas identity and bounds")) return 1;
      std::vector<unsigned char> color(info.color_annex_b_bytes), alpha(info.raw_alpha_bytes);
      size_t required = 0;
      if (!ck(vf_gpu_dmabuf_output_copy_color(coutput, color.data(), color.size(), &required) == VF_GPU_DMABUF_OK &&
              required == color.size() && decodedAtlasMatches(color, count) &&
              vf_gpu_dmabuf_output_copy_raw_alpha(coutput, alpha.data(), alpha.size(), &required) == VF_GPU_DMABUF_OK &&
              required == alpha.size() && alpha == out.rawAlpha,
              "C ABI atlas decoded color and exact paired alpha")) return 1;
      if (!ck(vf_gpu_dmabuf_output_destroy(coutput) == VF_GPU_DMABUF_OK, "destroy C ABI atlas output")) return 1;
    }
    // Nearly full-canvas final tiles exercise the borrowed allocation at 4K
    // capacity. Shrinking and expanding must clear every uncovered pixel.
    for (int inset : {2, 66, 2}) {
      auto large = in;
      large.cropWidth = W - inset;
      large.cropHeight = H - inset;
      const auto frameId = atlasFrame++;
      if (!ck(enc.encodeAtlas({{large, 0, 0, deadlineNs(5000)}},
                             {frameId, frameId + 780, 101}, true,
                             deadlineNs(5000), out, &error, &disposition),
              "large final atlas tile encode")) return 1;
      bool exact = out.rawAlpha.size() == size_t(W) * H;
      for (int y = 0; exact && y < H; ++y) for (int x = 0; x < W; ++x) {
        const int wanted = x < W - inset && y < H - inset ? (x < 64 ? 128 : 64) : 0;
        if (out.rawAlpha[size_t(y) * W + x] != wanted) { exact = false; break; }
      }
      if (!ck(exact, "large final tile and cleared padding alpha exact")) return 1;
    }
    std::printf("PASS atlas scratch transitions and full alpha %dx%d\n", W, H);
    vf_gpu_dmabuf_atlas invalidAtlas{};
    invalidAtlas.struct_size = sizeof(invalidAtlas); invalidAtlas.version = VF_GPU_DMABUF_ATLAS_VERSION;
    invalidAtlas.reserved = 1;
    vf_gpu_dmabuf_output* invalidOutput = reinterpret_cast<vf_gpu_dmabuf_output*>(uintptr_t(1));
    if (!ck(vf_gpu_dmabuf_encoder_encode_atlas_recoverable(atlasEncoder, &invalidAtlas, 1,
                deadlineNs(5000), &invalidOutput) == VF_GPU_DMABUF_INVALID_ARGUMENT && invalidOutput == nullptr,
            "C ABI atlas reserved field rejected")) return 1;
    invalidAtlas.reserved = 0;
    if (!ck(vf_gpu_dmabuf_encoder_encode_atlas_recoverable(atlasEncoder, &invalidAtlas, 1,
                deadlineNs(5000), &invalidOutput) == VF_GPU_DMABUF_ENCODER_FAILED && invalidOutput == nullptr,
            "C ABI invalid atlas poisons session")) return 1;
    if (!ck(vf_gpu_dmabuf_encoder_destroy(atlasEncoder) == VF_GPU_DMABUF_OK,
            "destroy C ABI atlas encoder")) return 1;
    if (!ck(eglMakeCurrent(e.d, e.s, e.s, e.c) == EGL_TRUE, "restore producer after atlas")) return 1;
    glDeleteTextures(1, &secondTexture);
  }
  if (!ck(eglMakeCurrent(e.d, e.s, e.s, e.c) == EGL_TRUE,
          "restore producer for expiry fixture"))
    return 1;
  Export expiredExport;
  if (!ck(exportFrame(e, tex, expiredExport), "export valid expiry fixture"))
    return 1;
  viewflow::gpu::DmabufFrame expired{};
  expired.dmaBufFd = expiredExport.fd;
  expired.nativeFenceFd = expiredExport.fence;
  expired.imageWidth = W;
  expired.imageHeight = H;
  expired.stride = expiredExport.stride;
  expired.offset = expiredExport.offset;
  expired.modifier = expiredExport.modifier;
  expired.fourcc = 0x34324241U;
  expired.cropWidth = W;
  expired.cropHeight = H;
  expired.metadata = {3, 702, 99};
  viewflow::gpu::EncodedDmabufFrame discarded;
  discarded.colorAnnexB = {1, 2, 3};
  auto disposition = viewflow::gpu::EncodeDisposition::ExpiredBeforeSubmission;
#ifdef VIEWFLOW_TEST_GPU_EXPIRY
  vf_test_expire_gpu_preparation(5);
  if (!ck(!enc.encode(expired, false, deadlineNs(5000), discarded, nullptr, &disposition) &&
          disposition == viewflow::gpu::EncodeDisposition::ExpiredAfterSubmission &&
          discarded.colorAnnexB.empty() && discarded.rawAlpha.empty(),
          "late matching packet is drained with completed cleanup")) return 1;
  expired.metadata = {4, 703, 99};
  if (!ck(enc.encode(expired, false, deadlineNs(5000), discarded, nullptr, &disposition) &&
          discarded.idr && disposition == viewflow::gpu::EncodeDisposition::Encoded,
          "next frame forces IDR after drained late packet")) return 1;
#endif
  if (!ck(!enc.encode(expired, true, deadlineNs(-1), discarded, nullptr, &disposition),
          "expired admission rejected"))
    return 1;
  if (!ck(disposition == viewflow::gpu::EncodeDisposition::ExpiredBeforeSubmission &&
          discarded.colorAnnexB.empty() && discarded.rawAlpha.empty(),
          "early scheduling miss clears output before any source reads"))
    return 1;
  expired.metadata = {5, 704, 99};
  if (!ck(enc.encode(expired, true, deadlineNs(5000), discarded, nullptr, &disposition) &&
          disposition == viewflow::gpu::EncodeDisposition::Encoded && discarded.idr &&
          !discarded.colorAnnexB.empty(),
          "encoder remains usable after early scheduling miss"))
    return 1;
  glDeleteTextures(1, &tex);
  std::puts("PASS GPU DMA-BUF encoder GOP native-fence and atlas integration");
}

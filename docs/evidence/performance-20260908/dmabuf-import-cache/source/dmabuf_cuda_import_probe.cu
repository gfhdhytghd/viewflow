// Cross-process DMA-BUF import capability gate.  Probe-only reuse keeps the
// CUDA/NVENC mechanics byte-for-byte identical to the owned-texture probe.
#define main viewflow_owned_gl_cuda_probe_main
#include "gl_cuda_nvenc_encode_probe.cu"
#undef main

#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/wait.h>

namespace {
struct Meta { uint32_t fourcc, width, height, stride, offset; uint64_t modifier; };

bool samples_match(const char* stage, const std::array<unsigned char, 4>* expected, GLuint texture) {
  GLuint fb = 0; glGenFramebuffers(1, &fb); glBindFramebuffer(GL_FRAMEBUFFER, fb);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
  bool ok = glGetError() == GL_NO_ERROR && glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  for (int band = 0; ok && band < 3; ++band) {
    std::array<unsigned char, 4> pixel{};
    glReadPixels(g_width / 2, (band * 2 + 1) * g_height / 6, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
    ok = glGetError() == GL_NO_ERROR && pixel == expected[band];
    std::cerr << stage << " sample " << band << " rgba=" << static_cast<unsigned>(pixel[0]) << ',' << static_cast<unsigned>(pixel[1]) << ','
              << static_cast<unsigned>(pixel[2]) << ',' << static_cast<unsigned>(pixel[3]) << '\n';
  }
  glDeleteFramebuffers(1, &fb); return ok;
}

bool send_fd(int s, const Meta& meta, int fd) {
  iovec iov{.iov_base = const_cast<Meta*>(&meta), .iov_len = sizeof(meta)};
  std::array<unsigned char, CMSG_SPACE(sizeof(int))> control{};
  msghdr msg{}; msg.msg_iov = &iov; msg.msg_iovlen = 1; msg.msg_control = control.data(); msg.msg_controllen = control.size();
  cmsghdr* c = CMSG_FIRSTHDR(&msg); c->cmsg_level = SOL_SOCKET; c->cmsg_type = SCM_RIGHTS; c->cmsg_len = CMSG_LEN(sizeof(fd)); std::memcpy(CMSG_DATA(c), &fd, sizeof(fd));
  return sendmsg(s, &msg, MSG_NOSIGNAL) == static_cast<ssize_t>(sizeof(meta));
}
bool recv_fd(int s, Meta* meta, int* fd) {
  std::array<unsigned char, CMSG_SPACE(sizeof(int))> control{}; iovec iov{.iov_base = meta, .iov_len = sizeof(*meta)};
  msghdr msg{}; msg.msg_iov = &iov; msg.msg_iovlen = 1; msg.msg_control = control.data(); msg.msg_controllen = control.size();
  if (recvmsg(s, &msg, MSG_CMSG_CLOEXEC) != static_cast<ssize_t>(sizeof(*meta)) || (msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC))) return false;
  cmsghdr* c = CMSG_FIRSTHDR(&msg); if (!c || c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS || c->cmsg_len != CMSG_LEN(sizeof(int))) return false;
  std::memcpy(fd, CMSG_DATA(c), sizeof(*fd)); return *fd >= 0;
}
bool verify_imported_alpha(cudaGraphicsResource_t resource) {
  if (!cuda_ok(cudaGraphicsMapResources(1, &resource, nullptr), "cudaGraphicsMapResources(import alpha)")) return false;
  cudaArray_t array = nullptr;
  if (!cuda_ok(cudaGraphicsSubResourceGetMappedArray(&array, resource, 0, 0), "cudaGraphicsSubResourceGetMappedArray(import alpha)")) {
    cudaGraphicsUnmapResources(1, &resource, nullptr); return false;
  }
  bool ok = true;
  for (int band = 0; band < 3; ++band) {
    std::array<unsigned char, 4> pixel{};
    const bool copied = cuda_ok(cudaMemcpy2DFromArray(pixel.data(), 4, array, static_cast<std::size_t>(g_width / 2) * 4,
                                               static_cast<std::size_t>((band * 2 + 1) * g_height / 6), 4, 1, cudaMemcpyDeviceToHost),
                        "cudaMemcpy2DFromArray(import alpha exact check)");
    if (!copied || pixel[3] != kColors[band][3]) {
      std::cerr << "FAIL imported alpha partition " << band << ": observed=" << static_cast<unsigned>(pixel[3])
                << " expected=" << static_cast<unsigned>(kColors[band][3]) << '\n';
      ok = false;
    }
  }
  return cuda_ok(cudaGraphicsUnmapResources(1, &resource, nullptr), "cudaGraphicsUnmapResources(import alpha)") && ok;
}

bool verify_partition_decode(const char* path) {
  std::ifstream input(path, std::ios::binary);
  std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(input)), {});
  if (bytes.empty() || bytes.size() > 32U * 1024U * 1024U) return false;
  AvRefs refs;
  const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
  refs.decoder = codec ? avcodec_alloc_context3(codec) : nullptr;
  AVPacket* packet = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  const auto cleanup = [&] { av_packet_free(&packet); av_frame_free(&frame); };
  if (!refs.decoder || !packet || !frame ||
      !av_ok(avcodec_open2(refs.decoder, codec, nullptr), "open partition decoder") ||
      !av_ok(av_new_packet(packet, static_cast<int>(bytes.size())), "allocate partition packet")) {
    cleanup(); return false;
  }
  // The producer requires exactly one access unit. av_new_packet supplies the
  // decoder padding; this path does not concatenate multiple frame packets.
  std::memcpy(packet->data, bytes.data(), bytes.size());
  if (!av_ok(avcodec_send_packet(refs.decoder, packet), "send partition AU") ||
      !av_ok(avcodec_send_packet(refs.decoder, nullptr), "flush partition decoder")) {
    cleanup(); return false;
  }
  int frames = 0;
  bool ok = true;
  for (;;) {
    const int result = avcodec_receive_frame(refs.decoder, frame);
    if (result == AVERROR_EOF) break;
    if (result < 0 || ++frames != 1 || frame->width != g_width ||
        frame->height != g_height || frame->format != AV_PIX_FMT_YUV420P) {
      ok = false; break;
    }
    for (int band = 0; band < 3; ++band) {
      const auto& c = kColors[band];
      const int expected[3] = {
        ((66 * c[0] + 129 * c[1] + 25 * c[2] + 128) >> 8) + 16,
        ((-38 * c[0] - 74 * c[1] + 112 * c[2] + 128) >> 8) + 128,
        ((112 * c[0] - 94 * c[1] - 18 * c[2] + 128) >> 8) + 128};
      const int y = (2 * band + 1) * g_height / 6;
      for (int plane = 0; plane < 3; ++plane) {
        const int divisor = plane == 0 ? 1 : 2;
        const int observed = frame->data[plane][
          static_cast<std::size_t>(y / divisor) * frame->linesize[plane] + g_width / 2 / divisor];
        if (std::abs(observed - expected[plane]) > 4) {
          std::cerr << "FAIL decoded partition " << band << " plane " << plane
                    << " observed=" << observed << " expected=" << expected[plane] << '\n';
          ok = false;
        }
      }
    }
    av_frame_unref(frame);
  }
  cleanup();
  return ok && frames == 1;
}

int consumer(int socket_fd) {
  Meta m{}; int dma_fd = -1;
  if (!recv_fd(socket_fd, &m, &dma_fd) || m.fourcc != 0x34324241U || m.width != static_cast<uint32_t>(g_width) || m.height != static_cast<uint32_t>(g_height) || m.stride == 0) return EXIT_FAILURE;
  EglScope egl; if (!egl.create()) { close(dma_fd); return EXIT_FAILURE; }
  const auto image_create = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
  const auto target = reinterpret_cast<void (*)(GLenum, void*)>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
  if (!image_create || !target) { close(dma_fd); return EXIT_FAILURE; }
  const EGLint attrs[] = {EGL_WIDTH, g_width, EGL_HEIGHT, g_height, EGL_LINUX_DRM_FOURCC_EXT, static_cast<EGLint>(m.fourcc), EGL_DMA_BUF_PLANE0_FD_EXT, dma_fd,
                          EGL_DMA_BUF_PLANE0_OFFSET_EXT, static_cast<EGLint>(m.offset), EGL_DMA_BUF_PLANE0_PITCH_EXT, static_cast<EGLint>(m.stride),
                          EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, static_cast<EGLint>(m.modifier), EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, static_cast<EGLint>(m.modifier >> 32), EGL_NONE};
  EGLImageKHR image = image_create(egl.display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr, attrs);
  if (image == EGL_NO_IMAGE_KHR) { close(dma_fd); return EXIT_FAILURE; }
  GLuint texture = 0; glGenTextures(1, &texture); glBindTexture(GL_TEXTURE_2D, texture); target(GL_TEXTURE_2D, image); glFinish();
  const bool imported_gl_alpha_ok = samples_match("consumer-import", kColors.data(), texture);
  unsigned int count = 0; int device = -1;
  cudaGraphicsResource_t resource = nullptr;
  bool ok = cuda_ok(cudaGLGetDevices(&count, &device, 1, cudaGLDeviceListAll), "cudaGLGetDevices(imported GL)") && count == 1 &&
      cuda_ok(cudaSetDevice(device), "cudaSetDevice(imported GL)") && cuda_ok(cudaFree(nullptr), "initialize CUDA") &&
      cuda_ok(cudaGraphicsGLRegisterImage(&resource, texture, GL_TEXTURE_2D, cudaGraphicsRegisterFlagsReadOnly), "cudaGraphicsGLRegisterImage(imported DMA-BUF texture)");
  AvRefs av; char path[] = "/tmp/viewflow-dmabuf-cuda-nvenc-XXXXXX.h264"; int fd = -1; FILE* out = nullptr; int written = 0;
  if (ok) ok = create_encoder(av);
  if (ok && (fd = mkstemps(path, 5)) >= 0) out = fdopen(fd, "wb");
  if (ok && out) ok = encode_from_texture(resource, av.encoder, out, 0, &written);
  if (out) {
    const int flushed = std::fflush(out);
    const int closed = std::fclose(out);
    ok = flushed == 0 && closed == 0 && ok;
  }
  const bool decoded_ok = ok && written == 1 && verify_partition_decode(path);
  const bool alpha_ok = ok && verify_imported_alpha(resource);
  if (resource) { cudaGraphicsUnmapResources(1, &resource, nullptr); cudaGraphicsUnregisterResource(resource); }
  glDeleteTextures(1, &texture); eglDestroyImage(egl.display, image); close(dma_fd);
  if (!ok || !decoded_ok || !imported_gl_alpha_ok || !alpha_ok || written != 1) { if (fd >= 0) std::remove(path); return EXIT_FAILURE; }
  std::cout << "PASS imported DMA-BUF GL texture -> CUDA graphics map/D2D/NVENC; one Annex-B frame PTS=101; decoded partition YUV within 4; three partition alpha samples exact; output=" << path << '\n';
  return EXIT_SUCCESS;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc == 5 && std::string(argv[1]) == "--verify") {
    if (!parse_probe_dimension(argv[3], &g_width) || !parse_probe_dimension(argv[4], &g_height)) return EXIT_FAILURE;
    return verify_partition_decode(argv[2]) ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  if (argc == 5 && std::string(argv[1]) == "--consumer") {
    if (!parse_probe_dimension(argv[2], &g_width) || !parse_probe_dimension(argv[3], &g_height)) return EXIT_FAILURE;
    return consumer(std::atoi(argv[4]));
  }
  if (argc == 3 && (!parse_probe_dimension(argv[1], &g_width) || !parse_probe_dimension(argv[2], &g_height))) return EXIT_FAILURE;
  EglScope egl; if (!egl.create()) return EXIT_FAILURE;
  const auto create = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
  const auto query = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC>(eglGetProcAddress("eglExportDMABUFImageQueryMESA"));
  const auto export_image = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEMESAPROC>(eglGetProcAddress("eglExportDMABUFImageMESA"));
  if (!create || !query || !export_image) return EXIT_FAILURE;
  std::vector<unsigned char> pixels(static_cast<std::size_t>(g_width) * g_height * 4);
  for (int y = 0; y < g_height; ++y) { const auto& c = kColors[std::min(2, y * 3 / g_height)]; for (int x = 0; x < g_width; ++x) std::memcpy(pixels.data() + (static_cast<std::size_t>(y) * g_width + x) * 4, c.data(), 4); }
  GLuint tex = 0; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, g_width, g_height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data()); glFinish();
  if (!samples_match("producer-before-image", kColors.data(), tex)) return EXIT_FAILURE;
  constexpr EGLint image_attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
  EGLImageKHR image = create(egl.display, egl.context, EGL_GL_TEXTURE_2D_KHR, reinterpret_cast<EGLClientBuffer>(static_cast<uintptr_t>(tex)), image_attrs);
  if (image != EGL_NO_IMAGE_KHR && !samples_match("producer-after-image", kColors.data(), tex)) return EXIT_FAILURE;
  int fourcc = 0, planes = 0; EGLuint64KHR mods[4]{}; int fds[4] = {-1,-1,-1,-1}; EGLint stride[4]{}, offset[4]{};
  if (image == EGL_NO_IMAGE_KHR || !egl_ok(query(egl.display, image, &fourcc, &planes, mods), "eglExportDMABUFImageQueryMESA") || !egl_ok(export_image(egl.display, image, fds, stride, offset), "eglExportDMABUFImageMESA") || planes != 1) return EXIT_FAILURE;
  int sv[2]; if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) != 0) return EXIT_FAILURE;
  for (int fd : fds) if (fd >= 0 && fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) { close(sv[0]); close(sv[1]); return EXIT_FAILURE; }
  if (fcntl(sv[0], F_SETFD, FD_CLOEXEC) < 0) { close(sv[0]); close(sv[1]); return EXIT_FAILURE; }
  const pid_t child = fork();
  if (child < 0) { close(sv[0]); close(sv[1]); return EXIT_FAILURE; }
  if (child == 0) { close(sv[0]); char w[16], h[16], s[16]; std::snprintf(w,sizeof(w),"%d",g_width); std::snprintf(h,sizeof(h),"%d",g_height); std::snprintf(s,sizeof(s),"%d",sv[1]); execl(argv[0],argv[0],"--consumer",w,h,s,nullptr); _exit(127); }
  close(sv[1]); const bool sent = send_fd(sv[0], Meta{static_cast<uint32_t>(fourcc),static_cast<uint32_t>(g_width),static_cast<uint32_t>(g_height),static_cast<uint32_t>(stride[0]),static_cast<uint32_t>(offset[0]),mods[0]}, fds[0]); close(sv[0]); int status = 0; bool reaped = false;
  for (int elapsed = 0; elapsed < 5000; elapsed += 10) { const pid_t result = waitpid(child, &status, WNOHANG); if (result == child) { reaped = true; break; } if (result < 0) break; usleep(10000); }
  if (!reaped) { kill(child, SIGKILL); waitpid(child, &status, 0); }
  for (int fd : fds) if (fd >= 0) close(fd); eglDestroyImage(egl.display,image); glDeleteTextures(1,&tex);
  return sent && reaped && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

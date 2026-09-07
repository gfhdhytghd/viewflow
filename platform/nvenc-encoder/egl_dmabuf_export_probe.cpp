// Manual capability probe only.  This owns an independent EGL/GLES pbuffer
// and never attaches to a compositor, window, plugin, or capture pipeline.
// It tests the actual EGL image DMA-BUF export path, including the returned
// descriptor and format metadata.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <climits>
#include <cstring>
#include <iostream>
#include <string>
#include <sys/socket.h>
#include <sys/wait.h>
#include <signal.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

namespace {

const char* egl_error(EGLint e) {
  switch (e) {
    case EGL_SUCCESS: return "EGL_SUCCESS";
    case EGL_NOT_INITIALIZED: return "EGL_NOT_INITIALIZED";
    case EGL_BAD_ACCESS: return "EGL_BAD_ACCESS";
    case EGL_BAD_ALLOC: return "EGL_BAD_ALLOC";
    case EGL_BAD_ATTRIBUTE: return "EGL_BAD_ATTRIBUTE";
    case EGL_BAD_CONTEXT: return "EGL_BAD_CONTEXT";
    case EGL_BAD_CONFIG: return "EGL_BAD_CONFIG";
    case EGL_BAD_DISPLAY: return "EGL_BAD_DISPLAY";
    case EGL_BAD_MATCH: return "EGL_BAD_MATCH";
    case EGL_BAD_PARAMETER: return "EGL_BAD_PARAMETER";
    default: return "EGL_UNKNOWN_ERROR";
  }
}

bool egl_ok(EGLBoolean value, const char* operation) {
  if (value == EGL_TRUE) return true;
  std::cerr << "FAIL " << operation << ": " << egl_error(eglGetError()) << '\n';
  return false;
}

bool gl_ok(const char* operation) {
  const GLenum e = glGetError();
  if (e == GL_NO_ERROR) return true;
  std::cerr << "FAIL " << operation << ": GL error 0x" << std::hex << e << std::dec << '\n';
  return false;
}

class EglScope {
 public:
  ~EglScope() {
    if (display_ != EGL_NO_DISPLAY) {
      eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      if (context_ != EGL_NO_CONTEXT) eglDestroyContext(display_, context_);
      if (surface_ != EGL_NO_SURFACE) eglDestroySurface(display_, surface_);
      eglTerminate(display_);
    }
  }

  bool create() {
    display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display_ == EGL_NO_DISPLAY || eglInitialize(display_, &major_, &minor_) != EGL_TRUE) {
      display_ = device_display();
      if (display_ == EGL_NO_DISPLAY || eglInitialize(display_, &major_, &minor_) != EGL_TRUE) {
        std::cerr << "FAIL eglInitialize: " << egl_error(eglGetError()) << '\n';
        return false;
      }
    }
    if (!egl_ok(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI")) return false;
    constexpr EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE,
                                EGL_OPENGL_ES3_BIT_KHR, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                                EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
    EGLConfig config = nullptr;
    EGLint count = 0;
    if (!egl_ok(eglChooseConfig(display_, attrs, &config, 1, &count), "eglChooseConfig") || count != 1) {
      std::cerr << "FAIL no RGBA GLES3 pbuffer config\n";
      return false;
    }
    constexpr EGLint pbuffer[] = {EGL_WIDTH, 2, EGL_HEIGHT, 2, EGL_NONE};
    surface_ = eglCreatePbufferSurface(display_, config, pbuffer);
    if (surface_ == EGL_NO_SURFACE) {
      std::cerr << "FAIL eglCreatePbufferSurface: " << egl_error(eglGetError()) << '\n';
      return false;
    }
    constexpr EGLint context[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    context_ = eglCreateContext(display_, config, EGL_NO_CONTEXT, context);
    if (context_ == EGL_NO_CONTEXT) {
      std::cerr << "FAIL eglCreateContext: " << egl_error(eglGetError()) << '\n';
      return false;
    }
    return egl_ok(eglMakeCurrent(display_, surface_, surface_, context_), "eglMakeCurrent");
  }

  EGLDisplay display() const { return display_; }
  EGLContext context() const { return context_; }
  EGLint major() const { return major_; }
  EGLint minor() const { return minor_; }

 private:
  static EGLDisplay device_display() {
    const auto query = reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
    const auto get = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if (!query || !get) return EGL_NO_DISPLAY;
    std::array<EGLDeviceEXT, 8> devices{};
    EGLint count = 0;
    if (query(static_cast<EGLint>(devices.size()), devices.data(), &count) != EGL_TRUE) return EGL_NO_DISPLAY;
    for (EGLint i = 0; i < count; ++i) {
      const EGLDisplay d = get(EGL_PLATFORM_DEVICE_EXT, devices[static_cast<std::size_t>(i)], nullptr);
      if (d != EGL_NO_DISPLAY) return d;
    }
    return EGL_NO_DISPLAY;
  }

  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLSurface surface_ = EGL_NO_SURFACE;
  EGLContext context_ = EGL_NO_CONTEXT;
  EGLint major_ = 0;
  EGLint minor_ = 0;
};

void close_fds(std::array<int, 4>& fds) {
  for (int& fd : fds) {
    if (fd >= 0) close(fd);
    fd = -1;
  }
}

struct ExportMetadata {
  uint32_t fourcc = 0;
  uint32_t planes = 0;
  uint32_t width = 2;
  uint32_t height = 2;
  uint32_t stride = 0;
  uint32_t offset = 0;
  uint64_t modifier = 0;
};

constexpr std::array<unsigned char, 16> kProbePixels = {3, 17, 91, 0, 42, 201, 7, 63,
                                                          128, 4, 222, 127, 255, 99, 1, 254};

bool recv_export(int socket_fd, ExportMetadata& metadata, int& dma_fd, int& fence_fd) {
  std::array<unsigned char, CMSG_SPACE(sizeof(int) * 2)> control{};
  iovec iov{.iov_base = &metadata, .iov_len = sizeof(metadata)};
  msghdr message{};
  message.msg_iov = &iov;
  message.msg_iovlen = 1;
  message.msg_control = control.data();
  message.msg_controllen = control.size();
  const ssize_t received = recvmsg(socket_fd, &message, MSG_CMSG_CLOEXEC);
  bool valid = received == static_cast<ssize_t>(sizeof(metadata)) && (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) == 0;
  int received_fds = 0;
  for (cmsghdr* cmsg = CMSG_FIRSTHDR(&message); cmsg; cmsg = CMSG_NXTHDR(&message, cmsg)) {
    if (cmsg->cmsg_type != SCM_RIGHTS || cmsg->cmsg_len < CMSG_LEN(0)) {
      valid = false;
      continue;
    }
    if (cmsg->cmsg_level != SOL_SOCKET) valid = false;
    const std::size_t bytes = cmsg->cmsg_len - CMSG_LEN(0);
    if (bytes % sizeof(int) != 0) {
      valid = false;
      continue;
    }
    const std::size_t count = bytes / sizeof(int);
    const auto* values = reinterpret_cast<const int*>(CMSG_DATA(cmsg));
    for (std::size_t i = 0; i < count; ++i) {
      if (received_fds == 0) dma_fd = values[i];
      else if (received_fds == 1) fence_fd = values[i];
      else close(values[i]);
      ++received_fds;
    }
  }
  return valid && received_fds == 2 && dma_fd >= 0 && fence_fd >= 0;
}

int consumer_main(int socket_fd) {
  ExportMetadata metadata;
  int dma_fd = -1;
  int fence_fd = -1;
  if (!recv_export(socket_fd, metadata, dma_fd, fence_fd)) {
    std::cerr << "FAIL consumer SCM_RIGHTS metadata\n";
    if (dma_fd >= 0) close(dma_fd);
    if (fence_fd >= 0) close(fence_fd);
    close(socket_fd);
    return EXIT_FAILURE;
  }
  close(socket_fd);
  pollfd fence_poll{.fd = fence_fd, .events = POLLIN, .revents = 0};
  const int fence_ready = poll(&fence_poll, 1, 5000);
  close(fence_fd);
  fence_fd = -1;
  if (fence_ready != 1 || (fence_poll.revents & POLLIN) == 0) {
    std::cerr << "FAIL consumer native fence timeout or error\n";
    close(dma_fd);
    return EXIT_FAILURE;
  }
  if (metadata.planes != 1 || metadata.width != 2 || metadata.height != 2 ||
      metadata.fourcc != 0x34324241U || metadata.stride < 8 ||
      metadata.stride > 0x7fffffffU || metadata.offset > 0x7fffffffU) {
    std::cerr << "FAIL consumer descriptor validation\n";
    close(dma_fd);
    return EXIT_FAILURE;
  }

  EglScope egl;
  if (!egl.create()) {
    close(dma_fd);
    return EXIT_FAILURE;
  }
  const char* extensions = eglQueryString(egl.display(), EGL_EXTENSIONS);
  const std::string extension_string = extensions ? extensions : "";
  if (extension_string.find("EGL_EXT_image_dma_buf_import") == std::string::npos) {
    std::cerr << "FAIL consumer EGL_EXT_image_dma_buf_import unavailable\n";
    close(dma_fd);
    return EXIT_FAILURE;
  }

  const auto create_image = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
  using ImageTargetFn = void (*)(GLenum, void*);
  const auto image_target = reinterpret_cast<ImageTargetFn>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
  if (!create_image || !image_target) {
    std::cerr << "FAIL consumer EGL image import entry points unavailable\n";
    close(dma_fd);
    return EXIT_FAILURE;
  }
  const EGLint modifier_lo = static_cast<EGLint>(metadata.modifier & 0xffffffffULL);
  const EGLint modifier_hi = static_cast<EGLint>(metadata.modifier >> 32U);
  const EGLint attrs[] = {EGL_WIDTH, static_cast<EGLint>(metadata.width), EGL_HEIGHT, static_cast<EGLint>(metadata.height),
                          EGL_LINUX_DRM_FOURCC_EXT, static_cast<EGLint>(metadata.fourcc), EGL_DMA_BUF_PLANE0_FD_EXT, dma_fd,
                          EGL_DMA_BUF_PLANE0_OFFSET_EXT, static_cast<EGLint>(metadata.offset), EGL_DMA_BUF_PLANE0_PITCH_EXT,
                          static_cast<EGLint>(metadata.stride), EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, modifier_lo,
                          EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, modifier_hi, EGL_NONE};
  EGLImageKHR image = create_image(egl.display(), EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr, attrs);
  if (image == EGL_NO_IMAGE_KHR) {
    std::cerr << "FAIL consumer eglCreateImageKHR(DMA-BUF): " << egl_error(eglGetError()) << '\n';
    close(dma_fd);
    return EXIT_FAILURE;
  }

  GLuint texture = 0;
  GLuint framebuffer = 0;
  glGenTextures(1, &texture);
  glBindTexture(GL_TEXTURE_2D, texture);
  image_target(GL_TEXTURE_2D, image);
  glGenFramebuffers(1, &framebuffer);
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
  bool ok = gl_ok("consumer EGLImage texture") && glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  std::array<unsigned char, 16> observed{};
  if (!ok) {
    std::cerr << "FAIL consumer framebuffer incomplete\n";
  } else {
    glReadPixels(0, 0, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE, observed.data());
    ok = gl_ok("consumer DMA-BUF readback") && observed == kProbePixels;
    if (!ok) std::cerr << "FAIL consumer exact RGBA/alpha comparison\n";
  }
  glDeleteFramebuffers(1, &framebuffer);
  glDeleteTextures(1, &texture);
  eglDestroyImage(egl.display(), image);
  close(dma_fd);
  if (ok) std::cout << "PASS consumer EGL DMA-BUF import/readback exact RGBA (including alpha)\n";
  return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}

bool send_export(int socket_fd, const ExportMetadata& metadata, int dma_fd, int fence_fd) {
  iovec iov{.iov_base = const_cast<ExportMetadata*>(&metadata), .iov_len = sizeof(metadata)};
  std::array<unsigned char, CMSG_SPACE(sizeof(int) * 2)> control{};
  msghdr message{};
  message.msg_iov = &iov;
  message.msg_iovlen = 1;
  message.msg_control = control.data();
  message.msg_controllen = control.size();
  cmsghdr* cmsg = CMSG_FIRSTHDR(&message);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(sizeof(int) * 2);
  const int fds[2] = {dma_fd, fence_fd};
  std::memcpy(CMSG_DATA(cmsg), fds, sizeof(fds));
  return sendmsg(socket_fd, &message, MSG_NOSIGNAL) == static_cast<ssize_t>(sizeof(metadata));
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 3 && std::string(argv[1]) == "--consumer") {
    char* end = nullptr;
    const long socket_fd = std::strtol(argv[2], &end, 10);
    if (!end || *end != '\0' || socket_fd < 0 || socket_fd > INT_MAX) return EXIT_FAILURE;
    return consumer_main(static_cast<int>(socket_fd));
  }
  EglScope egl;
  if (!egl.create()) return EXIT_FAILURE;

  const auto* vendor = reinterpret_cast<const char*>(glGetString(GL_VENDOR));
  const auto* renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
  const char* egl_extensions = eglQueryString(egl.display(), EGL_EXTENSIONS);
  const std::string extensions = egl_extensions ? egl_extensions : "";
  const bool has_image = extensions.find("EGL_KHR_image_base") != std::string::npos;
  const bool has_export = extensions.find("EGL_MESA_image_dma_buf_export") != std::string::npos;
  const bool has_fence = extensions.find("EGL_ANDROID_native_fence_sync") != std::string::npos;
  std::cout << "EGL " << egl.major() << '.' << egl.minor() << "; GL vendor=" << (vendor ? vendor : "unknown")
            << "; renderer=" << (renderer ? renderer : "unknown") << '\n';
  if (!has_image || !has_export || !has_fence) {
    std::cerr << "FAIL required EGL extensions: KHR_image_base=" << (has_image ? "yes" : "no")
              << " MESA_image_dma_buf_export=" << (has_export ? "yes" : "no")
              << " ANDROID_native_fence_sync=" << (has_fence ? "yes" : "no") << '\n';
    return EXIT_FAILURE;
  }

  GLuint texture = 0;
  GLuint framebuffer = 0;
  EGLImageKHR image = EGL_NO_IMAGE_KHR;
  std::array<int, 4> fds = {-1, -1, -1, -1};
  const auto cleanup = [&] {
    close_fds(fds);
    if (image != EGL_NO_IMAGE_KHR) eglDestroyImage(egl.display(), image);
    if (framebuffer) glDeleteFramebuffers(1, &framebuffer);
    if (texture) glDeleteTextures(1, &texture);
  };

  glGenTextures(1, &texture);
  glBindTexture(GL_TEXTURE_2D, texture);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, kProbePixels.data());
  glGenFramebuffers(1, &framebuffer);
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
  if (!gl_ok("create RGBA texture/FBO") || glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    std::cerr << "FAIL framebuffer incomplete\n";
    cleanup();
    return EXIT_FAILURE;
  }
  const auto create_sync = reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(eglGetProcAddress("eglCreateSyncKHR"));
  const auto destroy_sync = reinterpret_cast<PFNEGLDESTROYSYNCKHRPROC>(eglGetProcAddress("eglDestroySyncKHR"));
  const auto dup_fence = reinterpret_cast<PFNEGLDUPNATIVEFENCEFDANDROIDPROC>(eglGetProcAddress("eglDupNativeFenceFDANDROID"));
  if (!create_sync || !destroy_sync || !dup_fence) {
    std::cerr << "FAIL EGL native fence entry points unavailable\n";
    cleanup();
    return EXIT_FAILURE;
  }
  constexpr EGLint fence_attributes[] = {EGL_NONE};
  EGLSyncKHR sync = create_sync(egl.display(), EGL_SYNC_NATIVE_FENCE_ANDROID, fence_attributes);
  if (sync == EGL_NO_SYNC_KHR) {
    std::cerr << "FAIL eglCreateSyncKHR(native fence): " << egl_error(eglGetError()) << '\n';
    cleanup();
    return EXIT_FAILURE;
  }
  glFlush();
  const int fence_fd = dup_fence(egl.display(), sync);
  destroy_sync(egl.display(), sync);
  if (fence_fd < 0) {
    std::cerr << "FAIL eglDupNativeFenceFDANDROID\n";
    cleanup();
    return EXIT_FAILURE;
  }

  const auto create_image = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
  if (!create_image) {
    std::cerr << "FAIL EGL image entry points unavailable\n";
    close(fence_fd);
    cleanup();
    return EXIT_FAILURE;
  }
  constexpr EGLint image_attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
  image = create_image(egl.display(), egl.context(), EGL_GL_TEXTURE_2D_KHR,
                       reinterpret_cast<EGLClientBuffer>(static_cast<uintptr_t>(texture)), image_attrs);
  if (image == EGL_NO_IMAGE_KHR) {
    std::cerr << "FAIL eglCreateImageKHR: " << egl_error(eglGetError()) << '\n';
    close(fence_fd);
    cleanup();
    return EXIT_FAILURE;
  }

  auto query = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC>(eglGetProcAddress("eglExportDMABUFImageQueryMESA"));
  auto export_image = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEMESAPROC>(eglGetProcAddress("eglExportDMABUFImageMESA"));
  if (!query || !export_image) {
    std::cerr << "FAIL DMA-BUF export entry points unavailable\n";
    close(fence_fd);
    cleanup();
    return EXIT_FAILURE;
  }
  int fourcc = 0;
  int planes = 0;
  std::array<EGLuint64KHR, 4> modifiers{};
  if (!egl_ok(query(egl.display(), image, &fourcc, &planes, modifiers.data()), "eglExportDMABUFImageQueryMESA")) {
    close(fence_fd);
    cleanup();
    return EXIT_FAILURE;
  }
  std::array<EGLint, 4> strides{};
  std::array<EGLint, 4> offsets{};
  if (!egl_ok(export_image(egl.display(), image, fds.data(), strides.data(), offsets.data()), "eglExportDMABUFImageMESA")) {
    close(fence_fd);
    cleanup();
    return EXIT_FAILURE;
  }
  if (planes < 1 || planes > 4 || fds[0] < 0 || strides[0] <= 0) {
    std::cerr << "FAIL exported descriptor invalid: planes=" << planes << " fd0=" << fds[0]
              << " stride0=" << strides[0] << '\n';
    close(fence_fd);
    cleanup();
    return EXIT_FAILURE;
  }

  int sockets[2] = {-1, -1};
  if (fcntl(fence_fd, F_SETFD, FD_CLOEXEC) < 0) {
    close(fence_fd);
    cleanup();
    return EXIT_FAILURE;
  }
  for (const int fd : fds) {
    if (fd >= 0 && fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
      std::cerr << "FAIL exported fd close-on-exec\n";
      close(fence_fd);
      cleanup();
      return EXIT_FAILURE;
    }
  }
  if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sockets) != 0) {
    std::cerr << "FAIL socketpair for cross-process import\n";
    close(fence_fd);
    cleanup();
    return EXIT_FAILURE;
  }
  char socket_arg[32]{};
  std::snprintf(socket_arg, sizeof(socket_arg), "%d", sockets[1]);
  const pid_t child = fork();
  if (child < 0) {
    std::cerr << "FAIL fork for cross-process import\n";
    close(fence_fd);
    close(sockets[0]);
    close(sockets[1]);
    cleanup();
    return EXIT_FAILURE;
  }
  if (child == 0) {
    close(sockets[0]);
    execl(argv[0], argv[0], "--consumer", socket_arg, static_cast<char*>(nullptr));
    _exit(127);
  }
  close(sockets[1]);
  ExportMetadata metadata{.fourcc = static_cast<uint32_t>(fourcc),
                          .planes = static_cast<uint32_t>(planes),
                          .width = 2,
                          .height = 2,
                          .stride = static_cast<uint32_t>(strides[0]),
                          .offset = static_cast<uint32_t>(offsets[0]),
                          .modifier = modifiers[0]};
  if (!send_export(sockets[0], metadata, fds[0], fence_fd)) {
    std::cerr << "FAIL parent SCM_RIGHTS send\n";
    close(sockets[0]);
    close(fence_fd);
    kill(child, SIGKILL);
    waitpid(child, nullptr, 0);
    cleanup();
    return EXIT_FAILURE;
  }
  close(fence_fd);
  close(sockets[0]);
  int status = 0;
  bool exited = false;
  for (int elapsed_ms = 0; elapsed_ms < 5000; elapsed_ms += 10) {
    const pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) {
      exited = true;
      break;
    }
    if (result < 0) break;
    usleep(10000);
  }
  if (!exited) {
    std::cerr << "FAIL consumer timeout (5000 ms)\n";
    kill(child, SIGKILL);
    waitpid(child, &status, 0);
    cleanup();
    return EXIT_FAILURE;
  }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    std::cerr << "FAIL consumer process status=" << status << '\n';
    cleanup();
    return EXIT_FAILURE;
  }
  std::cout << "PASS EGL DMA-BUF export; fourcc=0x" << std::hex << static_cast<unsigned>(fourcc) << std::dec
            << "; planes=" << planes << "; modifier0=0x" << std::hex << modifiers[0] << std::dec
            << "; fd0=" << fds[0] << "; stride0=" << strides[0] << "; offset0=" << offsets[0] << '\n';
  cleanup();
  return EXIT_SUCCESS;
}

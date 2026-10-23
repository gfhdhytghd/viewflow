// Manual capability probe only.  It owns an offscreen EGL/GLES context and
// never attaches to a compositor, a window, or a capture/recording pipeline.
// The only host readback is the final verification copy from CUDA.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <cuda_gl_interop.h>
#include <cuda_runtime_api.h>

#include <array>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

[[nodiscard]] const char* egl_error_name(EGLint value) {
  switch (value) {
    case EGL_SUCCESS: return "EGL_SUCCESS";
    case EGL_NOT_INITIALIZED: return "EGL_NOT_INITIALIZED";
    case EGL_BAD_ACCESS: return "EGL_BAD_ACCESS";
    case EGL_BAD_ALLOC: return "EGL_BAD_ALLOC";
    case EGL_BAD_ATTRIBUTE: return "EGL_BAD_ATTRIBUTE";
    case EGL_BAD_CONTEXT: return "EGL_BAD_CONTEXT";
    case EGL_BAD_CONFIG: return "EGL_BAD_CONFIG";
    case EGL_BAD_CURRENT_SURFACE: return "EGL_BAD_CURRENT_SURFACE";
    case EGL_BAD_DISPLAY: return "EGL_BAD_DISPLAY";
    case EGL_BAD_MATCH: return "EGL_BAD_MATCH";
    case EGL_BAD_NATIVE_PIXMAP: return "EGL_BAD_NATIVE_PIXMAP";
    case EGL_BAD_NATIVE_WINDOW: return "EGL_BAD_NATIVE_WINDOW";
    case EGL_BAD_PARAMETER: return "EGL_BAD_PARAMETER";
    case EGL_BAD_SURFACE: return "EGL_BAD_SURFACE";
    default: return "unknown EGL error";
  }
}

[[nodiscard]] bool egl_ok(EGLBoolean value, const char* operation) {
  if (value == EGL_TRUE) return true;
  std::cerr << "FAIL " << operation << ": " << egl_error_name(eglGetError()) << '\n';
  return false;
}

[[nodiscard]] bool cuda_ok(cudaError_t value, const char* operation) {
  if (value == cudaSuccess) return true;
  std::cerr << "FAIL " << operation << ": " << cudaGetErrorString(value) << '\n';
  return false;
}

[[nodiscard]] bool gl_ok(const char* operation) {
  const GLenum value = glGetError();
  if (value == GL_NO_ERROR) return true;
  std::cerr << "FAIL " << operation << ": GL error 0x" << std::hex << value << std::dec << '\n';
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

  [[nodiscard]] bool create() {
    display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display_ == EGL_NO_DISPLAY || eglInitialize(display_, &major_, &minor_) != EGL_TRUE) {
      const EGLint default_error = eglGetError();
      display_ = create_device_display();
      if (display_ == EGL_NO_DISPLAY || eglInitialize(display_, &major_, &minor_) != EGL_TRUE) {
        const EGLint device_error = eglGetError();
        std::cerr << "FAIL eglInitialize(default=" << egl_error_name(default_error)
                  << ", platform-device=" << egl_error_name(device_error) << ")\n";
        return false;
      }
    }
    if (!egl_ok(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI(EGL_OPENGL_ES_API)")) return false;
    constexpr EGLint config_attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE,
                                             EGL_OPENGL_ES3_BIT_KHR, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                                             EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
    EGLConfig config = nullptr;
    EGLint count = 0;
    if (!egl_ok(eglChooseConfig(display_, config_attributes, &config, 1, &count), "eglChooseConfig") || count != 1) {
      std::cerr << "FAIL eglChooseConfig: no RGBA GLES3 pbuffer config\n";
      return false;
    }
    constexpr EGLint pbuffer_attributes[] = {EGL_WIDTH, 2, EGL_HEIGHT, 2, EGL_NONE};
    surface_ = eglCreatePbufferSurface(display_, config, pbuffer_attributes);
    if (surface_ == EGL_NO_SURFACE) {
      std::cerr << "FAIL eglCreatePbufferSurface: " << egl_error_name(eglGetError()) << '\n';
      return false;
    }
    constexpr EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    context_ = eglCreateContext(display_, config, EGL_NO_CONTEXT, context_attributes);
    if (context_ == EGL_NO_CONTEXT) {
      std::cerr << "FAIL eglCreateContext: " << egl_error_name(eglGetError()) << '\n';
      return false;
    }
    return egl_ok(eglMakeCurrent(display_, surface_, surface_, context_), "eglMakeCurrent");
  }

  [[nodiscard]] EGLint major() const { return major_; }
  [[nodiscard]] EGLint minor() const { return minor_; }

 private:
  [[nodiscard]] static EGLDisplay create_device_display() {
    const auto query_devices = reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
    const auto get_platform_display =
        reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if (query_devices == nullptr || get_platform_display == nullptr) return EGL_NO_DISPLAY;
    std::array<EGLDeviceEXT, 8> devices{};
    EGLint count = 0;
    if (query_devices(static_cast<EGLint>(devices.size()), devices.data(), &count) != EGL_TRUE || count < 1) return EGL_NO_DISPLAY;
    for (EGLint index = 0; index < count; ++index) {
      if (const EGLDisplay display = get_platform_display(EGL_PLATFORM_DEVICE_EXT, devices[static_cast<std::size_t>(index)], nullptr);
          display != EGL_NO_DISPLAY) {
        return display;
      }
    }
    return EGL_NO_DISPLAY;
  }

  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLSurface surface_ = EGL_NO_SURFACE;
  EGLContext context_ = EGL_NO_CONTEXT;
  EGLint major_ = 0;
  EGLint minor_ = 0;
};

}  // namespace

int main() {
  EglScope egl;
  if (!egl.create()) {
    std::cerr << "This probe needs an EGL display capable of an independent GLES3 pbuffer context.\n";
    return EXIT_FAILURE;
  }

  const auto* vendor = reinterpret_cast<const char*>(glGetString(GL_VENDOR));
  const auto* renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
  if (vendor == nullptr || renderer == nullptr) {
    std::cerr << "FAIL glGetString: no current GLES renderer\n";
    return EXIT_FAILURE;
  }

  int cuda_devices = 0;
  if (!cuda_ok(cudaGetDeviceCount(&cuda_devices), "cudaGetDeviceCount") || cuda_devices < 1) {
    std::cerr << "FAIL CUDA has no usable device for EGL/OpenGL interop\n";
    return EXIT_FAILURE;
  }

  // Each byte is distinct, including non-opaque alpha.  glTexImage2D uploads
  // it directly to the owned GL texture; no GL readback or PBO is used.
  constexpr std::array<unsigned char, 16> expected = {
      3, 17, 91, 0, 42, 201, 7, 63, 128, 4, 222, 127, 255, 99, 1, 254};
  GLuint texture = 0;
  glGenTextures(1, &texture);
  glBindTexture(GL_TEXTURE_2D, texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, expected.data());
  if (!gl_ok("create RGBA texture")) return EXIT_FAILURE;
  glFinish();

  cudaGraphicsResource_t resource = nullptr;
  bool mapped = false;
  const auto cleanup = [&] {
    if (mapped) cudaGraphicsUnmapResources(1, &resource, nullptr);
    if (resource != nullptr) cudaGraphicsUnregisterResource(resource);
    if (texture != 0) glDeleteTextures(1, &texture);
  };

  if (!cuda_ok(cudaGraphicsGLRegisterImage(&resource, texture, GL_TEXTURE_2D, cudaGraphicsRegisterFlagsReadOnly),
               "cudaGraphicsGLRegisterImage")) {
    std::cerr << "The current EGL GL renderer and CUDA device do not expose compatible GL image interop.\n";
    cleanup();
    return EXIT_FAILURE;
  }
  if (!cuda_ok(cudaGraphicsMapResources(1, &resource, nullptr), "cudaGraphicsMapResources")) {
    cleanup();
    return EXIT_FAILURE;
  }
  mapped = true;
  cudaArray_t array = nullptr;
  if (!cuda_ok(cudaGraphicsSubResourceGetMappedArray(&array, resource, 0, 0),
               "cudaGraphicsSubResourceGetMappedArray")) {
    cleanup();
    return EXIT_FAILURE;
  }

  // Test-only verification readback: CUDA copies the mapped GL texture into
  // host memory after the GPU interop step. Production code must instead keep
  // this CUDA image/device data on the GPU for its next stage.
  std::array<unsigned char, expected.size()> observed{};
  if (!cuda_ok(cudaMemcpy2DFromArray(observed.data(), 2 * 4, array, 0, 0, 2 * 4, 2,
                                     cudaMemcpyDeviceToHost),
               "cudaMemcpy2DFromArray(test-only verification)")) {
    cleanup();
    return EXIT_FAILURE;
  }
  if (!cuda_ok(cudaGraphicsUnmapResources(1, &resource, nullptr), "cudaGraphicsUnmapResources")) {
    cleanup();
    return EXIT_FAILURE;
  }
  mapped = false;
  if (!cuda_ok(cudaGraphicsUnregisterResource(resource), "cudaGraphicsUnregisterResource")) {
    resource = nullptr;
    cleanup();
    return EXIT_FAILURE;
  }
  resource = nullptr;
  glDeleteTextures(1, &texture);
  texture = 0;

  if (observed != expected) {
    std::cerr << "FAIL exact RGBA/alpha comparison after CUDA mapping\n";
    return EXIT_FAILURE;
  }
  std::cout << "PASS EGL " << egl.major() << '.' << egl.minor() << "; GL vendor=" << vendor
            << "; renderer=" << renderer << "; CUDA devices=" << cuda_devices
            << "; exact 2x2 RGBA (including alpha) mapped GL texture -> CUDA array.\n";
  return EXIT_SUCCESS;
}

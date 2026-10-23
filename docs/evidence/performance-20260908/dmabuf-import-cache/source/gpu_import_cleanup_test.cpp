#include "gpu_import_cleanup.hpp"
#include <cstdlib>
using viewflow::gpu::cleanupImportedImage;
void require(bool value) { if (!value) std::abort(); }
int main() {
  for (unsigned present = 0; present < 8; ++present) {
    for (unsigned failures = 0; failures < 8; ++failures) {
      for (bool report : {false, true}) {
        std::string calls, error = "original failure", expectedError = error;
        const bool resource = present & 1, mapped = present & 2, image = present & 4;
        const bool ok = cleanupImportedImage(resource, mapped, image,
            [&] { calls += 'u'; return !(failures & 1); },
            [&] { calls += 'r'; return !(failures & 2); },
            [&] { calls += 'd'; return !(failures & 4); }, report ? &error : nullptr);
        std::string expectedCalls;
        unsigned applicable = 0;
        if (resource && mapped) { expectedCalls += 'u'; applicable |= 1; }
        if (resource) { expectedCalls += 'r'; applicable |= 2; }
        if (image) { expectedCalls += 'd'; applicable |= 4; }
        if (report && (applicable & failures & 1)) expectedError += "; cleanup CUDA unmap failed";
        if (report && (applicable & failures & 2)) expectedError += "; cleanup CUDA unregister failed";
        if (report && (applicable & failures & 4)) expectedError += "; cleanup EGL image destruction failed";
        require(calls == expectedCalls);
        require(ok == !(applicable & failures));
        require(error == expectedError);
      }
    }
  }
  std::string empty;
  require(!cleanupImportedImage(false, false, true, [] { return true; },
      [] { return true; }, [] { return false; }, &empty));
  require(empty == "cleanup EGL image destruction failed");
}

#pragma once
#include <string>

namespace viewflow::gpu {
// Call every applicable cleanup operation, even after an earlier failure.
// Callers must poison the encoder and discard output when this returns false.
template <typename Unmap, typename Unregister, typename Destroy>
bool cleanupImportedImage(bool resource, bool mapped, bool image,
                          Unmap unmap, Unregister unregister, Destroy destroy,
                          std::string *error) {
  bool cleaned = true;
  const auto check = [&](bool success, const char *operation) {
    if (success) return;
    cleaned = false;
    if (error) {
      if (!error->empty()) error->append("; ");
      error->append(operation);
    }
  };
  if (resource && mapped) check(unmap(), "cleanup CUDA unmap failed");
  if (resource) check(unregister(), "cleanup CUDA unregister failed");
  if (image) check(destroy(), "cleanup EGL image destruction failed");
  return cleaned;
}
}

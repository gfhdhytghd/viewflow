// Nested-test fixture only. NVIDIA GBM rejects the headless fallback's implicit
// modifiers when no DRM backend can open a seat. Borrow the nested Wayland
// backend's advertised formats. No ownership or lifecycle methods are changed.
// Build against the same Aquamarine headers as the nested compositor, then pass
// --headless-format-preload to plugin-unload-nested.py. Never install this .so.
#include <aquamarine/backend/Headless.hpp>

std::vector<Aquamarine::SDRMFormat> Aquamarine::CHeadlessBackend::getRenderFormats() {
    return backend->getPrimaryRenderFormats();
}

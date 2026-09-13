#pragma once
#include <cstdlib>
#include <cstring>

namespace vf_diag {
// Per-frame timing and fixture selection are opt-in. Ordinary remote capture
// keeps the full configured rectangle and avoids per-frame diagnostic I/O.
inline bool enabled() {
    static const bool value = [] {
        const char* setting = std::getenv("VIEWFLOW_REVERSE_DIAGNOSTICS");
        return setting && std::strcmp(setting, "1") == 0;
    }();
    return value;
}
}

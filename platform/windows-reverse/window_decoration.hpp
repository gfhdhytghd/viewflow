#pragma once
#include <algorithm>
namespace viewflow::reverse {
// Coordinates stay in the source's physical pixels. DWM corner preference is
// deliberately not a radius: actual WGC alpha is the per-window silhouette.
inline unsigned shadow_padding(unsigned dpi, bool maximized, bool composition) {
    return maximized || !composition ? 0u : std::clamp((108u * std::clamp(dpi, 96u, 384u) + 48u) / 96u, 108u, 432u);
}
}

#pragma once
#include <string_view>
namespace viewflow::reverse {
// Platform comes from the locally generated paired profile, not geometry or
// window decoration. Legacy/unknown standalone sources retain wheel fallback.
inline constexpr bool raw_touchpad_supported(bool mac, bool hid_ready, std::string_view source) {
    if (source == "linux") return false;
    if (mac) return source != "windows" && hid_ready; // Preserve the existing negotiated macOS path.
    return source == "windows";
}
}

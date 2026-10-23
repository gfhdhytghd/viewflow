#pragma once

#include <cstdint>
#include <limits>

namespace viewflow::windows_capture {

// This contract deliberately has no Windows SDK dependency so its bounds and
// failure behavior can be tested on non-Windows builders.
enum class CaptureFailure : std::uint8_t {
    none,
    invalid_window,
    platform_unsupported,
    access_denied_or_protected,
    d3d_device_unavailable,
    setup_failed,
    invalid_frame_extent,
    target_closed,
    consumer_failed,
    runtime_failed,
};

// HRESULT values used here are fixed ABI values. Keeping them as u32 avoids
// making the portable contract pull in Windows headers.
inline constexpr std::uint32_t hresult_access_denied = 0x80070005u;
inline constexpr std::uint32_t hresult_not_implemented = 0x80004001u;
inline constexpr std::uint32_t hresult_not_supported = 0x80070032u;
inline constexpr std::uint32_t hresult_module_not_found = 0x8007007eu;

constexpr CaptureFailure classifyStartupHresult(std::uint32_t hresult) noexcept {
    switch (hresult) {
    case hresult_access_denied:
        // Do not substitute desktop/GDI capture. Access denial can be a
        // protected-content or policy boundary and needs an explicit result.
        return CaptureFailure::access_denied_or_protected;
    case hresult_not_implemented:
    case hresult_not_supported:
    case hresult_module_not_found:
        return CaptureFailure::platform_unsupported;
    default:
        return CaptureFailure::setup_failed;
    }
}

struct CaptureLimits {
    std::uint32_t max_width = 8192;
    std::uint32_t max_height = 8192;
    std::uint64_t max_pixels = 16ull * 1024ull * 1024ull;
};

constexpr bool validContentExtent(std::uint32_t width, std::uint32_t height,
                                  CaptureLimits limits = {}) noexcept {
    return width != 0 && height != 0 && width <= limits.max_width &&
           height <= limits.max_height &&
           static_cast<std::uint64_t>(width) * height <= limits.max_pixels;
}

struct NativeWindowBounds {
    std::int32_t left = 0;
    std::int32_t top = 0;
    std::int32_t right = 0;
    std::int32_t bottom = 0;
    // true when read with DWMWA_EXTENDED_FRAME_BOUNDS; otherwise it is the
    // unmodified GetWindowRect fallback. Consumers must only combine these
    // coordinates with input geometry from the same DPI-awareness context.
    bool is_extended_frame_bounds = false;

    friend constexpr bool operator==(NativeWindowBounds,
                                     NativeWindowBounds) noexcept = default;
};

struct CaptureGeometry {
    std::uint64_t epoch = 0;
    std::uint32_t content_width = 0;
    std::uint32_t content_height = 0;
    NativeWindowBounds source_bounds{};

    friend constexpr bool operator==(CaptureGeometry,
                                     CaptureGeometry) noexcept = default;
};

constexpr std::uint64_t nextGeometryEpoch(std::uint64_t current,
                                           bool changed) noexcept {
    if (!changed) return current;
    if (current == std::numeric_limits<std::uint64_t>::max()) return 0;
    return current + 1;
}

// WGC is requested as B8G8R8A8 UNORM. The API does not give this backend a
// trustworthy straight-vs-premultiplied alpha declaration, so alpha bytes are
// passed through untouched and no transparent decoration is inferred from them.
enum class CapturedAlpha : std::uint8_t {
    bgra8_alpha_preserved_unknown_mode,
};

// SystemRelativeTime is a signed WinRT TimeSpan. Its raw C++/WinRT count is
// expressed in 100 ns units; a negative value cannot identify a valid QPC
// render instant for this source and is rejected before delivery.
constexpr bool validSystemRelativeTime100ns(std::int64_t value) noexcept {
    return value >= 0;
}

} // namespace viewflow::windows_capture

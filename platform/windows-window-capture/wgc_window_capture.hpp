#pragma once

#include "wgc_capture_contract.hpp"

#include <d3d11.h>
#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>

namespace viewflow::windows_capture {

// The surface is borrowed and is valid only for the dynamic extent of
// FrameCallbacks::on_frame. Copy/import it before returning if it is needed
// after the callback; do not retain the WGC surface or Direct3D11CaptureFrame.
struct CapturedFrame {
    ID3D11Texture2D* surface = nullptr;
    CaptureGeometry geometry{};
    // This is Direct3D11CaptureFrame::SystemRelativeTime().Duration, in 100 ns
    // QPC-relative units. It is not a wall clock and is not restamped here.
    std::int64_t system_relative_time_100ns = 0;
    CapturedAlpha alpha = CapturedAlpha::bgra8_alpha_preserved_unknown_mode;
};

struct FrameCallbacks {
    std::function<void(const CaptureGeometry&)> on_geometry;
    std::function<void(const CapturedFrame&)> on_frame;
    std::function<void(CaptureFailure, std::uint32_t native_hresult)>
        on_terminal;
};

struct StartResult {
    CaptureFailure failure = CaptureFailure::none;
    std::uint32_t native_hresult = 0;

    [[nodiscard]] constexpr explicit operator bool() const noexcept {
        return failure == CaptureFailure::none;
    }
};

// A window-only Windows.Graphics.Capture source. It has no monitor, desktop,
// GDI, PrintWindow, or Desktop Duplication fallback. Start/stop may be called
// from any initialized WinRT apartment, but stop must not be called recursively
// from one of this object's callbacks; signal the owning loop instead.
class WindowCapture final {
public:
    WindowCapture();
    ~WindowCapture();
    WindowCapture(const WindowCapture&) = delete;
    WindowCapture& operator=(const WindowCapture&) = delete;

    [[nodiscard]] StartResult start(HWND window, CaptureLimits limits,
                                    FrameCallbacks callbacks,
                                    ID3D11Device* shared_device = nullptr);
    void stop() noexcept;
    [[nodiscard]] bool running() const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace viewflow::windows_capture

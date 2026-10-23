// SPDX-License-Identifier: GPL-3.0-only
// Derived from HyprCapture caa7657c5f13b5828f984357f7686c98375f2949; see ../NOTICE.
#pragma once
#include "window_gpu_sender.hpp"
#include "window_gpu_wire.hpp"
#include <optional>
#include <memory>

namespace viewflow_capture {
// One cache per source allocation, owned and destroyed on the render thread.
// reset() MUST precede any texture storage redefinition, even if GL recycles
// the same numeric name. Busy/retired allocations must never be re-rendered.
class WindowGpuExportCache {
  public:
    WindowGpuExportCache();
    ~WindowGpuExportCache();
    WindowGpuExportCache(const WindowGpuExportCache&) = delete;
    WindowGpuExportCache& operator=(const WindowGpuExportCache&) = delete;
    void reset();
    std::optional<WindowGpuPacket> exportFrame(unsigned int framebuffer, gpuwire::Frame metadata);
    std::uint64_t imageBuilds() const;
    std::uint64_t capabilityQueries() const;
  private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

// Render-thread only, with the compositor's EGL context current. Does not
// read pixels or wait for the GPU. The caller owns and must keep the source
// framebuffer immutable until sender Ready, or retire it on sender failure.
// metadata crop/style/time must describe the completed render, not a later
// window state. Image layout fields are filled from the actual export.
std::optional<WindowGpuPacket> exportWindowGpuFrame(unsigned int framebuffer,
                                                   gpuwire::Frame metadata);
}

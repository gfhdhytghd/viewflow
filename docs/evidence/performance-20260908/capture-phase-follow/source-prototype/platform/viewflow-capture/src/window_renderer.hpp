// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
#include <memory>
#include <string>
namespace viewflow_capture {
class WindowRenderer {
 public:
    explicit WindowRenderer(std::string socket);
    ~WindowRenderer();
    WindowRenderer(const WindowRenderer&) = delete;
    WindowRenderer& operator=(const WindowRenderer&) = delete;
    // Returns false on revoked target/export failure. Busy does not redraw.
    // Geometry epochs are producer-owned and advance when exported coordinates
    // or the main-surface input mapping change, including popup expansion.
    bool capture(std::uint64_t window_address, std::uint64_t sequence);
    int notification_fd() const;
    void drain_notifications();
 private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}

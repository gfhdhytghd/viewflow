// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <memory>
#include <nlohmann/json_fwd.hpp>

namespace viewflow::hyprland {

// Owns at most eight explicitly enrolled, same-compositor windows. Requests
// only arrive through the checked private-file Lua entry point in main.cpp.
class DesktopWindowController {
  public:
    DesktopWindowController();
    ~DesktopWindowController();
    DesktopWindowController(const DesktopWindowController&) = delete;
    DesktopWindowController& operator=(const DesktopWindowController&) = delete;

    [[nodiscard]] nlohmann::json handle(const nlohmann::json& request);
    // Plugin teardown drops only weak, finite enrollments. It does not move a
    // window during unload; callers request an explicit checked restore.
    void shutdown() noexcept;

  private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace viewflow::hyprland

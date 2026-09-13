// SPDX-License-Identifier: GPL-3.0-only
#include "desktop_window_controller.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/random.h>
#include <time.h>
#include <utility>

namespace viewflow::hyprland {
namespace {
using Json = nlohmann::json;

constexpr std::size_t MAX_WINDOWS = 8;
constexpr std::uint64_t MAX_LIFETIME_NS = 30'000'000'000ULL;
constexpr double MAX_LOGICAL_COORDINATE = 1'000'000.0;

[[nodiscard]] Json failure(std::string message) {
  return {{"ok", false}, {"version", 1}, {"error", std::move(message)}};
}

[[nodiscard]] std::uint64_t monotonicNs() {
  timespec now{};
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 || now.tv_nsec < 0)
    throw std::runtime_error("monotonic clock unavailable");
  const auto seconds = static_cast<std::uint64_t>(now.tv_sec);
  if (seconds > (std::numeric_limits<std::uint64_t>::max() - 999'999'999ULL) / 1'000'000'000ULL)
    throw std::runtime_error("monotonic clock overflow");
  return seconds * 1'000'000'000ULL + static_cast<std::uint64_t>(now.tv_nsec);
}

[[nodiscard]] bool validId(std::string_view id) {
  return !id.empty() && id.size() <= 128 && std::all_of(id.begin(), id.end(), [](unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '-' || c == '_';
  });
}

[[nodiscard]] std::uint64_t parseAddress(const Json& value, const char* field, bool optional = false) {
  if (optional && value.is_null()) return 0;
  const auto text = value.get<std::string>();
  if (text.size() < 3 || text.size() > 18 || !text.starts_with("0x"))
    throw std::runtime_error(std::string("invalid ") + field);
  std::uint64_t parsed = 0;
  const auto result = std::from_chars(text.data() + 2, text.data() + text.size(), parsed, 16);
  if (result.ec != std::errc{} || result.ptr != text.data() + text.size() || parsed == 0)
    throw std::runtime_error(std::string("invalid ") + field);
  return parsed;
}

[[nodiscard]] std::string mintToken() {
  std::array<std::uint8_t, 24> bytes{};
  if (getrandom(bytes.data(), bytes.size(), GRND_NONBLOCK) != static_cast<ssize_t>(bytes.size()))
    throw std::runtime_error("opaque token unavailable");
  static constexpr char HEX[] = "0123456789abcdef";
  std::string token;
  token.reserve(bytes.size() * 2);
  for (const auto byte : bytes) {
    token.push_back(HEX[(byte >> 4U) & 0x0fU]);
    token.push_back(HEX[byte & 0x0fU]);
  }
  return token;
}

[[nodiscard]] bool succeeded(const Config::Actions::ActionResult& result) {
  return result.has_value();
}

} // namespace

struct DesktopWindowController::Impl {
  struct OwnedWindow {
    PHLWINDOWREF window;
    WP<CWLSurfaceResource> surface;
    PHLWORKSPACEREF original_workspace;
    std::uint64_t address = 0;
    std::uint64_t surface_address = 0;
    std::uint64_t stable_id = 0;
    pid_t pid = 0;
    Vector2D original_position{};
    bool original_floating = false;
    bool forced_floating = false;
    std::string token;
    std::uint64_t expires_at_ns = 0;
    std::uint64_t last_sequence = 0;
  };

  std::map<std::string, OwnedWindow, std::less<>> windows;

  void purgeExpired(std::uint64_t now) {
    std::erase_if(windows, [now](const auto& entry) {
      return entry.second.expires_at_ns <= now || entry.second.window.expired() ||
             entry.second.surface.expired();
    });
  }

  [[nodiscard]] OwnedWindow* checked(const Json& request, std::uint64_t now) {
    const auto id = request.at("localWindowId").get<std::string>();
    const auto token = request.at("token").get<std::string>();
    const auto found = windows.find(id);
    if (found == windows.end() || !validId(id) || token.size() != 48 || token != found->second.token)
      throw std::runtime_error("unknown or unauthorized local window");
    auto& owned = found->second;
    if (owned.expires_at_ns <= now) {
      windows.erase(found);
      throw std::runtime_error("desktop window control expired");
    }
    if (g_pSessionLockManager && g_pSessionLockManager->isSessionLocked())
      throw std::runtime_error("session locked");
    const auto window = owned.window.lock();
    const auto surface = owned.surface.lock();
    if (!window || !surface || !window->m_isMapped ||
        reinterpret_cast<std::uintptr_t>(window.get()) != owned.address ||
        window->m_stableID != owned.stable_id || window->getPID() != owned.pid ||
        reinterpret_cast<std::uintptr_t>(surface.get()) != owned.surface_address ||
        window->resource().get() != surface.get())
      throw std::runtime_error("enrolled window lifetime or identity changed");
    return &owned;
  }

  [[nodiscard]] bool checkedSequence(OwnedWindow& owned, const Json& request) const {
    const auto sequence = request.at("sequence").get<std::uint64_t>();
    if (sequence == 0 || sequence != owned.last_sequence + 1) return false;
    owned.last_sequence = sequence;
    return true;
  }

  [[nodiscard]] bool checkedDeadline(const OwnedWindow& owned, const Json& request,
                                     std::uint64_t now) const {
    const auto deadline = request.at("notAfterMonotonicNs").get<std::uint64_t>();
    return deadline > now && deadline <= owned.expires_at_ns;
  }

  [[nodiscard]] Json enroll(const Json& request, std::uint64_t now) {
    const auto id = request.at("localWindowId").get<std::string>();
    const auto address = parseAddress(request.at("windowAddress"), "windowAddress");
    const auto pid64 = request.at("pid").get<std::uint64_t>();
    const auto deadline = request.at("notAfterMonotonicNs").get<std::uint64_t>();
    const auto surface_address = request.contains("surfaceAddress")
        ? parseAddress(request.at("surfaceAddress"), "surfaceAddress", true) : 0;
    if (!validId(id) || windows.contains(id) || windows.size() >= MAX_WINDOWS ||
        pid64 == 0 || pid64 > static_cast<std::uint64_t>(std::numeric_limits<pid_t>::max()) ||
        deadline <= now || deadline - now > MAX_LIFETIME_NS)
      return failure("invalid desktop-window enrollment");
    if (g_pSessionLockManager && g_pSessionLockManager->isSessionLocked())
      return failure("session locked");

    for (const auto& window : Desktop::windowState()->windows()) {
      if (!window || reinterpret_cast<std::uintptr_t>(window.get()) != address ||
          !window->m_isMapped || window->getPID() != static_cast<pid_t>(pid64))
        continue;
      const auto surface = window->resource();
      if (!surface || (surface_address != 0 &&
                       reinterpret_cast<std::uintptr_t>(surface.get()) != surface_address))
        return failure("capture surface identity mismatch");
      OwnedWindow owned{};
      owned.window = window;
      owned.surface = surface;
      owned.original_workspace = window->m_workspace;
      owned.address = address;
      owned.surface_address = reinterpret_cast<std::uintptr_t>(surface.get());
      owned.stable_id = window->m_stableID;
      owned.pid = window->getPID();
      owned.original_position =
          window->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
      owned.original_floating = window->m_isFloating;
      owned.token = mintToken();
      owned.expires_at_ns = deadline;
      const auto token = owned.token;
      windows.emplace(id, std::move(owned));
      return {{"ok", true}, {"version", 1}, {"localWindowId", id},
              {"token", token}, {"expiresAtMonotonicNs", deadline},
              {"surfaceAddress", request.contains("surfaceAddress") ? request.at("surfaceAddress") : Json(nullptr)}};
    }
    return failure("window address and pid not found");
  }

  [[nodiscard]] Json move(const Json& request, std::uint64_t now) {
    auto* owned = checked(request, now);
    if (!checkedSequence(*owned, request)) return failure("desktop-window sequence rejected");
    if (!checkedDeadline(*owned, request, now)) return failure("desktop-window deadline rejected");
    const auto x = request.at("desiredFullCaptureX").get<double>();
    const auto y = request.at("desiredFullCaptureY").get<double>();
    if (!std::isfinite(x) || !std::isfinite(y) || std::abs(x) > MAX_LOGICAL_COORDINATE ||
        std::abs(y) > MAX_LOGICAL_COORDINATE)
      return failure("invalid full-capture coordinates");
    const auto window = owned->window.lock();
    if (!window) return failure("enrolled window destroyed");
    if (!window->m_isFloating) {
      if (!succeeded(Config::Actions::floatWindow(Config::Actions::TOGGLE_ACTION_ENABLE, window)))
        return failure("could not make owned window floating");
      owned->forced_floating = true;
    }
    // ConfigActions::move takes the window's base geometry. Viewflow's desired
    // coordinates name the complete capture bounding box, so preserve the
    // current base-to-full extents rather than assuming client decorations.
    const auto full = window->getFullWindowBoundingBox();
    const auto base = window->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const Vector2D target{ x + base.x - full.x, y + base.y - full.y };
    // Workspace assignment can reposition a floating target. Perform that
    // handoff before applying the requested global coordinates, including a
    // partly clipped window, so the layout algorithm cannot clamp the drag.
    const auto monitor = State::monitorState()->query().vec(Vector2D{x + full.w / 2.0, y + full.h / 2.0}).run();
    if (monitor && monitor->m_activeWorkspace) {
      const auto workspace = monitor->m_activeSpecialWorkspace ? monitor->m_activeSpecialWorkspace : monitor->m_activeWorkspace;
      if (window->m_workspace != workspace)
        window->layoutTarget()->assignToSpace(workspace->m_space);
    }
    const auto width = request.value("desiredFullCaptureWidth", 0.0);
    const auto height = request.value("desiredFullCaptureHeight", 0.0);
    if (!std::isfinite(width) || !std::isfinite(height) || width < 0 || height < 0 ||
        width > MAX_LOGICAL_COORDINATE || height > MAX_LOGICAL_COORDINATE || ((width == 0) != (height == 0)))
      return failure("invalid full-capture size");
    if (width > 0 && (std::abs(width - full.w) > 0.5 || std::abs(height - full.h) > 0.5)) {
      const auto size = window->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
      const Vector2D clientSize{width - (full.w - size.x), height - (full.h - size.y)};
      if (clientSize.x <= 0 || clientSize.y <= 0 ||
          !succeeded(Config::Actions::resize(clientSize, false, window)))
        return failure("Hyprland rejected owned window resize");
    }
    if (!succeeded(Config::Actions::move(target, false, window)))
      return failure("Hyprland rejected owned window move");
    // Successful ordered activity renews the idle enrollment watchdog. A long
    // physical drag must not expire at a fixed offset from its initial Begin.
    owned->expires_at_ns = std::max(owned->expires_at_ns, now + MAX_LIFETIME_NS);
    return {{"ok", true}, {"version", 1},
            {"localWindowId", request.at("localWindowId")},
            {"sequence", owned->last_sequence}, {"moved", true},
            {"expiresAtMonotonicNs", owned->expires_at_ns}};
  }

  [[nodiscard]] Json release(const Json& request, std::uint64_t now) {
    const auto id = request.at("localWindowId").get<std::string>();
    auto* owned = checked(request, now);
    if (!checkedSequence(*owned, request)) return failure("desktop-window sequence rejected");
    if (!checkedDeadline(*owned, request, now)) return failure("desktop-window deadline rejected");
    const bool restore = request.at("restore").get<bool>();
    if (!restore) {
      windows.erase(id);
      return {{"ok", true}, {"version", 1}, {"localWindowId", id}, {"released", true}, {"restored", false}};
    }
    const auto window = owned->window.lock();
    const auto workspace = owned->original_workspace.lock();
    if (!window || !workspace) return failure("original owned window or workspace vanished");
    // Restore only the exact weakly retained object after its stable identity,
    // PID, and surface have all been revalidated above.
    if (!succeeded(Config::Actions::moveToWorkspace(workspace, true, window)) ||
        !succeeded(Config::Actions::move(owned->original_position, false, window)) ||
        !succeeded(Config::Actions::floatWindow(
            owned->original_floating ? Config::Actions::TOGGLE_ACTION_ENABLE :
                                      Config::Actions::TOGGLE_ACTION_DISABLE,
            window)))
      return failure("owned window restore failed; enrollment retained");
    windows.erase(id);
    return {{"ok", true}, {"version", 1}, {"localWindowId", id}, {"released", true}, {"restored", true}};
  }
};

DesktopWindowController::DesktopWindowController() : m_impl(std::make_unique<Impl>()) {}
DesktopWindowController::~DesktopWindowController() = default;

Json DesktopWindowController::handle(const Json& request) {
  try {
    if (!request.is_object() || request.value("version", 0) != 1)
      return failure("desktop-window request version required");
    const auto now = monotonicNs();
    m_impl->purgeExpired(now);
    const auto operation = request.at("operation").get<std::string>();
    if (operation == "enroll") return m_impl->enroll(request, now);
    if (operation == "move") return m_impl->move(request, now);
    if (operation == "release") return m_impl->release(request, now);
    return failure("unsupported desktop-window operation");
  } catch (const std::exception& error) {
    return failure(error.what());
  }
}

void DesktopWindowController::shutdown() noexcept {
  // Do not risk moving an unrelated/reused object during teardown. Weak
  // ownership expires naturally and all requests have finite deadlines.
  m_impl->windows.clear();
}

} // namespace viewflow::hyprland

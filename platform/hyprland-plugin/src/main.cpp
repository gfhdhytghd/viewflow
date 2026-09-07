// SPDX-License-Identifier: GPL-3.0-only
#include "metadata_bridge.hpp"
#include "input_capture.hpp"
#include "desktop_window_controller.hpp"

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/plugins/HookSystem.hpp>
#include <nlohmann/json.hpp>

#include <memory>
#include <array>
#include <stdexcept>
#include <string>
#include <string_view>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
extern "C" {
#include <lua.h>
}

namespace {

HANDLE g_handle = nullptr;
std::unique_ptr<viewflow::hyprland::MetadataBridge> g_bridge;
std::unique_ptr<viewflow::hyprland::InputCapture> g_inputCapture;
std::unique_ptr<viewflow::hyprland::DesktopWindowController> g_desktopWindowController;
CFunctionHook* g_focusMotionHook = nullptr;
// This compositor convenience path bypasses cancellable mouse.move. Keep an
// already-owned remote pointer installed only under the session's exact guard.
void focusedMotionHook(void* inputManager) {
  if (g_inputCapture && g_inputCapture->suppressConvenienceMotion()) return;
  using Original = void (*)(void*);
  reinterpret_cast<Original>(g_focusMotionHook->m_original)(inputManager);
}

class PrivateRequestFile {
  public:
    explicit PrivateRequestFile(std::string_view path) {
      if (path.empty() || path.size() > 4096 || path.front() != '/' || path.find('\0') != std::string_view::npos)
        throw std::runtime_error("absolute private request path required");
      const std::string nativePath{path};
      m_fd = open(nativePath.c_str(), O_RDWR | O_NOFOLLOW | O_CLOEXEC);
      struct stat state{};
      if (m_fd < 0 || fstat(m_fd, &state) != 0 || !S_ISREG(state.st_mode) ||
          state.st_uid != getuid() || (state.st_mode & 0777) != 0600 || state.st_nlink != 1 ||
          state.st_size <= 0 || state.st_size > 4096) {
        if (m_fd >= 0) close(m_fd);
        m_fd = -1;
        throw std::runtime_error("owned mode-0600 request file required");
      }
    }

    ~PrivateRequestFile() { if (m_fd >= 0) close(m_fd); }

    [[nodiscard]] nlohmann::json readJson() const {
      std::array<char, 4096> data{};
      const auto count = pread(m_fd, data.data(), data.size(), 0);
      if (count <= 0) throw std::runtime_error("request read failed");
      return nlohmann::json::parse(data.data(), data.data() + count);
    }

    void reply(const nlohmann::json& value) const {
      const auto encoded = value.dump();
      if (encoded.empty() || encoded.size() > 4096 ||
          pwrite(m_fd, encoded.data(), encoded.size(), 0) != static_cast<ssize_t>(encoded.size()) ||
          ftruncate(m_fd, static_cast<off_t>(encoded.size())) != 0)
        throw std::runtime_error("response write failed");
    }

  private:
    int m_fd = -1;
};

int desktopWindowRequest(lua_State* state) {
  try {
    size_t length = 0;
    const auto* path = lua_tolstring(state, 1, &length);
    if (!path || length == 0) throw std::runtime_error("request path required");
    PrivateRequestFile file{std::string_view{path, length}};
    if (!g_desktopWindowController) throw std::runtime_error("desktop window controller unavailable");
    const auto result = g_desktopWindowController->handle(file.readJson());
    file.reply(result);
    // A syntactically handled request returns true. The authenticated caller
    // must inspect the private-file JSON `ok` field before treating a move as applied.
    lua_pushboolean(state, true);
    return 1;
  } catch (const std::exception& error) {
    lua_pushboolean(state, false);
    lua_pushstring(state, error.what());
    return 2;
  }
}

} // namespace

// Optional synchronous compositor-thread interop, queried by edgehover before
// it synthesizes local input. No cached callback survives plugin unload.
APICALL EXPORT bool viewflow_input_capture_active_v1() {
  return g_inputCapture && g_inputCapture->captured();
}

APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
  g_handle = handle;

  const std::string compositorHash = __hyprland_api_get_hash();
  const std::string pluginHash = __hyprland_api_get_client_hash();
  if (compositorHash != pluginHash) {
    HyprlandAPI::addNotification(
        handle, "[Viewflow] Refusing ABI-mismatched Hyprland plugin",
        CHyprColor{1.0F, 0.2F, 0.2F, 1.0F}, 5000);
    throw std::runtime_error("Viewflow Hyprland plugin ABI mismatch: rebuild "
                             "against the active Hyprland headers");
  }

  g_bridge = std::make_unique<viewflow::hyprland::MetadataBridge>();
  g_bridge->start();
  g_inputCapture =
      std::make_unique<viewflow::hyprland::InputCapture>(*g_bridge);
  g_inputCapture->start();
  g_desktopWindowController =
      std::make_unique<viewflow::hyprland::DesktopWindowController>();
  if (!HyprlandAPI::addLuaFunction(handle, "viewflow", "capture_status", [](lua_State *state) -> int {
        const auto json = g_inputCapture ? g_inputCapture->captureStatusJson() : "{}";
        lua_pushlstring(state, json.data(), json.size());
        return 1;
      }) || !HyprlandAPI::addLuaFunction(handle, "viewflow", "pointer_timings", [](lua_State *state) -> int {
        const auto json = g_inputCapture ? g_inputCapture->pointerTimingsJson() : "[]";
        lua_pushlstring(state, json.data(), json.size());
        return 1;
      }) || !HyprlandAPI::addLuaFunction(handle, "viewflow", "desktop_window", desktopWindowRequest)) {
    g_desktopWindowController.reset();
    g_inputCapture.reset();
    g_bridge.reset();
    throw std::runtime_error("Viewflow timing query registration failed");
  }

  constexpr std::string_view focusMotionSymbol = "_ZN13CInputManager25sendMotionEventsToFocusedEv";
  const auto matches = HyprlandAPI::findFunctionsByName(handle, std::string(focusMotionSymbol));
  const void* address = nullptr;
  for (const auto& match : matches) {
    if (match.signature != focusMotionSymbol) continue;
    if (address) { address = nullptr; break; }
    address = match.address;
  }
  if (address) g_focusMotionHook = HyprlandAPI::createFunctionHook(handle, address,
      reinterpret_cast<const void*>(&focusedMotionHook));
  if (!g_focusMotionHook || !g_focusMotionHook->hook()) {
    if (g_focusMotionHook) HyprlandAPI::removeFunctionHook(handle, g_focusMotionHook);
    g_focusMotionHook = nullptr;
    g_desktopWindowController.reset();
    g_inputCapture.reset();
    g_bridge.reset();
    throw std::runtime_error("Viewflow exact compositor focus-motion hook unavailable");
  }

  return {
      "viewflow-hyprland",
      "Non-blocking Viewflow metadata and physical edge-input bridge (no "
      "pixel capture)",
      "Viewflow contributors",
      "0.1.0",
  };
}

APICALL EXPORT void PLUGIN_EXIT() {
  if (g_focusMotionHook) HyprlandAPI::removeFunctionHook(g_handle, g_focusMotionHook);
  g_focusMotionHook = nullptr;
  if (g_desktopWindowController) g_desktopWindowController->shutdown();
  g_desktopWindowController.reset();
  g_inputCapture.reset();
  g_bridge.reset();
  g_handle = nullptr;
}

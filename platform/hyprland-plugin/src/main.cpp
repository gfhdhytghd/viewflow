// SPDX-License-Identifier: GPL-3.0-only
#include "metadata_bridge.hpp"
#include "input_capture.hpp"
#include "desktop_window_controller.hpp"
#include "macos_shadow.hpp"
#include "popup_backdrop.hpp"

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/plugins/HookSystem.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
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
std::unique_ptr<viewflow::hyprland::MacOsShadows> g_macShadows;
std::unique_ptr<viewflow::hyprland::PopupBackdrops> g_popupBackdrops;
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
  // Consumers such as edgehover cancel the current physical event when this
  // is true. A synchronous returned window operation is not that event.
  return g_inputCapture && g_inputCapture->captured() && !g_inputCapture->forwardedMotion;
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
      }) || !HyprlandAPI::addLuaFunction(handle, "viewflow", "forwarded_button", [](lua_State* state) -> int {
        const auto code = lua_tointeger(state, 1), down = lua_tointeger(state, 2), time = lua_tointeger(state, 3);
        if (!g_inputCapture || code < 272 || code > 276 || down < 0 || down > 1 || time < 0 || time > UINT32_MAX) {
          lua_pushliteral(state, "invalid forwarded button"); return lua_error(state);
        }
        g_inputCapture->forwardedButton(static_cast<uint32_t>(code), down != 0, static_cast<uint32_t>(time));
        return 0;
      }) || !HyprlandAPI::addLuaFunction(handle, "viewflow", "forwarded_axis", [](lua_State* state) -> int {
        const auto axis=lua_tointeger(state,1), amount=lua_tointeger(state,2), precise=lua_tointeger(state,3), time=lua_tointeger(state,4);
        if (!g_inputCapture || axis<0 || axis>1 || amount<INT32_MIN || amount>INT32_MAX || precise<0 || precise>1 || time<0 || time>UINT32_MAX) {
          lua_pushliteral(state,"invalid forwarded axis"); return lua_error(state);
        }
        g_inputCapture->forwardedAxis(static_cast<uint32_t>(axis),-double(amount)/(precise?1000.0:8.0),
            precise?0:static_cast<int32_t>(-amount),precise?WL_POINTER_AXIS_SOURCE_CONTINUOUS:WL_POINTER_AXIS_SOURCE_WHEEL,static_cast<uint32_t>(time));
        return 0;
      }) || !HyprlandAPI::addLuaFunction(handle, "viewflow", "with_forwarded_motion", [](lua_State* state) -> int {
        if (!g_inputCapture || !lua_isfunction(state, 1)) {
          lua_pushliteral(state, "forwarded motion requires a function");
          return lua_error(state);
        }
        const bool previous = g_inputCapture->forwardedMotion;
        const auto physicalPosition = g_pInputManager->getMouseCoordsInternal();
        g_inputCapture->forwardedMotion = true;
        lua_pushvalue(state, 1);
        const int result = lua_pcall(state, 0, 0, 0);
        // Returned window input borrows the seat position for synchronous
        // hit testing. It must not move the physical cross-desktop cursor or
        // manufacture a new edge crossing after the user has returned home.
        if (!previous) Pointer::mgr()->warpTo(physicalPosition);
        g_inputCapture->forwardedMotion = previous;
        if (result != LUA_OK) return lua_error(state);
        return 0;
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

  g_macShadows = std::make_unique<viewflow::hyprland::MacOsShadows>(handle);
  g_popupBackdrops = std::make_unique<viewflow::hyprland::PopupBackdrops>(handle);
  return {
      "viewflow-hyprland",
      "Non-blocking Viewflow metadata and physical edge-input bridge (no "
      "pixel capture)",
      "Viewflow contributors",
      "0.1.0",
  };
}

APICALL EXPORT void PLUGIN_EXIT() {
  g_popupBackdrops.reset();
  g_macShadows.reset();
  if (g_focusMotionHook) HyprlandAPI::removeFunctionHook(g_handle, g_focusMotionHook);
  g_focusMotionHook = nullptr;
  if (g_desktopWindowController) g_desktopWindowController->shutdown();
  g_desktopWindowController.reset();
  g_inputCapture.reset();
  g_bridge.reset();
  g_handle = nullptr;
}

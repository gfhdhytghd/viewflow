// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "socket_sink.hpp"
#include "input_dispatch_origin.hpp"

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>

#include <chrono>
#include <cstdint>
#include <functional>
#include <string>
#include <optional>
#include <span>
#include <unordered_map>

struct wl_event_source;

namespace viewflow::hyprland {

struct WindowState {
  std::uint64_t id = 0;
  std::int64_t monitorId = -1;
  std::int64_t workspaceId = -1;
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
  double scale = 1;
  float alpha = 1;
  std::uint32_t flags = 0;
  std::string className;
  std::string title;

  bool operator==(const WindowState &) const = default;
};

struct MonitorState {
  std::int64_t id = -1;
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
  double pixelWidth = 0;
  double pixelHeight = 0;
  double scale = 1;
  double refreshHz = 0;
  std::uint32_t transform = 0;
  std::string name;
  std::string description;

  bool operator==(const MonitorState &) const = default;
};

class MetadataBridge {
public:
  MetadataBridge();
  ~MetadataBridge();

  MetadataBridge(const MetadataBridge &) = delete;
  MetadataBridge &operator=(const MetadataBridge &) = delete;

  void start();
  void onCommandsReady(std::function<void(InputDispatchOrigin)> callback);
  [[nodiscard]] bool send(protocol::MessageType type,
                          std::span<const std::byte> payload);
  [[nodiscard]] std::optional<ReceivedPacket> receive();
  [[nodiscard]] bool connected() const noexcept;
  [[nodiscard]] std::uint64_t connectionGeneration() const noexcept;

private:
  void refreshNativeSource();
  [[nodiscard]] bool ensureSession();
  void reconcile();
  [[nodiscard]] bool sendSnapshot();
  void upsertWindow(PHLWINDOW window, bool force = false);
  void removeWindow(PHLWINDOW window);
  void upsertMonitor(PHLMONITOR monitor, bool force = false);
  void removeMonitor(PHLMONITOR monitor);
  [[nodiscard]] bool transmitWindow(const WindowState &state);
  [[nodiscard]] bool transmitMonitor(const MonitorState &state);
  [[nodiscard]] static WindowState readWindow(PHLWINDOW window);
  [[nodiscard]] static MonitorState readMonitor(PHLMONITOR monitor);

  SocketSink m_sink;
  std::function<void(InputDispatchOrigin)> m_commandsReady;
  wl_event_source *m_nativeReadable = nullptr;
  wl_event_source *m_nativeTimer = nullptr;
  int m_nativeFd = -1;
  std::uint64_t m_nativeGeneration = 0;
  std::uint64_t m_seenConnectionGeneration = 0;
  bool m_sendingSnapshot = false;
  std::chrono::steady_clock::time_point m_lastReconcile{};
  std::unordered_map<std::uint64_t, WindowState> m_windows;
  std::unordered_map<std::int64_t, MonitorState> m_monitors;

  CHyprSignalListener m_windowOpen;
  CHyprSignalListener m_windowClose;
  CHyprSignalListener m_windowTitle;
  CHyprSignalListener m_windowClass;
  CHyprSignalListener m_windowFullscreen;
  CHyprSignalListener m_windowFloating;
  CHyprSignalListener m_windowPin;
  CHyprSignalListener m_windowWorkspace;
  CHyprSignalListener m_monitorAdded;
  CHyprSignalListener m_monitorRemoved;
  CHyprSignalListener m_monitorLayout;
  CHyprSignalListener m_renderPre;
};

} // namespace viewflow::hyprland

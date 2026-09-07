// SPDX-License-Identifier: GPL-3.0-only
#include "metadata_bridge.hpp"

#include <hyprland/src/Compositor.hpp>

#include <hyprland/src/SharedDefs.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/version.h>

#include <algorithm>
#include <span>
#include <stdexcept>
#include <unordered_set>
#include <utility>
#include <vector>

namespace viewflow::hyprland {
namespace {

constexpr auto RECONCILE_INTERVAL = std::chrono::milliseconds{4};

std::span<const std::byte> payloadOf(const std::vector<std::byte> &packet) {
  return std::span{packet}.subspan(protocol::HEADER_SIZE);
}

std::string bounded(std::string value, std::size_t maximum) {
  if (value.size() > maximum)
    value.resize(maximum);
  return value;
}

} // namespace

MetadataBridge::MetadataBridge() = default;

MetadataBridge::~MetadataBridge() {
  if (m_nativeTimer) wl_event_source_remove(m_nativeTimer);
  if (m_nativeReadable) wl_event_source_remove(m_nativeReadable);
}

void MetadataBridge::onCommandsReady(std::function<void(InputDispatchOrigin)> callback) {
  m_commandsReady = std::move(callback);
  refreshNativeSource();
}

void MetadataBridge::refreshNativeSource() {
  const auto fd = m_sink.nativeFd();
  const auto generation = m_sink.connectionGeneration();
  if (m_commandsReady && m_nativeReadable && fd == m_nativeFd &&
      generation == m_nativeGeneration)
    return;
  if (m_nativeReadable) {
    wl_event_source_remove(m_nativeReadable);
    m_nativeReadable = nullptr;
  }
  m_nativeFd = -1;
  m_nativeGeneration = 0;
  if (!m_commandsReady || fd < 0 || !g_pCompositor || !g_pCompositor->m_wlEventLoop)
    return;
  m_nativeReadable = wl_event_loop_add_fd(g_pCompositor->m_wlEventLoop, fd,
      WL_EVENT_READABLE, [](int, uint32_t mask, void *data) -> int {
        auto *bridge = static_cast<MetadataBridge *>(data);
        if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) bridge->m_sink.disconnect();
        if (bridge->m_commandsReady) bridge->m_commandsReady(InputDispatchOrigin::Readable);
        bridge->refreshNativeSource();
        return 0;
      }, this);
  if (!m_nativeReadable) {
    m_sink.disconnect(); // Never retain a connection we cannot service.
    return;
  }
  m_nativeFd = fd;
  m_nativeGeneration = generation;
}

bool MetadataBridge::send(protocol::MessageType type,
                          std::span<const std::byte> payload) {
  const bool sent = ensureSession() && m_sink.send(type, payload);
  refreshNativeSource();
  return sent;
}

std::optional<ReceivedPacket> MetadataBridge::receive() {
  auto packet = m_sink.receive();
  refreshNativeSource();
  return packet;
}

bool MetadataBridge::connected() const noexcept { return m_sink.connected(); }
std::uint64_t MetadataBridge::connectionGeneration() const noexcept {
  return m_sink.connectionGeneration();
}

void MetadataBridge::start() {
  // Animation ticks stop on a static desktop. Commands are serviced by FD
  // readiness; this low-rate watchdog only reconnects and maintains idle state.
  m_nativeTimer = wl_event_loop_add_timer(g_pCompositor->m_wlEventLoop,
      [](void *data) -> int {
        auto *bridge = static_cast<MetadataBridge *>(data);
        (void)bridge->ensureSession();
        if (bridge->m_commandsReady) bridge->m_commandsReady(InputDispatchOrigin::Watchdog);
        wl_event_source_timer_update(bridge->m_nativeTimer, 100);
        return 0;
      }, this);
  if (!m_nativeTimer)
    throw std::runtime_error("Viewflow native IPC watchdog registration failed");
  wl_event_source_timer_update(m_nativeTimer, 100);
  auto &events = Event::bus()->m_events;

  m_windowOpen = events.window.open.listen(
      [this](PHLWINDOW window) { upsertWindow(std::move(window)); });
  m_windowClose = events.window.close.listen(
      [this](PHLWINDOW window) { removeWindow(std::move(window)); });
  m_windowTitle = events.window.title.listen(
      [this](PHLWINDOW window) { upsertWindow(std::move(window)); });
  m_windowClass = events.window.class_.listen(
      [this](PHLWINDOW window) { upsertWindow(std::move(window)); });
  m_windowFullscreen = events.window.fullscreen.listen(
      [this](PHLWINDOW window) { upsertWindow(std::move(window)); });
  m_windowFloating = events.window.floating.listen(
      [this](PHLWINDOW window) { upsertWindow(std::move(window)); });
  m_windowPin = events.window.pin.listen(
      [this](PHLWINDOW window) { upsertWindow(std::move(window)); });
  m_windowWorkspace = events.window.moveToWorkspace.listen(
      [this](PHLWINDOW window, PHLWORKSPACE) {
        upsertWindow(std::move(window));
      });

  m_monitorAdded = events.monitor.added.listen(
      [this](PHLMONITOR monitor) { upsertMonitor(std::move(monitor)); });
  m_monitorRemoved = events.monitor.removed.listen(
      [this](PHLMONITOR monitor) { removeMonitor(std::move(monitor)); });
  m_monitorLayout =
      events.monitor.layoutChanged.listen([this] { reconcile(); });
  m_renderPre = events.render.pre.listen([this](PHLMONITOR) {
    const auto now = std::chrono::steady_clock::now();
    if (now - m_lastReconcile >= RECONCILE_INTERVAL) {
      m_lastReconcile = now;
      // Service already-queued input before rendering work as well as on FD
      // readiness. Live capture may keep rendering while an IPC readiness
      // callback is delayed. The same bounded command drain and original
      // native deadlines apply; this is not a new source of input authority.
      if (m_commandsReady) m_commandsReady(InputDispatchOrigin::RenderPre);
      reconcile();
    }
  });

  reconcile();
}

bool MetadataBridge::ensureSession() {
  if (m_sendingSnapshot)
    return true;
  if (!m_sink.ensureConnected()) {
    refreshNativeSource();
    return false;
  }
  refreshNativeSource();
  if (!m_sink.connected()) return false;
  if (m_seenConnectionGeneration == m_sink.connectionGeneration())
    return true;

  const auto generation = m_sink.connectionGeneration();
  if (!sendSnapshot()) {
    m_sink.disconnect();
    refreshNativeSource();
    return false;
  }

  m_seenConnectionGeneration = generation;
  return true;
}

bool MetadataBridge::sendSnapshot() {
  m_sendingSnapshot = true;
  m_windows.clear();
  m_monitors.clear();

  protocol::PacketBuilder hello{protocol::MessageType::HELLO, 0};
  hello.appendString("viewflow-hyprland", protocol::MAX_NAME_BYTES);
  hello.appendString(GIT_COMMIT_HASH, protocol::MAX_DESCRIPTION_BYTES);
  auto helloPacket = hello.finish();
  if (!m_sink.send(protocol::MessageType::HELLO, payloadOf(helloPacket)) ||
      !m_sink.send(protocol::MessageType::SNAPSHOT_BEGIN, {})) {
    m_sendingSnapshot = false;
    return false;
  }

  for (const auto &monitor : State::monitorState()->monitors()) {
    if (!monitor)
      continue;
    const auto state = readMonitor(monitor);
    if (!transmitMonitor(state)) {
      m_sendingSnapshot = false;
      return false;
    }
    m_monitors[state.id] = state;
  }

  for (const auto &window : Desktop::windowState()->windows()) {
    if (!Desktop::View::validMapped(window))
      continue;
    const auto state = readWindow(window);
    if (!transmitWindow(state)) {
      m_sendingSnapshot = false;
      return false;
    }
    m_windows[state.id] = state;
  }

  const bool complete = m_sink.send(protocol::MessageType::SNAPSHOT_END, {});
  m_sendingSnapshot = false;
  return complete;
}

void MetadataBridge::reconcile() {
  if (!ensureSession())
    return;

  std::unordered_set<std::int64_t> liveMonitors;
  for (const auto &monitor : State::monitorState()->monitors()) {
    if (!monitor)
      continue;
    liveMonitors.insert(monitor->m_id);
    upsertMonitor(monitor);
  }

  std::vector<std::int64_t> removedMonitors;
  for (const auto &[id, state] : m_monitors)
    if (!liveMonitors.contains(id))
      removedMonitors.push_back(id);
  for (const auto id : removedMonitors) {
    protocol::PacketBuilder payload{protocol::MessageType::MONITOR_REMOVE, 0};
    payload.appendIntegral(id);
    auto packet = payload.finish();
    if (m_sink.send(protocol::MessageType::MONITOR_REMOVE, payloadOf(packet)))
      m_monitors.erase(id);
  }

  std::unordered_set<std::uint64_t> liveWindows;
  for (const auto &window : Desktop::windowState()->windows()) {
    if (!Desktop::View::validMapped(window))
      continue;
    const auto id = reinterpret_cast<std::uintptr_t>(window.get());
    liveWindows.insert(id);
    upsertWindow(window);
  }

  std::vector<std::uint64_t> removedWindows;
  for (const auto &[id, state] : m_windows)
    if (!liveWindows.contains(id))
      removedWindows.push_back(id);
  for (const auto id : removedWindows) {
    protocol::PacketBuilder payload{protocol::MessageType::WINDOW_REMOVE, 0};
    payload.appendIntegral(id);
    auto packet = payload.finish();
    if (m_sink.send(protocol::MessageType::WINDOW_REMOVE, payloadOf(packet)))
      m_windows.erase(id);
  }
}

void MetadataBridge::upsertWindow(PHLWINDOW window, bool force) {
  if (!window || (!m_sendingSnapshot && !ensureSession()))
    return;
  const auto state = readWindow(window);
  if (!force) {
    const auto existing = m_windows.find(state.id);
    if (existing != m_windows.end() && existing->second == state)
      return;
  }
  if (transmitWindow(state))
    m_windows[state.id] = state;
}

void MetadataBridge::removeWindow(PHLWINDOW window) {
  if (!window || !ensureSession())
    return;
  const auto id = static_cast<std::uint64_t>(
      reinterpret_cast<std::uintptr_t>(window.get()));
  protocol::PacketBuilder payload{protocol::MessageType::WINDOW_REMOVE, 0};
  payload.appendIntegral(id);
  auto packet = payload.finish();
  if (m_sink.send(protocol::MessageType::WINDOW_REMOVE, payloadOf(packet)))
    m_windows.erase(id);
}

void MetadataBridge::upsertMonitor(PHLMONITOR monitor, bool force) {
  if (!monitor || (!m_sendingSnapshot && !ensureSession()))
    return;
  const auto state = readMonitor(monitor);
  if (!force) {
    const auto existing = m_monitors.find(state.id);
    if (existing != m_monitors.end() && existing->second == state)
      return;
  }
  if (transmitMonitor(state))
    m_monitors[state.id] = state;
}

void MetadataBridge::removeMonitor(PHLMONITOR monitor) {
  if (!monitor || !ensureSession())
    return;
  protocol::PacketBuilder payload{protocol::MessageType::MONITOR_REMOVE, 0};
  payload.appendIntegral(monitor->m_id);
  auto packet = payload.finish();
  if (m_sink.send(protocol::MessageType::MONITOR_REMOVE, payloadOf(packet)))
    m_monitors.erase(monitor->m_id);
}

bool MetadataBridge::transmitWindow(const WindowState &state) {
  protocol::PacketBuilder payload{protocol::MessageType::WINDOW_UPSERT, 0};
  payload.appendIntegral(state.id);
  payload.appendIntegral(state.monitorId);
  payload.appendIntegral(state.workspaceId);
  payload.appendDouble(state.x);
  payload.appendDouble(state.y);
  payload.appendDouble(state.width);
  payload.appendDouble(state.height);
  payload.appendDouble(state.scale);
  payload.appendFloat(state.alpha);
  payload.appendIntegral(state.flags);
  payload.appendString(state.className, protocol::MAX_CLASS_BYTES);
  payload.appendString(state.title, protocol::MAX_TITLE_BYTES);
  auto packet = payload.finish();
  return m_sink.send(protocol::MessageType::WINDOW_UPSERT, payloadOf(packet));
}

bool MetadataBridge::transmitMonitor(const MonitorState &state) {
  protocol::PacketBuilder payload{protocol::MessageType::MONITOR_UPSERT, 0};
  payload.appendIntegral(state.id);
  payload.appendDouble(state.x);
  payload.appendDouble(state.y);
  payload.appendDouble(state.width);
  payload.appendDouble(state.height);
  payload.appendDouble(state.pixelWidth);
  payload.appendDouble(state.pixelHeight);
  payload.appendDouble(state.scale);
  payload.appendDouble(state.refreshHz);
  payload.appendIntegral(state.transform);
  payload.appendString(state.name, protocol::MAX_NAME_BYTES);
  payload.appendString(state.description, protocol::MAX_DESCRIPTION_BYTES);
  auto packet = payload.finish();
  return m_sink.send(protocol::MessageType::MONITOR_UPSERT, payloadOf(packet));
}

WindowState MetadataBridge::readWindow(PHLWINDOW window) {
  const auto position =
      window->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
  const auto size = window->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
  const auto monitor = window->m_monitor.lock();

  std::uint32_t flags = 0;
  if (window->m_isMapped)
    flags |= protocol::WINDOW_MAPPED;
  if (window->m_isFloating)
    flags |= protocol::WINDOW_FLOATING;
  if (Fullscreen::controller()->isFullscreen(window))
    flags |= protocol::WINDOW_FULLSCREEN;
  if (window->m_pinned)
    flags |= protocol::WINDOW_PINNED;
  if (window->m_isX11)
    flags |= protocol::WINDOW_X11;
  if (window->m_class.size() > protocol::MAX_CLASS_BYTES ||
      window->m_title.size() > protocol::MAX_TITLE_BYTES)
    flags |= protocol::WINDOW_TEXT_TRUNCATED;

  return {
      .id = static_cast<std::uint64_t>(
          reinterpret_cast<std::uintptr_t>(window.get())),
      .monitorId = monitor ? monitor->m_id : -1,
      .workspaceId = window->m_workspace ? window->workspaceID() : -1,
      .x = position.x,
      .y = position.y,
      .width = size.x,
      .height = size.y,
      .scale = monitor ? monitor->m_scale : 1.0,
      .alpha = window->effectiveAlpha(),
      .flags = flags,
      .className = bounded(window->m_class, protocol::MAX_CLASS_BYTES),
      .title = bounded(window->m_title, protocol::MAX_TITLE_BYTES),
  };
}

MonitorState MetadataBridge::readMonitor(PHLMONITOR monitor) {
  return {
      .id = monitor->m_id,
      .x = monitor->m_position.x,
      .y = monitor->m_position.y,
      .width = monitor->m_size.x,
      .height = monitor->m_size.y,
      .pixelWidth = monitor->m_pixelSize.x,
      .pixelHeight = monitor->m_pixelSize.y,
      .scale = monitor->m_scale,
      .refreshHz = monitor->m_refreshRate,
      .transform = static_cast<std::uint32_t>(monitor->m_transform),
      .name = bounded(monitor->m_name, protocol::MAX_NAME_BYTES),
      .description =
          bounded(monitor->m_description, protocol::MAX_DESCRIPTION_BYTES),
  };
}

} // namespace viewflow::hyprland

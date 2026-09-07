// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "metadata_bridge.hpp"
#include "window_pointer_session.hpp"
#include "window_pointer_authority.hpp"
#include <memory>
#include <array>
#include <optional>
#include "pointer_timing_ring.hpp"
#include <string>

namespace viewflow::hyprland {
// Consumes commands only from MetadataBridge's checked, same-user local IPC.
// The authenticated network runtime must authorize before writing this IPC.
class WindowPointerController {
public:
  bool acceptsImeKeyboard(const SP<IKeyboard>& keyboard) const;
  bool imeKey(const SP<IKeyboard>& keyboard, std::uint32_t key, std::uint32_t state, std::uint32_t timeMs);
  bool imeModifiers(const SP<IKeyboard>& keyboard);
  explicit WindowPointerController(MetadataBridge &bridge) : m_bridge(bridge) {}
  bool handle(const ReceivedPacket &packet, bool routeAvailable,
              std::uint64_t tickStarted, std::uint64_t readStarted, InputDispatchOrigin origin,
              std::uint64_t previousDispatchStarted, std::uint64_t previousDispatchEnded);
  void poll(bool routeAvailable);
  void cancel(WindowPointerRevocation reason = WindowPointerRevocation::RouteUnavailable);
  void captureLoopback(bool enabled, const void *keyboard = nullptr);
  [[nodiscard]] std::string timingsJson() const;
  bool suppressConvenienceMotion() const { return m_session && m_session->suppressConvenienceMotion(); }
private:
  PointerTimingRing m_timings;
  std::uint32_t m_lastPointerFocusDiagnostic = 0;
  std::uint32_t m_lastKeyboardRuntimeDiagnostic = 0;
  PointerFocusTrace m_lastPointerFocusTrace;
  void notifyRevoked(WindowPointerRevocation reason);
  void retire(bool preserveFocus = false);
  bool completePendingBegin(bool accepted);
  struct PendingBegin {
    PointerTimingRing::Timing timing;
    std::array<std::uint64_t, 3> target;
  };
  std::optional<PendingBegin> m_pendingBegin;
  MetadataBridge &m_bridge;
  std::unique_ptr<WindowPointerSession> m_session;
  std::uint64_t m_connection = 0;
  WindowPointerAuthority m_authority;
  std::array<std::uint64_t, 3> m_boundTarget{};
  std::optional<std::array<std::uint64_t, 3>> m_closedTarget;
  // A failed native keyboard release fences this controller across reconnects.
  bool m_cleanupFailed = false;
  WindowPointerRevocation m_lastRevocation = WindowPointerRevocation::None;
  std::shared_ptr<CaptureLoopbackState> m_captureLoopback = std::make_shared<CaptureLoopbackState>();
};
}

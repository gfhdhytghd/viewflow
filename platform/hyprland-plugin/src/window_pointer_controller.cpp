// SPDX-License-Identifier: GPL-3.0-only
#include "window_pointer_controller.hpp"
#include "window_pointer_command.hpp"
#include "diagnostic_clock.hpp"
#include "window_input_lifecycle.hpp"
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <time.h>

namespace viewflow::hyprland {
bool WindowPointerController::acceptsImeKeyboard(const SP<IKeyboard>& keyboard) const {
  return m_session && m_session->acceptsImeKeyboard(keyboard);
}
bool WindowPointerController::imeKey(const SP<IKeyboard>& keyboard, std::uint32_t key, std::uint32_t state, std::uint32_t timeMs) {
  return m_session && m_session->imeKey(keyboard, key, state, timeMs);
}
bool WindowPointerController::imeModifiers(const SP<IKeyboard>& keyboard) {
  return m_session && m_session->imeModifiers(keyboard);
}

namespace {
using Clock = WindowPointerSession::Clock;
std::optional<Clock::time_point> localDeadline(std::uint64_t deadline) {
  // Take steady time first: conversion must never extend the native deadline.
  const auto steady = Clock::now();
  timespec now{};
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0)
    return std::nullopt;
  const auto mono = std::uint64_t(now.tv_sec) * 1'000'000'000ULL + std::uint64_t(now.tv_nsec);
  // Bounded native grant lifetime. A fresh source-authorized generation is
  // needed to renew, rather than allowing an unbounded retained session.
  if (deadline <= mono || deadline - mono > 5'000'000'000ULL)
    return std::nullopt;
  return steady + std::chrono::nanoseconds(deadline - mono);
}
std::uint32_t waylandTimeMs() {
  timespec now{};
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    return 0;
  return static_cast<std::uint32_t>(std::uint64_t(now.tv_sec) * 1000ULL + std::uint64_t(now.tv_nsec) / 1'000'000ULL);
}
}

void WindowPointerController::captureLoopback(bool enabled, const void *keyboard) {
  m_captureLoopback->active = enabled;
  m_captureLoopback->keyboard = keyboard;
  if (enabled && !m_cleanupFailed &&
      (m_lastRevocation == WindowPointerRevocation::LocalMotion ||
       m_lastRevocation == WindowPointerRevocation::LocalButton ||
       m_lastRevocation == WindowPointerRevocation::LocalAxis ||
       m_lastRevocation == WindowPointerRevocation::LocalKey ||
       m_lastRevocation == WindowPointerRevocation::Cancelled))
    m_authority.rearmForCapture();
}

void WindowPointerController::cancel(WindowPointerRevocation reason) {
  if (m_session) {
    m_session->end(reason);
    m_cleanupFailed = m_cleanupFailed || !m_session->cleanupSucceeded();
    notifyRevoked(m_cleanupFailed ? WindowPointerRevocation::RouteUnavailable : reason);
    m_authority.revoke();
  }
  retire();
}

void WindowPointerController::retire(bool preserveFocus) {
  if (m_pendingBegin) completePendingBegin(false);
  if (m_session) {
    m_session->end(retirementReason(m_session->inactiveReason()), preserveFocus);
    m_lastPointerFocusDiagnostic = m_session->focusDiagnostic();
    m_timings.recordFocusDiagnostic(m_lastPointerFocusDiagnostic);
    m_lastKeyboardRuntimeDiagnostic = m_session->keyboardRuntimeDiagnostic();
    m_timings.recordKeyboardDiagnostic(m_lastKeyboardRuntimeDiagnostic);
    m_lastPointerFocusTrace = m_session->focusTrace();
    m_timings.recordFocusTrace(m_lastPointerFocusTrace);
    m_cleanupFailed = m_cleanupFailed || !m_session->cleanupSucceeded();
    m_session.reset();
  }
}

bool WindowPointerController::completePendingBegin(bool accepted) {
  if (!m_pendingBegin) return false;
  auto pending = *m_pendingBegin;
  m_pendingBegin.reset();
  auto& timing = pending.timing;
  timing.applied = diagnosticMonotonicNs();
  timing.result = accepted ? 1U : 0U;
  timing.beginStage = accepted ? 9U : 8U;
  timing.keyboardStartupFailure = m_session ? m_session->keyboardStartupFailure() : 11U;
  protocol::PacketBuilder reply{protocol::MessageType::WINDOW_POINTER_RESULT, 0};
  reply.appendIntegral(timing.generation);
  reply.appendIntegral(timing.sequence);
  reply.appendIntegral(timing.result);
  reply.appendIntegral(std::uint32_t{0});
  const auto bytes = reply.finish();
  timing.sent = m_bridge.connected() && m_bridge.connectionGeneration() == m_connection &&
      m_bridge.send(protocol::MessageType::WINDOW_POINTER_RESULT,
          std::span{bytes}.subspan(protocol::HEADER_SIZE));
  timing.replied = diagnosticMonotonicNs();
  m_timings.push(timing);
  if (accepted && timing.sent) m_boundTarget = pending.target;
  else m_authority.revoke();
  return accepted && timing.sent;
}

std::string WindowPointerController::timingsJson() const {
  return m_timings.json();
}

void WindowPointerController::poll(bool routeAvailable) {
  if (!routeAvailable) cancel();
  if (!m_bridge.connected() || m_connection != m_bridge.connectionGeneration()) {
    retire();
    m_authority.reset();
    m_lastPointerFocusDiagnostic = 0;
    m_lastKeyboardRuntimeDiagnostic = 0;
    m_lastPointerFocusTrace = {};
    m_boundTarget = {};
    m_closedTarget.reset();
    m_connection = m_bridge.connectionGeneration();
  }
  if (m_pendingBegin) {
    if (m_session) m_session->pollAdmission();
    if (m_session && m_session->admissionPending()) return;
    const bool accepted = m_session && m_session->active();
    const bool confirmed = completePendingBegin(accepted);
    if (!confirmed) { retire(); return; }
  }
  if (m_session && !m_session->active()) {
    if (m_authority.resizeSuspended()) {
      const auto reason = m_session->resizeGuardReason();
      if (reason == WindowPointerRevocation::Resized) return;
      notifyRevoked(reason);
    } else {
      // Cleanup precedes the resize notification. Retain only the inert exact
      // target/listeners, with the original lease as the suspension deadline.
      m_session->end(m_session->inactiveReason());
      if (!m_session->cleanupSucceeded()) {
        m_cleanupFailed = true;
        notifyRevoked(WindowPointerRevocation::RouteUnavailable);
        m_authority.revoke();
        retire();
        return;
      }
      const auto reason = m_session->resizeGuardReason();
      if (reason == WindowPointerRevocation::Resized && m_authority.suspendForResize()) {
        notifyRevoked(reason);
        return;
      }
      notifyRevoked(m_session->inactiveReason() == WindowPointerRevocation::Resized ?
          reason : m_session->inactiveReason());
    }
    const auto reason = m_lastRevocation;
    retire();
    if (!m_cleanupFailed && (reason == WindowPointerRevocation::WindowUnmapped ||
        reason == WindowPointerRevocation::SurfaceUnmapped || reason == WindowPointerRevocation::SurfaceDestroyed)) {
      m_closedTarget = m_boundTarget;
      m_authority.retireTarget();
    } else m_authority.revoke(); // Other revocations remain irreversible.
  }
}

void WindowPointerController::notifyRevoked(WindowPointerRevocation reason) {
  m_lastRevocation = reason;
  if (!m_bridge.connected() || m_bridge.connectionGeneration() != m_connection ||
      m_authority.generation() == 0 || reason == WindowPointerRevocation::None)
    return;
  protocol::PacketBuilder packet{protocol::MessageType::WINDOW_POINTER_REVOKED, 0};
  packet.appendIntegral(m_authority.generation());
  packet.appendIntegral(static_cast<std::uint32_t>(reason));
  packet.appendIntegral(std::uint32_t{0});
  const auto bytes = packet.finish();
  (void)m_bridge.send(protocol::MessageType::WINDOW_POINTER_REVOKED,
      std::span{bytes}.subspan(protocol::HEADER_SIZE));
}

bool WindowPointerController::handle(const ReceivedPacket &packet, bool routeAvailable,
                                     std::uint64_t tickStarted, std::uint64_t readStarted, InputDispatchOrigin origin,
                                     std::uint64_t previousDispatchStarted, std::uint64_t previousDispatchEnded) {
  using protocol::MessageType;
  if (packet.type != MessageType::WINDOW_POINTER_BEGIN &&
      packet.type != MessageType::WINDOW_POINTER_BEGIN_BUTTONS &&
      packet.type != MessageType::WINDOW_POINTER_BEGIN_BUTTONS_WHEEL &&
      packet.type != MessageType::WINDOW_INPUT_BEGIN_DIRECT_KEYBOARD &&
      packet.type != MessageType::WINDOW_INPUT_REBIND_RESIZED &&
      packet.type != MessageType::WINDOW_KEYBOARD_KEY &&
      packet.type != MessageType::WINDOW_POINTER_MOVE &&
      packet.type != MessageType::WINDOW_POINTER_BUTTON &&
      packet.type != MessageType::WINDOW_POINTER_WHEEL &&
      packet.type != MessageType::WINDOW_POINTER_END &&
      packet.type != MessageType::WINDOW_POINTER_END_PRESERVE_FOCUS)
    return false;
  const auto received = diagnosticMonotonicNs();
  poll(routeAvailable);
  routeAvailable = routeAvailable && !m_cleanupFailed;
  if (!m_bridge.connected())
    return true;
  // The source cannot send application commands before the original BEGIN
  // receipt. Any overlapping command retires this pending admission; it cannot
  // change the target, bypass the IME gate or refresh the waiting deadline.
  const auto command = parseWindowPointerCommand(packet.type, packet.payload);
  if (m_pendingBegin) {
    const bool preserveFocus = command && command->generation == m_authority.generation() &&
        command->type == MessageType::WINDOW_POINTER_END_PRESERVE_FOCUS;
    m_authority.revoke();
    retire(preserveFocus);
  }
  std::uint32_t result = 0; // rejected; never transport-received == applied
  // Fixed-size local diagnostics only: no addresses, key contents or I/O.
  const bool diagnosticBegin = command && (packet.type == MessageType::WINDOW_POINTER_BEGIN ||
      packet.type == MessageType::WINDOW_POINTER_BEGIN_BUTTONS || packet.type == MessageType::WINDOW_POINTER_BEGIN_BUTTONS_WHEEL ||
      packet.type == MessageType::WINDOW_INPUT_BEGIN_DIRECT_KEYBOARD);
  std::uint32_t beginStage = diagnosticBegin ? (routeAvailable ? 2 : 1) : 0;
  std::uint32_t keyboardStartupFailure = 0;
  if (command && !routeAvailable) {
    // Rejected begins cannot become active by replay after device capture ends.
    if (command->type == MessageType::WINDOW_POINTER_BEGIN ||
        command->type == MessageType::WINDOW_POINTER_BEGIN_BUTTONS ||
        command->type == MessageType::WINDOW_POINTER_BEGIN_BUTTONS_WHEEL ||
        command->type == MessageType::WINDOW_INPUT_BEGIN_DIRECT_KEYBOARD)
      m_authority.begin(command->generation, false);
    else if (command->type == MessageType::WINDOW_INPUT_REBIND_RESIZED)
      m_authority.rebind(command->generation, false);
  }
  if (command && routeAvailable) {
    const auto &c = *command;
    const bool allowKeyboard = c.type == MessageType::WINDOW_INPUT_BEGIN_DIRECT_KEYBOARD;
    const bool allowWheel = c.type == MessageType::WINDOW_POINTER_BEGIN_BUTTONS_WHEEL || allowKeyboard;
    const bool begin = c.type == MessageType::WINDOW_POINTER_BEGIN || c.type == MessageType::WINDOW_POINTER_BEGIN_BUTTONS || allowWheel;
    const bool allowButtons = c.type == MessageType::WINDOW_POINTER_BEGIN_BUTTONS || allowWheel;
    if (c.type == MessageType::WINDOW_INPUT_REBIND_RESIZED) {
      if (m_authority.rebind(c.generation, true)) {
        const auto deadline = localDeadline(c.deadlineNs);
        auto replacement = deadline && m_session ? m_session->rebindAfterResize(
            c.windowAddress, c.surfaceAddress, c.pid, {c.x, c.y}, *deadline) : nullptr;
        if (replacement && replacement->active()) {
          m_session = std::move(replacement);
          result = 1;
        } else {
          if (replacement) {
            replacement->end();
            m_cleanupFailed = m_cleanupFailed || !replacement->cleanupSucceeded();
          }
          m_authority.revoke();
          retire();
        }
      }
    } else if (begin && m_authority.begin(c.generation, true) &&
               (!m_closedTarget || *m_closedTarget != std::array<std::uint64_t, 3>{c.windowAddress, c.surfaceAddress, c.pid})) {
      beginStage = 3;
      const auto deadline = localDeadline(c.deadlineNs);
      if (!deadline) beginStage = 4;
      if (m_session) {
        if (deadline && m_session->renew(c.windowAddress, c.surfaceAddress, c.pid,
                                        {c.x, c.y}, *deadline, allowButtons, allowWheel, allowKeyboard))
          result = 1;
        else {
          m_authority.revoke();
          retire();
        }
      } else if (deadline) {
        beginStage = 5;
        for (const auto &window : Desktop::windowState()->windows()) {
          if (reinterpret_cast<std::uintptr_t>(window.get()) != c.windowAddress ||
              window->getPID() != static_cast<pid_t>(c.pid) || !window->wlSurface())
            continue;
          beginStage = 6;
          const auto surface = window->wlSurface()->resource();
          if (!surface || reinterpret_cast<std::uintptr_t>(surface.get()) != c.surfaceAddress ||
              surface->m_current.size != Vector2D(c.x, c.y))
            break;
          beginStage = 7;
          if (auto target = WindowInputTarget::bind(window, m_captureLoopback)) {
            beginStage = 8;
            m_session = std::make_unique<WindowPointerSession>(std::move(*target), *deadline, allowButtons, allowWheel, allowKeyboard, true);
            keyboardStartupFailure = m_session->keyboardStartupFailure();
            if (m_session->active()) { result = 1; beginStage = 9; }
          }
          break;
        }
      }
    } else if (c.generation == m_authority.generation() && m_authority.generation() != 0) {
      if (c.type == MessageType::WINDOW_POINTER_END || c.type == MessageType::WINDOW_POINTER_END_PRESERVE_FOCUS) {
        if (m_authority.resizeSuspended()) m_authority.revoke();
        retire(c.type == MessageType::WINDOW_POINTER_END_PRESERVE_FOCUS);
        if (!m_cleanupFailed) {
          m_authority.end(c.generation, true);
          result = 3; // exact end requires native cleanup
        }
      } else if (c.type == MessageType::WINDOW_POINTER_MOVE && m_session) {
        if (const auto deadline = localDeadline(c.deadlineNs))
          if (m_session->move({c.x, c.y}, *deadline, waylandTimeMs())) result = 2;
      } else if (c.type == MessageType::WINDOW_POINTER_BUTTON && m_session) {
        if (const auto deadline = localDeadline(c.deadlineNs)) {
          if (m_session->button({c.x, c.y}, c.button, c.state, *deadline, waylandTimeMs())) result = 4;
        } else if (c.state == 2) {
          // An expired up is not an applied click, but it must not leave the
          // session's previous down held until an unrelated future command.
          m_session->cancel();
        }
      } else if (c.type == MessageType::WINDOW_POINTER_WHEEL && m_session) {
        if (const auto deadline = localDeadline(c.deadlineNs))
          if (m_session->wheel({c.x, c.y}, c.vertical120, c.horizontal120, *deadline, waylandTimeMs())) result = 5;
      } else if (c.type == MessageType::WINDOW_KEYBOARD_KEY && m_session) {
        if (const auto deadline = localDeadline(c.deadlineNs)) {
          if (m_session->key(c.usagePage, c.usageId, c.state, c.repeat, *deadline, waylandTimeMs())) result = 6;
        } else m_session->cancel();
      }
    }
  }
  if (diagnosticBegin && command && m_session && m_session->admissionPending()) {
    m_pendingBegin = PendingBegin{
      {packet.sequence, command->generation, received, 0, 0, command->deadlineNs,
       static_cast<std::uint32_t>(packet.type), 0, false, tickStarted, readStarted, origin,
       previousDispatchStarted, previousDispatchEnded, 10, 0},
      {command->windowAddress, command->surfaceAddress, command->pid}};
    return true; // The exact original receipt is emitted only after admission.
  }
  const auto applied = diagnosticMonotonicNs();
  if (command && result == 1) m_boundTarget = {command->windowAddress, command->surfaceAddress, command->pid};
  protocol::PacketBuilder reply{MessageType::WINDOW_POINTER_RESULT, 0};
  reply.appendIntegral(command ? command->generation : std::uint64_t{0});
  reply.appendIntegral(packet.sequence);
  reply.appendIntegral(result);
  reply.appendIntegral(std::uint32_t{0});
  const auto bytes = reply.finish();
  const bool sent = m_bridge.connected() && m_bridge.connectionGeneration() == m_connection &&
      m_bridge.send(MessageType::WINDOW_POINTER_RESULT,
                     std::span{bytes}.subspan(protocol::HEADER_SIZE));
  m_timings.push({packet.sequence, command ? command->generation : 0,
      received, applied, diagnosticMonotonicNs(), command ? command->deadlineNs : 0,
      static_cast<std::uint32_t>(packet.type), result, sent, tickStarted, readStarted, origin,
      previousDispatchStarted, previousDispatchEnded, beginStage, keyboardStartupFailure,
      m_session ? m_session->focusDiagnostic() : m_lastPointerFocusDiagnostic,
      m_session ? m_session->keyboardRuntimeDiagnostic() : m_lastKeyboardRuntimeDiagnostic,
      m_session ? m_session->focusTrace() : m_lastPointerFocusTrace});
  if (!sent) {
    m_authority.revoke();
    retire();
  }
  return true;
}
}

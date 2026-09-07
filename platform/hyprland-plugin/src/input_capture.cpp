// SPDX-License-Identifier: GPL-3.0-only
#include "input_capture.hpp"
#include "diagnostic_clock.hpp"

#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/protocols/SessionLock.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>

#include <aquamarine/input/Input.hpp>
#include <libinput.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <cmath>
#include <span>
#include <sstream>
#include <unordered_set>
#include <vector>

namespace viewflow::hyprland {
namespace {

constexpr auto PENDING_TIMEOUT = std::chrono::milliseconds{250};
const std::string INJECTED_TAG = "viewflow-injected";

std::span<const std::byte> payloadOf(const std::vector<std::byte> &packet) {
  return std::span{packet}.subspan(protocol::HEADER_SIZE);
}

template <typename T>
std::optional<T> readIntegral(std::span<const std::byte> bytes,
                              std::size_t offset) {
  if (offset > bytes.size() || sizeof(T) > bytes.size() - offset)
    return std::nullopt;
  using Unsigned = std::make_unsigned_t<T>;
  Unsigned value = 0;
  for (std::size_t i = 0; i < sizeof(T); ++i)
    value |=
        static_cast<Unsigned>(std::to_integer<std::uint8_t>(bytes[offset + i]))
        << (i * 8U);
  return static_cast<T>(value);
}

void appendTarget(protocol::PacketBuilder &payload,
                  const InputLeaseIdentity &lease) {
  for (const auto byte : lease.targetDevice)
    payload.appendIntegral(byte);
}

} // namespace

InputCapture::InputCapture(MetadataBridge &bridge) : m_bridge(bridge), m_windowPointer(bridge) {}

InputCapture::~InputCapture() {
  if (const auto target = m_returnDrag.lock(); target && g_layoutManager->dragController()->target() == target)
    g_layoutManager->endDragTarget();
  m_bridge.onCommandsReady({});
  release(true);
}

void InputCapture::start() {
  auto &events = Event::bus()->m_events;
  m_tick = events.tick.listen([this] { tick(); });
  m_mouseMove = events.input.mouse.move.listen(
      [this](Vector2D position, Event::SCallbackInfo &info) {
        observePointerPosition(position.x, position.y);
        if (!m_core.captured())
          return;
        info.cancelled = true;
        if (const auto &edge = m_core.activeEdge(); edge)
          Pointer::mgr()->warpTo({edge->anchorX, edge->anchorY});
      });
  m_mouseButton = events.input.mouse.button.listen(
      [this](IPointer::SButtonEvent, Event::SCallbackInfo &info) {
        if (m_core.captured())
          info.cancelled = true;
      });
  m_mouseAxis = events.input.mouse.axis.listen(
      [this](IPointer::SAxisEvent, Event::SCallbackInfo &info) {
        if (m_core.captured())
          info.cancelled = true;
      });
  m_keyboardKey = events.input.keyboard.key.listen(
      [this](IKeyboard::SKeyEvent, Event::SCallbackInfo &info) {
        if (m_core.captured())
          info.cancelled = true;
      });
  m_gestures[0] = events.gesture.swipe.begin.listen([this](IPointer::SSwipeBeginEvent e, Event::SCallbackInfo& info) {
    if (m_cancelLocalGesture) return;
    auto decision = m_swipeRoute.begin(remoteGesture());
    if (decision.cancelLocal) { m_cancelLocalGesture = true; g_pInputManager->onSwipeEnd({e.timeMs, true}); m_cancelLocalGesture = false; }
    if (decision.suppress) ++m_suppressedGestureEvents; else ++m_localGestureEvents;
    info.cancelled = info.cancelled || decision.suppress;
  });
  m_gestures[1] = events.gesture.swipe.update.listen([this](IPointer::SSwipeUpdateEvent e, Event::SCallbackInfo& info) {
    if (m_cancelLocalGesture) return;
    auto decision = m_swipeRoute.update(remoteGesture());
    if (decision.cancelLocal) { m_cancelLocalGesture = true; g_pInputManager->onSwipeEnd({e.timeMs, true}); m_cancelLocalGesture = false; }
    if (decision.suppress) ++m_suppressedGestureEvents; else ++m_localGestureEvents;
    info.cancelled = info.cancelled || decision.suppress;
  });
  m_gestures[2] = events.gesture.swipe.end.listen([this](IPointer::SSwipeEndEvent e, Event::SCallbackInfo& info) {
    if (m_cancelLocalGesture) return;
    auto decision = m_swipeRoute.end(remoteGesture());
    if (decision.cancelLocal) { m_cancelLocalGesture = true; g_pInputManager->onSwipeEnd({e.timeMs, true}); m_cancelLocalGesture = false; }
    if (decision.suppress) ++m_suppressedGestureEvents; else ++m_localGestureEvents;
    info.cancelled = info.cancelled || decision.suppress;
  });
  m_gestures[3] = events.gesture.pinch.begin.listen([this](IPointer::SPinchBeginEvent e, Event::SCallbackInfo& info) {
    if (m_cancelLocalGesture) return;
    auto decision = m_pinchRoute.begin(remoteGesture());
    if (decision.cancelLocal) { m_cancelLocalGesture = true; g_pInputManager->onPinchEnd({e.timeMs, true}); m_cancelLocalGesture = false; }
    if (decision.suppress) ++m_suppressedGestureEvents; else ++m_localGestureEvents;
    info.cancelled = info.cancelled || decision.suppress;
  });
  m_gestures[4] = events.gesture.pinch.update.listen([this](IPointer::SPinchUpdateEvent e, Event::SCallbackInfo& info) {
    if (m_cancelLocalGesture) return;
    auto decision = m_pinchRoute.update(remoteGesture());
    if (decision.cancelLocal) { m_cancelLocalGesture = true; g_pInputManager->onPinchEnd({e.timeMs, true}); m_cancelLocalGesture = false; }
    if (decision.suppress) ++m_suppressedGestureEvents; else ++m_localGestureEvents;
    info.cancelled = info.cancelled || decision.suppress;
  });
  m_gestures[5] = events.gesture.pinch.end.listen([this](IPointer::SPinchEndEvent e, Event::SCallbackInfo& info) {
    if (m_cancelLocalGesture) return;
    auto decision = m_pinchRoute.end(remoteGesture());
    if (decision.cancelLocal) { m_cancelLocalGesture = true; g_pInputManager->onPinchEnd({e.timeMs, true}); m_cancelLocalGesture = false; }
    if (decision.suppress) ++m_suppressedGestureEvents; else ++m_localGestureEvents;
    info.cancelled = info.cancelled || decision.suppress;
  });
  reconcileDevices();
  if (g_pInputManager) {
    const auto position = g_pInputManager->getMouseCoordsInternal();
    observePointerPosition(position.x, position.y);
  }
  m_bridge.onCommandsReady([this](InputDispatchOrigin origin) { tick(origin); });
}

void InputCapture::tick(InputDispatchOrigin origin) {
  const auto tickStarted = diagnosticMonotonicNs();
  if (m_clickPending) {
    m_clickPending = false;
    const auto window = Desktop::focusState()->window();
    m_clickedWindow = reinterpret_cast<std::uintptr_t>(window.get());
    m_clickSerial = (m_clickSerial % 0x7ffffffeU) + 1;
  }
  if (m_nativeConnection != m_bridge.connectionGeneration()) {
    release(false);
    m_core.resetConnection();
    m_lastReleasedGeneration = 0;
    m_nativeConnection = m_bridge.connectionGeneration();
  }
  m_windowPointer.poll(routeAllowed());
  if (m_core.phase() != CapturePhase::LOCAL && !m_bridge.connected())
    release(false);
  if (m_core.phase() == CapturePhase::CAPTURE_PENDING &&
      std::chrono::steady_clock::now() - m_pendingSince > PENDING_TIMEOUT)
    release(false);
  if (m_core.captured()) {
    const auto &remote = m_core.remote();
    const bool topologyLive = !remote || std::ranges::any_of(State::monitorState()->monitors(), [&](const auto &monitor) {
      if (!monitor || monitor->m_id != remote->monitorId) return false;
      const auto box = monitor->logicalBox();
      return box.x == remote->x && box.y == remote->y && box.width == remote->width && box.height == remote->height;
    });
    if (!topologyLive || !PROTO::sessionLock || PROTO::sessionLock->isLocked()) release(true);
  }
  reconcileDevices();
  drainTouchpad();
  processCommands(tickStarted, origin);
  // A receive callback may have discovered disconnect after the first poll.
  m_windowPointer.poll(routeAllowed());
  if (m_core.phase() != CapturePhase::LOCAL && !m_bridge.connected())
    release(false);
  // Include empty dispatches: command-only history cannot establish whether
  // the compositor was servicing the event loop between two input commands.
  m_previousDispatchStarted = tickStarted;
  m_previousDispatchEnded = diagnosticMonotonicNs();
}

void InputCapture::reconcileDevices() {
  if (!g_pInputManager)
    return;

  std::unordered_set<IPointer *> livePointers;
  for (const auto &pointer : g_pInputManager->m_pointers) {
    if (!pointer || !physical(*pointer))
      continue;
    auto *raw = pointer.get();
    livePointers.insert(raw);
    if (!m_touchpad && pointer->m_isTouchpad) {
      const auto aq = pointer->aq();
      auto* device = aq ? aq->getLibinputHandle() : nullptr;
      if (device) {
        auto capture = std::make_unique<TouchpadCapture>();
        const auto path = std::string("/dev/input/") + libinput_device_get_sysname(device);
        if (capture->open(path)) { m_touchpad = std::move(capture); m_touchpadPointer = raw; }
      }
    }
    if (m_pointers.contains(raw))
      continue;

    auto listeners = std::make_unique<PointerListeners>();
    auto *record = listeners.get();
    listeners->destroy = pointer->m_events.destroy.listen([this, record] {
      record->dead = true;
      if (m_core.captured())
        release(true);
    });
    listeners->motion = pointer->m_pointerEvents.motion.listen(
        [this](const IPointer::SMotionEvent &event) {
          onPointerMotion(event);
        });
    listeners->button = pointer->m_pointerEvents.button.listen(
        [this](const IPointer::SButtonEvent &event) {
          onPointerButton(event);
        });
    listeners->axis = pointer->m_pointerEvents.axis.listen(
        [this, raw](const IPointer::SAxisEvent &event) {
          // Only the captured raw device's derived wheel is redundant.
          if (raw == m_touchpadPointer && rawTouchpad() && m_core.captured() && event.source == WL_POINTER_AXIS_SOURCE_FINGER) return;
          onPointerAxis(event);
        });
    listeners->frame =
        pointer->m_pointerEvents.frame.listen([this] { onPointerFrame(); });
    m_pointers.emplace(raw, std::move(listeners));
  }
  if (m_touchpadPointer && !livePointers.contains(m_touchpadPointer)) {
    m_touchpad.reset(); m_touchpadPointer = nullptr;
  }
  const bool pointerDisappeared =
      std::ranges::any_of(m_pointers, [&](const auto &entry) {
        return entry.second->dead || !livePointers.contains(entry.first);
      });
  std::unordered_set<IKeyboard *> liveKeyboards;
  for (const auto &keyboard : g_pInputManager->m_keyboards) {
    if (!keyboard || (!physical(*keyboard) && !keyboard->isVirtual()))
      continue;
    auto *raw = keyboard.get();
    liveKeyboards.insert(raw);
    if (m_keyboards.contains(raw))
      continue;

    auto listeners = std::make_unique<KeyboardListeners>();
    auto *record = listeners.get();
    listeners->keyboard = keyboard;
    listeners->physical = physical(*keyboard);
    listeners->destroy = keyboard->m_events.destroy.listen([this, record] {
      record->dead = true;
      if (m_core.captured() && record->physical)
        release(true);
    });
    listeners->key = keyboard->m_keyboardEvents.key.listen(
        [this, record](const IKeyboard::SKeyEvent &event) {
          const auto keyboard = record->keyboard.lock();
          if (!keyboard) return;
          const bool trusted = !record->physical && m_windowPointer.acceptsImeKeyboard(keyboard);
          const bool permitted = record->enabledState.permitted(keyboard->m_enabled) && keyboard->m_allowed;
          if (m_core.captured() || trusted) suppressKeyboard(*record);
          else record->enabledState.restore(keyboard->m_enabled);
          if (record->physical) onKey(event);
          else if (trusted && permitted) m_windowPointer.imeKey(keyboard, event.keycode, event.state, event.timeMs);
        });
    // Dynamic device listeners run before Hyprland's static InputManager hook.
    listeners->modifiers =
        keyboard->m_keyboardEvents.modifiers.listen([this, record] {
          const auto keyboard = record->keyboard.lock();
          if (!keyboard) return;
          const bool trusted = !record->physical && m_windowPointer.acceptsImeKeyboard(keyboard);
          const bool permitted = record->enabledState.permitted(keyboard->m_enabled) && keyboard->m_allowed;
          if (m_core.captured() || trusted) suppressKeyboard(*record);
          else record->enabledState.restore(keyboard->m_enabled);
          if (trusted && permitted) m_windowPointer.imeModifiers(keyboard);
        });
    m_keyboards.emplace(raw, std::move(listeners));
  }
  if (m_core.captured()) suppressLocalKeyboards();
  else for (auto& [_, record] : m_keyboards) {
    const auto keyboard = record->keyboard.lock();
    if (keyboard && !record->physical && !m_windowPointer.acceptsImeKeyboard(keyboard))
      record->enabledState.restore(keyboard->m_enabled);
  }

  const bool keyboardDisappeared =
      std::ranges::any_of(m_keyboards, [&](const auto &entry) {
        return entry.second->physical && (entry.second->dead || !liveKeyboards.contains(entry.first));
      });
  if (m_core.captured() && (pointerDisappeared || keyboardDisappeared))
    release(true);

  std::erase_if(m_pointers, [&](const auto &entry) {
    return entry.second->dead || !livePointers.contains(entry.first);
  });
  std::erase_if(m_keyboards, [&](const auto &entry) {
    return entry.second->dead || !liveKeyboards.contains(entry.first);
  });
}

void InputCapture::processCommands(std::uint64_t tickStarted, InputDispatchOrigin origin) {
  // Never let an IPC producer monopolize the compositor event loop. Remaining
  // packets wait for the next tick and still face their original deadlines.
  for (unsigned handled = 0; handled < 64; ++handled) {
    const auto readStarted = diagnosticMonotonicNs();
    const auto packet = m_bridge.receive();
    if (!packet)
      break;
    if (m_windowPointer.handle(*packet, routeAllowed(), tickStarted, readStarted, origin,
                              m_previousDispatchStarted, m_previousDispatchEnded))
      continue;
    if (packet->type == protocol::MessageType::INPUT_CAPTURE_TOPOLOGY) {
      if (packet->payload.size() != 48)
        continue;
      const auto generation = readIntegral<std::uint64_t>(packet->payload, 0);
      const auto monitorId = readIntegral<std::int64_t>(packet->payload, 8);
      const auto number = [&](std::size_t offset) {
        return std::bit_cast<double>(*readIntegral<std::uint64_t>(packet->payload, offset));
      };
      InputRect remote{*monitorId, number(16), number(24), number(32), number(40)};
      receipt(*generation, packet->type, *generation != 0 && m_core.configureRemote(remote));
    } else if (packet->type == protocol::MessageType::INPUT_LEASE_ACTIVATE) {
      if (packet->payload.size() != 24 && packet->payload.size() != 25)
        continue;
      const auto generation = readIntegral<std::uint64_t>(packet->payload, 0);
      if (!generation)
        continue;
      if (physicalKeyHeld()) {
        if (!m_core.captured()) { release(false); m_lastReleasedGeneration = *generation; }
        receipt(*generation, packet->type, false);
        continue;
      }
      InputLeaseIdentity lease{.generation = *generation};
      std::memcpy(lease.targetDevice.data(), packet->payload.data() + 8,
                  lease.targetDevice.size());
      const bool loopback = packet->payload.size() == 25 && packet->payload[24] == std::byte{1};
      if (packet->payload.size() == 25 && packet->payload[24] != std::byte{0} && !loopback) {
        receipt(*generation, packet->type, false);
        continue;
      }
      auto sourceKeyboard = g_pSeatManager ? g_pSeatManager->m_keyboard.lock() : nullptr;
      if (!sourceKeyboard || !physical(*sourceKeyboard) || !sourceKeyboard->m_enabled || !sourceKeyboard->m_allowed) {
        sourceKeyboard = nullptr;
        for (const auto& candidate : g_pInputManager->m_keyboards | std::views::reverse)
          if (candidate && physical(*candidate) && candidate->m_enabled && candidate->m_allowed) { sourceKeyboard = candidate; break; }
      }
      const bool applied = (!loopback || (sourceKeyboard && sourceKeyboard->m_enabled && sourceKeyboard->m_allowed)) &&
          g_pInputManager && !g_pInputManager->hasHeldButtons() && m_core.activate(lease);
      if (applied) {
        if (!loopback) m_windowPointer.cancel();
        m_loopback = loopback;
        m_windowPointer.captureLoopback(loopback, sourceKeyboard.get());
        m_eventSequence = 1;
        suppressLocalKeyboards();
        if (const auto &edge = m_core.activeEdge(); edge)
          Pointer::mgr()->warpTo({edge->anchorX, edge->anchorY});
      }
      if (!applied && !m_core.captured()) { release(false); m_lastReleasedGeneration = *generation; }
      receipt(*generation, packet->type, applied);
    } else if (packet->type == protocol::MessageType::INPUT_LEASE_RELEASE) {
      if (packet->payload.size() != 8 && packet->payload.size() != 24 && packet->payload.size() != 44 && packet->payload.size() != 52)
        continue;
      const auto generation = readIntegral<std::uint64_t>(packet->payload, 0);
      std::optional<Vector2D> returnPosition;
      bool returnValid = true;
      if (packet->payload.size() >= 24) {
        const auto x = std::bit_cast<double>(*readIntegral<std::uint64_t>(packet->payload, 8));
        const auto y = std::bit_cast<double>(*readIntegral<std::uint64_t>(packet->payload, 16));
        returnValid = std::isfinite(x) && std::isfinite(y);
        // Return must land on a real currently present local output.
        returnValid = returnValid && std::ranges::any_of(State::monitorState()->monitors(), [&](const auto &monitor) {
          if (!monitor || !m_core.remote() || monitor->m_id == m_core.remote()->monitorId) return false;
          const auto box = monitor->logicalBox();
          return x >= box.x && x < box.x + box.width && y >= box.y && y < box.y + box.height;
        });
        if (returnValid) returnPosition = Vector2D{x, y};
      }
      const bool alreadyReleased = generation && !m_core.lease() &&
          *generation == m_lastReleasedGeneration && packet->payload.size() == 8;
      const bool applied = alreadyReleased || (returnValid && generation && m_core.lease() &&
          *generation == m_core.lease()->generation);
      if (applied) {
        SP<Layout::ITarget> dragTarget;
        // Look up the live object by identity; never dereference a wire address.
        // Physical release during the revoke round trip means a normal return.
        if (packet->payload.size() >= 44 && m_core.physicalButtonHeld(272)) {
          const auto pid = *readIntegral<std::uint32_t>(packet->payload, 24);
          const auto address = *readIntegral<std::uint64_t>(packet->payload, 28);
          const auto surface = *readIntegral<std::uint64_t>(packet->payload, 36);
          const auto reverseId = packet->payload.size() == 52 ? *readIntegral<std::uint64_t>(packet->payload, 44) : 0;
          for (const auto& window : Desktop::windowState()->windows()) {
            if (window && window->m_isMapped && window->m_isFloating &&
                window->getPID() == static_cast<pid_t>(pid) &&
                reinterpret_cast<std::uintptr_t>(window.get()) == address &&
                ((surface != 0 && reinterpret_cast<std::uintptr_t>(window->resource().get()) == surface) ||
                 (surface == 0 && reverseId != 0 && window->m_class == "ViewflowReverse-" + std::to_string(reverseId)))) {
              dragTarget = window->layoutTarget();
              break;
            }
          }
        }
        release(true);
        if (returnPosition) Pointer::mgr()->warpTo(*returnPosition);
        if (dragTarget && returnPosition && !g_layoutManager->dragController()->target()) {
          g_layoutManager->beginDragTarget(dragTarget, MBIND_MOVE, std::nullopt, true);
          m_returnDrag = dragTarget;
        }
      }
      if (generation)
        receipt(*generation, packet->type, applied);
    }
  }
}

void InputCapture::observePointerPosition(double x, double y) {
  std::vector<InputRect> monitors;
  monitors.reserve(State::monitorState()->monitors().size());
  for (const auto &monitor : State::monitorState()->monitors()) {
    if (!monitor)
      continue;
    const auto box = monitor->logicalBox();
    monitors.push_back({monitor->m_id, box.x, box.y, box.width, box.height});
  }
  m_core.observePosition(x, y, monitors);
}

void InputCapture::onPointerMotion(const IPointer::SMotionEvent &event) {
  if (!m_core.captured()) {
    // Include keys/buttons already held when the plugin was loaded; raw
    // listeners could not have observed those earlier press transitions.
    if (g_pInputManager && g_pInputManager->hasHeldButtons()) return;
    // The compositor-wide ledger includes forwarded virtual keys and can
    // retain a key whose release was consumed by remote capture. Only a
    // currently pressed physical key can defer a physical mouse handoff.
    if (physicalKeyHeld()) return;
    const auto candidate =
        m_core.observeMotion(event.unaccel.x, event.unaccel.y);
    if (!candidate)
      return;
    m_windowPointer.cancel(WindowPointerRevocation::LocalMotion);
    m_pendingSince = std::chrono::steady_clock::now();
    protocol::PacketBuilder payload{protocol::MessageType::EDGE_CANDIDATE, 0};
    payload.appendIntegral(candidate->monitorId);
    payload.appendIntegral(candidate->edge);
    payload.appendDouble(candidate->edgePosition);
    payload.appendDouble(candidate->anchorX);
    payload.appendDouble(candidate->anchorY);
    payload.appendIntegral(event.timeMs);
    if (candidate->entryPosition) {
      payload.appendDouble((*candidate->entryPosition)[0]);
      payload.appendDouble((*candidate->entryPosition)[1]);
    }
    if (!send(protocol::MessageType::EDGE_CANDIDATE, payload))
      release(false);
    return;
  }

  const auto &lease = *m_core.lease();
  protocol::PacketBuilder payload{protocol::MessageType::INPUT_RELATIVE_MOTION,
                                  0};
  payload.appendIntegral(lease.generation);
  appendTarget(payload, lease);
  payload.appendIntegral(m_eventSequence++);
  payload.appendIntegral(event.timeMs);
  payload.appendDouble(event.delta.x);
  payload.appendDouble(event.delta.y);
  payload.appendDouble(event.unaccel.x);
  payload.appendDouble(event.unaccel.y);
  if (!send(protocol::MessageType::INPUT_RELATIVE_MOTION, payload))
    release(false);
}

void InputCapture::onPointerButton(const IPointer::SButtonEvent &event) {
  const bool pressed = event.state == WL_POINTER_BUTTON_STATE_PRESSED;
  if (!pressed && event.button == 272) {
    if (const auto target = m_returnDrag.lock(); target && g_layoutManager->dragController()->target() == target)
      g_layoutManager->endDragTarget();
    m_returnDrag.reset();
  }
  if (pressed && !m_core.captured()) m_clickPending = true;
  if (!m_core.button(event.button, pressed)) {
    if (!pressed && g_pInputManager) {
      const auto position = g_pInputManager->getMouseCoordsInternal();
      observePointerPosition(position.x, position.y);
    }
    return;
  }
  const auto &lease = *m_core.lease();
  protocol::PacketBuilder payload{protocol::MessageType::INPUT_POINTER_BUTTON,
                                  0};
  payload.appendIntegral(lease.generation);
  appendTarget(payload, lease);
  payload.appendIntegral(m_eventSequence++);
  payload.appendIntegral(event.timeMs);
  payload.appendIntegral(event.button);
  payload.appendIntegral(static_cast<std::uint8_t>(pressed));
  if (!send(protocol::MessageType::INPUT_POINTER_BUTTON, payload))
    release(false);
}

void InputCapture::onPointerAxis(const IPointer::SAxisEvent &event) {
  if (!m_core.captured())
    return;
  const auto &lease = *m_core.lease();
  protocol::PacketBuilder payload{protocol::MessageType::INPUT_POINTER_AXIS, 0};
  payload.appendIntegral(lease.generation);
  appendTarget(payload, lease);
  payload.appendIntegral(m_eventSequence++);
  payload.appendIntegral(event.timeMs);
  payload.appendIntegral(static_cast<std::uint32_t>(event.source));
  payload.appendIntegral(static_cast<std::uint32_t>(event.axis));
  payload.appendIntegral(static_cast<std::uint32_t>(event.relativeDirection));
  payload.appendDouble(event.delta);
  payload.appendIntegral(event.deltaDiscrete);
  if (!send(protocol::MessageType::INPUT_POINTER_AXIS, payload))
    release(false);
}

bool InputCapture::remoteGesture() const {
  if (m_core.captured()) return true;
  // Pointer ownership, not keyboard focus: a pinch on an unfocused Windows
  // proxy still belongs to Windows. Native proxy surfaces have this app ID.
  const auto surface = g_pSeatManager ? g_pSeatManager->m_state.pointerFocus.lock() : nullptr;
  if (!surface) return false;
  return std::ranges::any_of(Desktop::windowState()->windows(), [&](const auto& window) {
    return window && window->m_class.starts_with("ViewflowReverse-") && window->resource() == surface;
  });
}

void InputCapture::drainTouchpad() {
  if (!m_touchpad) return;
  m_touchpad->drain(m_core.captured(), [this](const TouchpadSnapshot& frame) {
    if (!m_core.captured()) return;
    const auto& lease = *m_core.lease();
    protocol::PacketBuilder payload{protocol::MessageType::INPUT_TOUCHPAD_FRAME, 0};
    payload.appendIntegral(lease.generation);
    appendTarget(payload, lease);
    payload.appendIntegral(m_eventSequence++);
    payload.appendIntegral(frame.width);
    payload.appendIntegral(frame.height);
    payload.appendIntegral(frame.count);
    for (const auto& c : frame.contacts) {
      payload.appendIntegral(c.id); payload.appendIntegral(c.x); payload.appendIntegral(c.y);
    }
    if (!send(protocol::MessageType::INPUT_TOUCHPAD_FRAME, payload)) release(false);
    else ++m_touchpadFrames;
  });
}

void InputCapture::onPointerFrame() {
  drainTouchpad();
  if (!m_core.captured())
    return;
  const auto &lease = *m_core.lease();
  protocol::PacketBuilder payload{protocol::MessageType::INPUT_POINTER_FRAME,
                                  0};
  payload.appendIntegral(lease.generation);
  appendTarget(payload, lease);
  payload.appendIntegral(m_eventSequence++);
  if (!send(protocol::MessageType::INPUT_POINTER_FRAME, payload))
    release(false);
}

void InputCapture::onKey(const IKeyboard::SKeyEvent &event) {
  const bool pressed = event.state == WL_KEYBOARD_KEY_STATE_PRESSED;
  if (!m_core.key(event.keycode, pressed)) {
    if (!pressed && g_pInputManager) {
      const auto position = g_pInputManager->getMouseCoordsInternal();
      observePointerPosition(position.x, position.y);
    }
    return;
  }
  if (m_core.emergencyEscape()) {
    release(true);
    return;
  }
  const auto &lease = *m_core.lease();
  protocol::PacketBuilder payload{protocol::MessageType::INPUT_KEY, 0};
  payload.appendIntegral(lease.generation);
  appendTarget(payload, lease);
  payload.appendIntegral(m_eventSequence++);
  payload.appendIntegral(event.timeMs);
  payload.appendIntegral(event.keycode);
  payload.appendIntegral(static_cast<std::uint8_t>(pressed));
  payload.appendIntegral(static_cast<std::uint8_t>(event.updateMods));
  if (!send(protocol::MessageType::INPUT_KEY, payload))
    release(false);
}

void InputCapture::suppressKeyboard(KeyboardListeners &listeners) {
  if (listeners.dead)
    return;
  if (auto keyboard = listeners.keyboard.lock(); keyboard)
    listeners.enabledState.suppress(keyboard->m_enabled);
}

void InputCapture::suppressLocalKeyboards() {
  for (auto &[_, listeners] : m_keyboards)
    suppressKeyboard(*listeners);
}

void InputCapture::restoreLocalKeyboards() {
  for (auto &[_, listeners] : m_keyboards) {
    if (listeners->dead || !listeners->enabledState.active())
      continue;
    if (auto keyboard = listeners->keyboard.lock(); keyboard) {
      listeners->enabledState.restore(keyboard->m_enabled);
      if (listeners->physical && keyboard->m_enabled && g_pInputManager)
        g_pInputManager->onKeyboardMod(keyboard);
    }
  }
}

void InputCapture::release(bool notifyPeer) {
  const auto lease = m_core.lease();
  const auto edge = m_core.activeEdge();
  if (notifyPeer && lease && m_bridge.connected()) {
    protocol::PacketBuilder payload{protocol::MessageType::INPUT_RELEASE_ALL,
                                    0};
    payload.appendIntegral(lease->generation);
    appendTarget(payload, *lease);
    payload.appendIntegral(m_eventSequence++);
    (void)send(protocol::MessageType::INPUT_RELEASE_ALL, payload);
  }
  // Revoke reverse injection before restoring any physical input.
  if (m_loopback) m_windowPointer.cancel(WindowPointerRevocation::Cancelled);
  m_loopback = false;
  m_windowPointer.captureLoopback(false);
  const auto released = m_core.release();
  if (released.lease) m_lastReleasedGeneration = released.lease->generation;
  restoreLocalKeyboards();
  if (released.lease && edge)
    Pointer::mgr()->warpTo({edge->anchorX, edge->anchorY});
}

bool InputCapture::routeAllowed() const {
  return windowPointerRouteAllowed(m_core.phase()) || (m_core.captured() && m_loopback);
}

void InputCapture::receipt(std::uint64_t generation, protocol::MessageType command, bool applied) {
  protocol::PacketBuilder payload{protocol::MessageType::INPUT_CAPTURE_RECEIPT, 0};
  payload.appendIntegral(generation);
  payload.appendIntegral(command);
  payload.appendIntegral(static_cast<std::uint8_t>(applied));
  // Losing an activation receipt must never leave the seat captured.
  if (!send(protocol::MessageType::INPUT_CAPTURE_RECEIPT, payload))
    release(false);
}

bool InputCapture::send(protocol::MessageType type,
                        protocol::PacketBuilder &payload) {
  auto packet = payload.finish();
  return m_bridge.send(type, payloadOf(packet));
}

bool InputCapture::physicalKeyHeld() const {
  return g_pInputManager && std::ranges::any_of(g_pInputManager->getKeysFromAllKBs(), [&](uint32_t key) {
    return std::ranges::any_of(g_pInputManager->m_keyboards, [&](const auto& keyboard) {
      return keyboard && physical(*keyboard) && keyboard->m_enabled && keyboard->getPressed(key);
    });
  });
}

std::string InputCapture::captureStatusJson() const {
  std::ostringstream out;
  out << "{\"connected\":" << m_bridge.connected() << ",\"phase\":" << int(m_core.phase())
      << ",\"pointers\":" << m_pointers.size() << ",\"held_buttons\":" << (g_pInputManager && g_pInputManager->hasHeldButtons())
      << ",\"held_keys\":" << (g_pInputManager ? g_pInputManager->getKeysFromAllKBs().size() : 0)
      << ",\"raw_touchpad\":" << rawTouchpad() << ",\"touchpad_frames\":" << m_touchpadFrames
      << ",\"suppressed_gesture_events\":" << m_suppressedGestureEvents
      << ",\"local_gesture_events\":" << m_localGestureEvents
      << ",\"gesture_remote_now\":" << remoteGesture()
      << ",\"swipe_remote_latched\":" << m_swipeRoute.remoteStarted
      << ",\"pinch_remote_latched\":" << m_pinchRoute.remoteStarted
      << ",\"click_serial\":" << m_clickSerial << ",\"clicked_window\":" << m_clickedWindow
      << ",\"remote\":";
  if (const auto& r = m_core.remote()) out << "[" << r->monitorId << "," << r->x << "," << r->y << "," << r->width << "," << r->height << "]";
  else out << "null";
  out << ",\"keycodes\":[";
  if (g_pInputManager) { bool first = true; for (const auto key : g_pInputManager->getKeysFromAllKBs()) { if (!first) out << ","; first = false; out << key; } }
  out << "],\"physical_held_keys\":[";
  if (g_pInputManager) { bool first = true; for (const auto key : g_pInputManager->getKeysFromAllKBs()) {
    for (const auto& keyboard : g_pInputManager->m_keyboards) {
      if (!keyboard || !physical(*keyboard) || !keyboard->m_enabled || !keyboard->getPressed(key)) continue;
      if (!first) out << ","; first = false; out << key; break;
    }
  } }
  out << "]}";
  return out.str();
}

bool InputCapture::physical(IPointer &pointer) const {
  return !pointer.isVirtual() && !pointer.m_deviceTags.contains(INJECTED_TAG);
}

bool InputCapture::physical(IKeyboard &keyboard) const {
  return !keyboard.isVirtual() && !keyboard.m_deviceTags.contains(INJECTED_TAG);
}

} // namespace viewflow::hyprland

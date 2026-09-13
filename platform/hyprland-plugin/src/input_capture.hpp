// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "input_capture_core.hpp"
#include "touchpad_capture.hpp"
#include "gesture_route.hpp"
#include "metadata_bridge.hpp"
#include "window_pointer_controller.hpp"

#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/devices/IPointer.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>
#include <hyprland/src/layout/target/Target.hpp>

#include <chrono>
#include <cstdint>
#include <memory>
#include <unordered_map>

namespace viewflow::hyprland {

class InputCapture {
public:
  explicit InputCapture(MetadataBridge &bridge);
  ~InputCapture();

  InputCapture(const InputCapture &) = delete;
  InputCapture &operator=(const InputCapture &) = delete;

  void start();
  [[nodiscard]] std::string pointerTimingsJson() const { return m_windowPointer.timingsJson(); }
  bool suppressConvenienceMotion() const { return m_windowPointer.suppressConvenienceMotion(); }
  [[nodiscard]] std::string captureStatusJson() const;
  bool captured() const { return m_core.captured(); }
  bool forwardedMotion = false; // Synchronous compositor-thread cursor dispatch only.
  void forwardedButton(uint32_t code, bool down, uint32_t time);
  void forwardedAxis(uint32_t axis, double delta, int32_t discrete, uint32_t source, uint32_t time);

private:
  struct PointerListeners {
    bool dead = false;
    bool physical = false;
    CHyprSignalListener destroy;
    CHyprSignalListener motion;
    CHyprSignalListener button;
    CHyprSignalListener axis;
    CHyprSignalListener frame;
  };

  struct KeyboardListeners {
    bool dead = false;
    bool physical = false;
    WP<IKeyboard> keyboard;
    EnabledStateLease enabledState;
    CHyprSignalListener destroy;
    CHyprSignalListener key;
    CHyprSignalListener modifiers;
  };

  void tick(InputDispatchOrigin origin = InputDispatchOrigin::Tick);
  void reconcileDevices();
  void processCommands(std::uint64_t tickStarted, InputDispatchOrigin origin);
  void observePointerPosition(double x, double y);
  void onPointerMotion(const IPointer::SMotionEvent &event, bool external = false);
  void onPointerButton(const IPointer::SButtonEvent &event, bool external = false);
  void onPointerAxis(const IPointer::SAxisEvent &event);
  void onPointerFrame();
  void drainTouchpad();
  bool remoteGesture() const;
  enum class TouchpadMode : std::uint8_t { Derived = 0, QuicRaw = 1, ExternalNative = 2 };
  bool suppressesDerivedTouchpad() const {
    return m_touchpadMode != TouchpadMode::Derived && m_touchpad && m_touchpad->available();
  }
  bool rawTouchpad() const { return m_touchpadMode == TouchpadMode::QuicRaw && m_touchpad && m_touchpad->available(); }
  bool externalTouchpad() const { return m_touchpadMode == TouchpadMode::ExternalNative && m_touchpad && m_touchpad->available(); }
  void onKey(const IKeyboard::SKeyEvent &event);
  void suppressKeyboard(KeyboardListeners &listeners);
  void suppressLocalKeyboards();
  void restoreLocalKeyboards();
  void release(bool notifyPeer);
  [[nodiscard]] bool routeAllowed() const;
  void receipt(std::uint64_t generation, protocol::MessageType command, bool applied);
  [[nodiscard]] bool send(protocol::MessageType type,
                          protocol::PacketBuilder &payload);
  [[nodiscard]] bool physicalKeyHeld() const;
  [[nodiscard]] bool physical(IPointer &pointer) const;
  [[nodiscard]] bool physical(IKeyboard &keyboard) const;

  TouchpadMode m_touchpadMode{TouchpadMode::QuicRaw};
  bool m_buttonPhysical = true, m_axisPhysical = true, m_keyPhysical = true;
  uint64_t m_returnedButtons = 0;
  std::unique_ptr<TouchpadCapture> m_touchpad;
  IPointer* m_touchpadPointer{};
  std::uint64_t m_touchpadFrames{}, m_suppressedGestureEvents{}, m_localGestureEvents{};
  std::array<CHyprSignalListener, 6> m_gestures;
  GestureRoute m_swipeRoute, m_pinchRoute;
  bool m_cancelLocalGesture{};
  MetadataBridge &m_bridge;
  WindowPointerController m_windowPointer;
  InputCaptureCore m_core;
  std::uint64_t m_eventSequence = 1;
  bool m_loopback = false;
  bool m_clickPending = false;
  WP<Layout::ITarget> m_returnDrag;
  std::uint32_t m_clickSerial = 0;
  std::uintptr_t m_clickedWindow = 0;
  std::uint64_t m_lastReleasedGeneration = 0;
  std::uint64_t m_nativeConnection = 0;
  std::uint64_t m_previousDispatchStarted = 0, m_previousDispatchEnded = 0;
  std::chrono::steady_clock::time_point m_pendingSince{};
  std::unordered_map<IPointer *, std::unique_ptr<PointerListeners>> m_pointers;
  std::unordered_map<IKeyboard *, std::unique_ptr<KeyboardListeners>>
      m_keyboards;

  CHyprSignalListener m_tick;
  CHyprSignalListener m_mouseMove;
  CHyprSignalListener m_mouseButton;
  CHyprSignalListener m_mouseAxis;
  CHyprSignalListener m_keyboardKey;
};

} // namespace viewflow::hyprland

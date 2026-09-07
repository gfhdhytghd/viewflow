// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <xkbcommon/xkbcommon.h>

namespace viewflow::hyprland {

// Physical USB usages -> Linux evdev codes, not keysyms or Unicode. Unsupported
// usages have no fallback to an arbitrary evdev code or compositor shortcut.
std::optional<std::uint32_t> keyboardUsageToEvdev(std::uint16_t page, std::uint16_t usage);

struct WindowKeyboardModifiers {
  std::uint32_t depressed = 0, latched = 0, locked = 0, group = 0;
  bool operator==(const WindowKeyboardModifiers&) const = default;
};

struct WindowKeyboardTransition {
  std::uint32_t evdev = 0;
  // Wayland key state: 0 release, 1 press, 2 repeated. Sending 2 additionally
  // requires wl_keyboard >= 10; it must never be disguised as another down.
  std::uint32_t state = 0;
  WindowKeyboardModifiers modifiers;
};

// A private XKB state built from the SOURCE keyboard's keymap. This object never
// alters IKeyboard, global modifiers, keyboard LEDs or desktop input settings.
// It is not authorization, focus routing, native delivery or cleanup itself.
class WindowKeyboardState {
public:
  static std::unique_ptr<WindowKeyboardState> create(xkb_keymap* sourceKeymap,
      WindowKeyboardModifiers initial = {});
  WindowKeyboardState(const WindowKeyboardState&) = delete;
  WindowKeyboardState& operator=(const WindowKeyboardState&) = delete;

  // State is updated before dispatch so the native owner can retain exact
  // potentially-held recipients on uncertain delivery. Do not retry a failed
  // native dispatch: revoke the session and clean its original recipients.
  std::optional<WindowKeyboardTransition> transition(std::uint16_t page,
      std::uint16_t usage, std::uint32_t state, bool repeat);
  WindowKeyboardModifiers modifiers() const;
  bool matchesKeymap(xkb_keymap* keymap) const;
  const std::map<std::uint32_t, std::pair<std::uint16_t, std::uint16_t>>& pressed() const;

private:
  struct StateDeleter { void operator()(xkb_state* state) const { xkb_state_unref(state); } };
  explicit WindowKeyboardState(xkb_state* state) : m_state(state) {}
  std::unique_ptr<xkb_state, StateDeleter> m_state;
  // Index by native code, not usage: two distinct USB usages can alias one
  // evdev code and must not cause an early native key release.
  std::map<std::uint32_t, std::pair<std::uint16_t, std::uint16_t>> m_pressed;
};

} // namespace viewflow::hyprland

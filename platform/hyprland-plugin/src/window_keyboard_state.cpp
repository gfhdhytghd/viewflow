// SPDX-License-Identifier: GPL-3.0-only
#include "window_keyboard_state.hpp"
#include <array>
#include <linux/input-event-codes.h>

namespace viewflow::hyprland {

std::optional<std::uint32_t> keyboardUsageToEvdev(std::uint16_t page, std::uint16_t usage) {
  if (page == 0x0c) {
    switch (usage) {
    case 0xb0: return KEY_PLAY;
    case 0xb1: return KEY_PAUSE;
    case 0xb5: return KEY_NEXTSONG;
    case 0xb6: return KEY_PREVIOUSSONG;
    case 0xb7: return KEY_STOPCD;
    case 0xcd: return KEY_PLAYPAUSE;
    case 0xe2: return KEY_MUTE;
    case 0xe9: return KEY_VOLUMEUP;
    case 0xea: return KEY_VOLUMEDOWN;
    case 0x223: return KEY_HOMEPAGE;
    case 0x224: return KEY_BACK;
    case 0x225: return KEY_FORWARD;
    case 0x226: return KEY_STOP;
    case 0x227: return KEY_REFRESH;
    case 0x22a: return KEY_BOOKMARKS;
    default: return std::nullopt;
    }
  }
  if (page != 7) return std::nullopt;
  constexpr std::array<std::uint32_t, 26> letters{
    KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G, KEY_H, KEY_I, KEY_J,
    KEY_K, KEY_L, KEY_M, KEY_N, KEY_O, KEY_P, KEY_Q, KEY_R, KEY_S, KEY_T,
    KEY_U, KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z};
  constexpr std::array<std::uint32_t, 10> digits{
    KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0};
  constexpr std::array<std::uint32_t, 24> functions{
    KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10,
    KEY_F11, KEY_F12, KEY_F13, KEY_F14, KEY_F15, KEY_F16, KEY_F17, KEY_F18, KEY_F19,
    KEY_F20, KEY_F21, KEY_F22, KEY_F23, KEY_F24};
  if (usage >= 4 && usage <= 0x1d) return letters[usage - 4];
  if (usage >= 0x1e && usage <= 0x27) return digits[usage - 0x1e];
  if (usage >= 0x3a && usage <= 0x45) return functions[usage - 0x3a];
  if (usage >= 0x68 && usage <= 0x73) return functions[usage - 0x68 + 12];
  switch (usage) {
  case 0x28: return KEY_ENTER;
  case 0x29: return KEY_ESC;
  case 0x2a: return KEY_BACKSPACE;
  case 0x2b: return KEY_TAB;
  case 0x2c: return KEY_SPACE;
  case 0x2d: return KEY_MINUS;
  case 0x2e: return KEY_EQUAL;
  case 0x2f: return KEY_LEFTBRACE;
  case 0x30: return KEY_RIGHTBRACE;
  case 0x31: case 0x32: return KEY_BACKSLASH;
  case 0x33: return KEY_SEMICOLON;
  case 0x34: return KEY_APOSTROPHE;
  case 0x35: return KEY_GRAVE;
  case 0x36: return KEY_COMMA;
  case 0x37: return KEY_DOT;
  case 0x38: return KEY_SLASH;
  case 0x39: return KEY_CAPSLOCK;
  case 0x46: return KEY_SYSRQ;
  case 0x47: return KEY_SCROLLLOCK;
  case 0x48: return KEY_PAUSE;
  case 0x49: return KEY_INSERT;
  case 0x4a: return KEY_HOME;
  case 0x4b: return KEY_PAGEUP;
  case 0x4c: return KEY_DELETE;
  case 0x4d: return KEY_END;
  case 0x4e: return KEY_PAGEDOWN;
  case 0x4f: return KEY_RIGHT;
  case 0x50: return KEY_LEFT;
  case 0x51: return KEY_DOWN;
  case 0x52: return KEY_UP;
  case 0x53: return KEY_NUMLOCK;
  case 0x54: return KEY_KPSLASH;
  case 0x55: return KEY_KPASTERISK;
  case 0x56: return KEY_KPMINUS;
  case 0x57: return KEY_KPPLUS;
  case 0x58: return KEY_KPENTER;
  case 0x59: return KEY_KP1;
  case 0x5a: return KEY_KP2;
  case 0x5b: return KEY_KP3;
  case 0x5c: return KEY_KP4;
  case 0x5d: return KEY_KP5;
  case 0x5e: return KEY_KP6;
  case 0x5f: return KEY_KP7;
  case 0x60: return KEY_KP8;
  case 0x61: return KEY_KP9;
  case 0x62: return KEY_KP0;
  case 0x63: return KEY_KPDOT;
  case 0x64: return KEY_102ND;
  case 0x65: return KEY_COMPOSE;
  case 0x66: return KEY_POWER;
  case 0x67: return KEY_KPEQUAL;
  case 0x74: return KEY_OPEN;
  case 0x75: return KEY_HELP;
  case 0x76: return KEY_PROPS;
  case 0x77: return KEY_FRONT;
  case 0x78: return KEY_STOP;
  case 0x79: return KEY_AGAIN;
  case 0x7a: return KEY_UNDO;
  case 0x7b: return KEY_CUT;
  case 0x7c: return KEY_COPY;
  case 0x7d: return KEY_PASTE;
  case 0x7e: return KEY_FIND;
  case 0x7f: return KEY_MUTE;
  case 0x80: return KEY_VOLUMEUP;
  case 0x81: return KEY_VOLUMEDOWN;
  case 0x85: return KEY_KPCOMMA;
  case 0x87: return KEY_RO;
  case 0x88: return KEY_KATAKANAHIRAGANA;
  case 0x89: return KEY_YEN;
  case 0x8a: return KEY_HENKAN;
  case 0x8b: return KEY_MUHENKAN;
  case 0x8c: return KEY_KPJPCOMMA;
  case 0x90: return KEY_HANGEUL;
  case 0x91: return KEY_HANJA;
  case 0x92: return KEY_KATAKANA;
  case 0x93: return KEY_HIRAGANA;
  case 0x94: return KEY_ZENKAKUHANKAKU;
  case 0xe0: return KEY_LEFTCTRL;
  case 0xe1: return KEY_LEFTSHIFT;
  case 0xe2: return KEY_LEFTALT;
  case 0xe3: return KEY_LEFTMETA;
  case 0xe4: return KEY_RIGHTCTRL;
  case 0xe5: return KEY_RIGHTSHIFT;
  case 0xe6: return KEY_RIGHTALT;
  case 0xe7: return KEY_RIGHTMETA;
  default: return std::nullopt;
  }
}

std::unique_ptr<WindowKeyboardState> WindowKeyboardState::create(xkb_keymap* keymap,
    WindowKeyboardModifiers initial) {
  // Never import a locally held modifier/latched one-shot into remote input.
  if (!keymap || initial.depressed || initial.latched ||
      initial.group >= xkb_keymap_num_layouts(keymap)) return nullptr;
  const auto numMods = xkb_keymap_num_mods(keymap);
  if (numMods < 32 && (initial.locked >> numMods) != 0) return nullptr;
  auto* state = xkb_state_new(keymap);
  if (!state) return nullptr;
  std::unique_ptr<WindowKeyboardState> result(new WindowKeyboardState(state));
  xkb_state_update_mask(state, 0, 0, initial.locked, 0, 0, initial.group);
  return result;
}

WindowKeyboardModifiers WindowKeyboardState::modifiers() const {
  return {xkb_state_serialize_mods(m_state.get(), XKB_STATE_MODS_DEPRESSED),
      xkb_state_serialize_mods(m_state.get(), XKB_STATE_MODS_LATCHED),
      xkb_state_serialize_mods(m_state.get(), XKB_STATE_MODS_LOCKED),
      xkb_state_serialize_layout(m_state.get(), XKB_STATE_LAYOUT_EFFECTIVE)};
}

bool WindowKeyboardState::matchesKeymap(xkb_keymap* keymap) const {
  return keymap && xkb_state_get_keymap(m_state.get()) == keymap;
}

const std::map<std::uint32_t, std::pair<std::uint16_t, std::uint16_t>>& WindowKeyboardState::pressed() const {
  return m_pressed;
}

std::optional<WindowKeyboardTransition> WindowKeyboardState::transition(std::uint16_t page,
    std::uint16_t usage, std::uint32_t state, bool repeat) {
  if (state < 1 || state > 2 || (repeat && state != 1)) return std::nullopt;
  const auto code = keyboardUsageToEvdev(page, usage);
  if (!code || !xkb_keymap_key_get_name(xkb_state_get_keymap(m_state.get()), *code + 8))
    return std::nullopt;
  const auto identity = std::pair{page, usage};
  const auto held = m_pressed.find(*code);
  if (repeat) {
    if (held == m_pressed.end() || held->second != identity) return std::nullopt;
    return WindowKeyboardTransition{*code, 2, modifiers()};
  }
  if (state == 1) {
    if (held != m_pressed.end() || m_pressed.size() >= 256) return std::nullopt;
    m_pressed.emplace(*code, identity);
    xkb_state_update_key(m_state.get(), *code + 8, XKB_KEY_DOWN);
  } else {
    if (held == m_pressed.end() || held->second != identity) return std::nullopt;
    xkb_state_update_key(m_state.get(), *code + 8, XKB_KEY_UP);
    m_pressed.erase(held);
  }
  return WindowKeyboardTransition{*code, state == 1 ? 1U : 0U, modifiers()};
}

} // namespace viewflow::hyprland

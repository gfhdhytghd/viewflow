// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "viewflow_hyprland/protocol.hpp"
#include "window_wheel.hpp"
#include <bit>
#include <cmath>
#include <optional>

namespace viewflow::hyprland {

// Native IPC only. Deadlines use Linux CLOCK_MONOTONIC nanoseconds, NOT the
// remote peer's ProcessClock origin. The daemon must authorize/map first.
struct WindowPointerCommand {
  protocol::MessageType type;
  std::uint64_t generation = 0;
  std::uint64_t windowAddress = 0;
  std::uint64_t surfaceAddress = 0;
  std::uint32_t pid = 0;
  std::uint64_t deadlineNs = 0;
  double x = 0, y = 0; // begin: expected main surface extent; move: local point
  std::uint32_t button = 0, state = 0; // 1..5; 1 pressed / 2 released
  std::int32_t vertical120 = 0, horizontal120 = 0; // up/right, detent = 120
  std::uint16_t usagePage = 0, usageId = 0;
  bool repeat = false;
};

inline std::optional<WindowPointerCommand>
parseWindowPointerCommand(protocol::MessageType type,
                          std::span<const std::byte> bytes) {
  const bool begin = type == protocol::MessageType::WINDOW_POINTER_BEGIN ||
      type == protocol::MessageType::WINDOW_POINTER_BEGIN_BUTTONS ||
      type == protocol::MessageType::WINDOW_POINTER_BEGIN_BUTTONS_WHEEL ||
      type == protocol::MessageType::WINDOW_INPUT_BEGIN_DIRECT_KEYBOARD ||
      type == protocol::MessageType::WINDOW_INPUT_REBIND_RESIZED;
  const bool end = type == protocol::MessageType::WINDOW_POINTER_END ||
      type == protocol::MessageType::WINDOW_POINTER_END_PRESERVE_FOCUS;
  const std::size_t expected = begin ? 56 :
      type == protocol::MessageType::WINDOW_POINTER_MOVE ? 32 :
      type == protocol::MessageType::WINDOW_POINTER_BUTTON ? 40 :
      type == protocol::MessageType::WINDOW_POINTER_WHEEL ? 40 :
      type == protocol::MessageType::WINDOW_KEYBOARD_KEY ? 32 :
      end ? 8 : 0;
  if (expected == 0 || bytes.size() != expected)
    return std::nullopt;
  const auto u64 = [bytes](std::size_t offset) {
    std::uint64_t value = 0;
    for (std::size_t i = 0; i < 8; ++i)
      value |= std::uint64_t(std::to_integer<unsigned char>(bytes[offset + i])) << (8 * i);
    return value;
  };
  WindowPointerCommand result{.type = type, .generation = u64(0)};
  if (!result.generation)
    return std::nullopt;
  if (end)
    return result;
  if (type == protocol::MessageType::WINDOW_KEYBOARD_KEY) {
    result.deadlineNs = u64(8);
    const auto page = static_cast<std::uint32_t>(u64(16));
    const auto usage = static_cast<std::uint32_t>(u64(16) >> 32);
    result.state = static_cast<std::uint32_t>(u64(24));
    const auto repeat = static_cast<std::uint32_t>(u64(24) >> 32);
    if (!result.deadlineNs || !page || page > 0xffff || !usage || usage > 0xffff ||
        result.state < 1 || result.state > 2 || repeat > 1 || (repeat && result.state != 1)) return std::nullopt;
    result.usagePage = static_cast<std::uint16_t>(page);
    result.usageId = static_cast<std::uint16_t>(usage);
    result.repeat = repeat != 0;
    return result;
  }
  std::size_t offset = 8;
  if (begin) {
    result.windowAddress = u64(8);
    result.surfaceAddress = u64(48);
    const auto pid = u64(16); // high 32 bits reserved; PID must fit signed pid_t
    if (!result.windowAddress || !result.surfaceAddress || !pid || pid > 0x7fffffff)
      return std::nullopt;
    result.pid = static_cast<std::uint32_t>(pid);
    offset = 24;
  }
  result.deadlineNs = u64(offset);
  result.x = std::bit_cast<double>(u64(offset + 8));
  result.y = std::bit_cast<double>(u64(offset + 16));
  if (!result.deadlineNs || !std::isfinite(result.x) || !std::isfinite(result.y) ||
      result.x < 0 || result.y < 0)
    return std::nullopt;
  if (begin &&
      (result.x == 0 || result.y == 0))
    return std::nullopt;
  if (type == protocol::MessageType::WINDOW_POINTER_BUTTON) {
    const auto transition = u64(32);
    result.button = static_cast<std::uint32_t>(transition);
    result.state = static_cast<std::uint32_t>(transition >> 32);
    if (result.button < 1 || result.button > 5 || result.state < 1 || result.state > 2)
      return std::nullopt;
  }
  if (type == protocol::MessageType::WINDOW_POINTER_WHEEL) {
    const auto packed = u64(32);
    result.vertical120 = std::bit_cast<std::int32_t>(static_cast<std::uint32_t>(packed));
    result.horizontal120 = std::bit_cast<std::int32_t>(static_cast<std::uint32_t>(packed >> 32));
    if (!windowWheelAxes(result.vertical120, result.horizontal120)) return std::nullopt;
  }
  return result;
}

} // namespace viewflow::hyprland

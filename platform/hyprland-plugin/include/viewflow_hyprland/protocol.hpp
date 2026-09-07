// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <bit>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>
#include <stdexcept>
#include <string_view>
#include <type_traits>
#include <vector>

namespace viewflow::hyprland::protocol {

inline constexpr std::uint32_t MAGIC =
    0x59484656U; // "VFHY" in little-endian byte order.
inline constexpr std::uint16_t VERSION = 1;
inline constexpr std::size_t HEADER_SIZE = 20;
inline constexpr std::size_t MAX_PACKET_SIZE = 16 * 1024;
inline constexpr std::size_t MAX_TITLE_BYTES = 4096;
inline constexpr std::size_t MAX_CLASS_BYTES = 1024;
inline constexpr std::size_t MAX_NAME_BYTES = 256;
inline constexpr std::size_t MAX_DESCRIPTION_BYTES = 1024;

enum class MessageType : std::uint16_t {
  HELLO = 1,
  SNAPSHOT_BEGIN = 2,
  SNAPSHOT_END = 3,
  WINDOW_UPSERT = 10,
  WINDOW_REMOVE = 11,
  MONITOR_UPSERT = 20,
  MONITOR_REMOVE = 21,
  EDGE_CANDIDATE = 30,
  INPUT_RELATIVE_MOTION = 31,
  INPUT_POINTER_BUTTON = 32,
  INPUT_POINTER_AXIS = 33,
  INPUT_POINTER_FRAME = 34,
  INPUT_KEY = 35,
  INPUT_RELEASE_ALL = 36,
  INPUT_TOUCHPAD_FRAME = 37,
  INPUT_LEASE_ACTIVATE = 40,
  INPUT_LEASE_RELEASE = 41,
  INPUT_CAPTURE_TOPOLOGY = 42,
  INPUT_CAPTURE_RECEIPT = 43,
  WINDOW_POINTER_BEGIN = 50,
  WINDOW_POINTER_MOVE = 51,
  WINDOW_POINTER_END = 52,
  WINDOW_POINTER_RESULT = 53,
  WINDOW_POINTER_REVOKED = 54,
  WINDOW_POINTER_BUTTON = 55,
  WINDOW_POINTER_BEGIN_BUTTONS = 56,
  WINDOW_POINTER_WHEEL = 57,
  WINDOW_POINTER_BEGIN_BUTTONS_WHEEL = 58,
  WINDOW_INPUT_BEGIN_DIRECT_KEYBOARD = 59,
  WINDOW_KEYBOARD_KEY = 60,
  WINDOW_INPUT_REBIND_RESIZED = 61,
  WINDOW_POINTER_END_PRESERVE_FOCUS = 62,
};

enum class Edge : std::uint8_t {
  LEFT = 0,
  RIGHT = 1,
  TOP = 2,
  BOTTOM = 3,
};

enum WindowFlags : std::uint32_t {
  WINDOW_MAPPED = 1U << 0,
  WINDOW_FLOATING = 1U << 1,
  WINDOW_FULLSCREEN = 1U << 2,
  WINDOW_PINNED = 1U << 3,
  WINDOW_X11 = 1U << 4,
  WINDOW_TEXT_TRUNCATED = 1U << 31,
};

class PacketBuilder {
public:
  PacketBuilder(MessageType type, std::uint64_t sequence) {
    m_bytes.reserve(256);
    appendIntegral(MAGIC);
    appendIntegral(VERSION);
    appendIntegral(static_cast<std::uint16_t>(type));
    appendIntegral(std::uint32_t{0});
    appendIntegral(sequence);
  }

  template <typename T>
    requires((std::is_integral_v<T> &&
              !std::is_same_v<std::remove_cv_t<T>, bool>) ||
             std::is_enum_v<T>)
  void appendIntegral(T value) {
    if constexpr (std::is_enum_v<T>) {
      appendIntegral(static_cast<std::underlying_type_t<T>>(value));
    } else {
      using Unsigned = std::make_unsigned_t<T>;
      auto encoded = static_cast<Unsigned>(value);
      for (std::size_t i = 0; i < sizeof(Unsigned); ++i)
        appendByte(static_cast<std::uint8_t>((encoded >> (i * 8U)) & 0xffU));
    }
  }

  void appendFloat(float value) {
    appendIntegral(std::bit_cast<std::uint32_t>(value));
  }

  void appendDouble(double value) {
    appendIntegral(std::bit_cast<std::uint64_t>(value));
  }

  void appendString(std::string_view value, std::size_t maximum) {
    if (maximum > std::numeric_limits<std::uint16_t>::max())
      throw std::length_error("Viewflow protocol string limit exceeds uint16");

    const auto bounded = value.substr(0, maximum);
    appendIntegral(static_cast<std::uint16_t>(bounded.size()));
    appendBytes(std::as_bytes(std::span{bounded.data(), bounded.size()}));
  }

  [[nodiscard]] std::vector<std::byte> finish() {
    if (m_bytes.size() < HEADER_SIZE || m_bytes.size() > MAX_PACKET_SIZE)
      throw std::length_error(
          "Viewflow Hyprland packet is outside protocol bounds");

    const auto payloadSize =
        static_cast<std::uint32_t>(m_bytes.size() - HEADER_SIZE);
    for (std::size_t i = 0; i < sizeof(payloadSize); ++i)
      m_bytes[8 + i] =
          static_cast<std::byte>((payloadSize >> (i * 8U)) & 0xffU);

    return std::move(m_bytes);
  }

private:
  void appendByte(std::uint8_t value) {
    if (m_bytes.size() == MAX_PACKET_SIZE)
      throw std::length_error(
          "Viewflow Hyprland packet exceeds protocol bound");
    m_bytes.push_back(static_cast<std::byte>(value));
  }

  void appendBytes(std::span<const std::byte> bytes) {
    if (bytes.size() > MAX_PACKET_SIZE - m_bytes.size())
      throw std::length_error(
          "Viewflow Hyprland packet exceeds protocol bound");
    m_bytes.insert(m_bytes.end(), bytes.begin(), bytes.end());
  }

  std::vector<std::byte> m_bytes;
};

} // namespace viewflow::hyprland::protocol

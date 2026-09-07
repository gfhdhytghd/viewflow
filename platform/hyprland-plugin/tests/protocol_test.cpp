// SPDX-License-Identifier: GPL-3.0-only
#include "viewflow_hyprland/protocol.hpp"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>

using viewflow::hyprland::protocol::MessageType;
using viewflow::hyprland::protocol::PacketBuilder;

namespace {

std::uint32_t readU32(const std::vector<std::byte> &bytes, std::size_t offset) {
  std::uint32_t result = 0;
  for (std::size_t i = 0; i < 4; ++i)
    result |= static_cast<std::uint32_t>(
                  std::to_integer<std::uint8_t>(bytes.at(offset + i)))
              << (i * 8U);
  return result;
}

} // namespace

int main() {
  PacketBuilder builder{MessageType::WINDOW_REMOVE, 42};
  builder.appendIntegral(std::uint64_t{0x0102030405060708ULL});
  const auto packet = builder.finish();

  if (packet.size() != viewflow::hyprland::protocol::HEADER_SIZE + 8 ||
      readU32(packet, 0) != viewflow::hyprland::protocol::MAGIC ||
      readU32(packet, 8) != 8 ||
      std::to_integer<std::uint8_t>(packet[20]) != 0x08 ||
      std::to_integer<std::uint8_t>(packet[27]) != 0x01)
    return 1;

  bool rejected = false;
  try {
    PacketBuilder oversized{MessageType::HELLO, 1};
    oversized.appendString(
        std::string(viewflow::hyprland::protocol::MAX_PACKET_SIZE, 'x'),
        viewflow::hyprland::protocol::MAX_PACKET_SIZE);
    (void)oversized.finish();
  } catch (const std::length_error &) {
    rejected = true;
  }
  return rejected ? 0 : 2;
}

// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "viewflow_hyprland/protocol.hpp"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>
#include <vector>

namespace viewflow::hyprland {

struct ReceivedPacket {
  protocol::MessageType type;
  std::uint64_t sequence;
  std::vector<std::byte> payload;
};

class SocketSink {
public:
  SocketSink();
  ~SocketSink();

  SocketSink(const SocketSink &) = delete;
  SocketSink &operator=(const SocketSink &) = delete;

  [[nodiscard]] bool ensureConnected();
  [[nodiscard]] bool send(protocol::MessageType type,
                          std::span<const std::byte> payload);
  [[nodiscard]] std::optional<ReceivedPacket> receive();
  void disconnect() noexcept;
  [[nodiscard]] bool connected() const noexcept;
  // Borrowed descriptor, valid only for the current connection generation.
  [[nodiscard]] int nativeFd() const noexcept { return m_fd; }
  [[nodiscard]] std::uint64_t connectionGeneration() const noexcept;
  [[nodiscard]] const std::filesystem::path &socketPath() const noexcept;

private:
  std::filesystem::path m_socketPath;
  int m_fd = -1;
  std::uint64_t m_sequence = 1;
  std::uint64_t m_connectionGeneration = 0;
  std::uint64_t m_lastReceivedSequence = 0;
  std::chrono::steady_clock::time_point m_nextConnectAttempt{};
};

} // namespace viewflow::hyprland

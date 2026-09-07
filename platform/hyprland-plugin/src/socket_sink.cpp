// SPDX-License-Identifier: GPL-3.0-only
#include "socket_sink.hpp"

#include <array>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace viewflow::hyprland {
namespace {

constexpr auto CONNECT_RETRY_DELAY = std::chrono::milliseconds{250};

template <typename T>
T readIntegral(std::span<const std::byte> bytes, std::size_t offset) {
  using Unsigned = std::make_unsigned_t<T>;
  Unsigned value = 0;
  for (std::size_t i = 0; i < sizeof(Unsigned); ++i)
    value = static_cast<Unsigned>(
        value | static_cast<Unsigned>(
                    static_cast<Unsigned>(
                        std::to_integer<std::uint8_t>(bytes[offset + i]))
                    << (i * 8U)));
  return static_cast<T>(value);
}

std::filesystem::path resolveSocketPath() {
  if (const char *explicitPath = std::getenv("VIEWFLOW_HYPRLAND_SOCKET");
      explicitPath && *explicitPath)
    return explicitPath;
  if (const char *runtimeDir = std::getenv("XDG_RUNTIME_DIR");
      runtimeDir && *runtimeDir)
    return std::filesystem::path{runtimeDir} / "viewflow" / "hyprland.sock";
  return {};
}

} // namespace

SocketSink::SocketSink() : m_socketPath(resolveSocketPath()) {}

SocketSink::~SocketSink() { disconnect(); }

bool SocketSink::ensureConnected() {
  if (m_fd >= 0)
    return true;
  if (m_socketPath.empty() ||
      std::chrono::steady_clock::now() < m_nextConnectAttempt)
    return false;

  m_nextConnectAttempt = std::chrono::steady_clock::now() + CONNECT_RETRY_DELAY;

  const auto nativePath = m_socketPath.string();
  sockaddr_un address{};
  if (nativePath.size() >= sizeof(address.sun_path))
    return false;

  const int fd =
      ::socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (fd < 0)
    return false;

  address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, nativePath.c_str(), nativePath.size() + 1);
  const auto addressLength = static_cast<socklen_t>(
      offsetof(sockaddr_un, sun_path) + nativePath.size() + 1);
  if (::connect(fd, reinterpret_cast<const sockaddr *>(&address),
                addressLength) < 0) {
    ::close(fd);
    return false;
  }

  ucred peer{};
  socklen_t peerLength = sizeof(peer);
  if (::getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &peerLength) != 0 ||
      peerLength != sizeof(peer) || peer.uid != ::geteuid() || peer.pid <= 0) {
    ::close(fd);
    return false;
  }
  m_fd = fd;
  m_sequence = 1;
  m_lastReceivedSequence = 0;
  ++m_connectionGeneration;
  return true;
}

bool SocketSink::send(protocol::MessageType type,
                      std::span<const std::byte> payload) {
  if (!ensureConnected() ||
      payload.size() > protocol::MAX_PACKET_SIZE - protocol::HEADER_SIZE)
    return false;

  protocol::PacketBuilder packet{type, m_sequence++};
  for (const auto byte : payload)
    packet.appendIntegral(std::to_integer<std::uint8_t>(byte));
  auto bytes = packet.finish();

  const auto written =
      ::send(m_fd, bytes.data(), bytes.size(), MSG_DONTWAIT | MSG_NOSIGNAL);
  if (written == static_cast<ssize_t>(bytes.size()))
    return true;

  disconnect();
  return false;
}

std::optional<ReceivedPacket> SocketSink::receive() {
  if (m_fd < 0)
    return std::nullopt;

  std::array<std::byte, protocol::MAX_PACKET_SIZE> bytes{};
  const auto count = ::recv(m_fd, bytes.data(), bytes.size(), MSG_DONTWAIT);
  if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
    return std::nullopt;
  if (count <= 0) {
    disconnect();
    return std::nullopt;
  }

  const auto size = static_cast<std::size_t>(count);
  const auto packet = std::span{bytes}.first(size);
  if (size < protocol::HEADER_SIZE ||
      readIntegral<std::uint32_t>(packet, 0) != protocol::MAGIC ||
      readIntegral<std::uint16_t>(packet, 4) != protocol::VERSION ||
      readIntegral<std::uint32_t>(packet, 8) != size - protocol::HEADER_SIZE) {
    disconnect();
    return std::nullopt;
  }

  const auto sequence = readIntegral<std::uint64_t>(packet, 12);
  if (sequence == 0 || sequence <= m_lastReceivedSequence) {
    disconnect();
    return std::nullopt;
  }
  m_lastReceivedSequence = sequence;

  return ReceivedPacket{
      static_cast<protocol::MessageType>(
          readIntegral<std::uint16_t>(packet, 6)),
      sequence,
      std::vector<std::byte>(packet.begin() + protocol::HEADER_SIZE,
                             packet.end())};
}

std::uint64_t SocketSink::connectionGeneration() const noexcept {
  return m_connectionGeneration;
}

const std::filesystem::path &SocketSink::socketPath() const noexcept {
  return m_socketPath;
}

bool SocketSink::connected() const noexcept { return m_fd >= 0; }

void SocketSink::disconnect() noexcept {
  if (m_fd >= 0)
    ::close(m_fd);
  m_fd = -1;
}

} // namespace viewflow::hyprland

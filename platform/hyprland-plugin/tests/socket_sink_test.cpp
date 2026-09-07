// SPDX-License-Identifier: GPL-3.0-only
#include "socket_sink.hpp"

#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <filesystem>
#include <span>
#include <thread>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <wayland-server-core.h>

namespace {

std::uint32_t readU32(std::span<const std::byte> bytes, std::size_t offset) {
  std::uint32_t result = 0;
  for (std::size_t i = 0; i < 4; ++i)
    result |= static_cast<std::uint32_t>(
                  std::to_integer<std::uint8_t>(bytes[offset + i]))
              << (i * 8U);
  return result;
}

int fail(int listener, int peer, const std::filesystem::path &directory,
         int code) {
  if (peer >= 0)
    ::close(peer);
  if (listener >= 0)
    ::close(listener);
  std::filesystem::remove_all(directory);
  return code;
}

} // namespace

int main() {
  std::array<char, 40> directoryTemplate{};
  constexpr char PREFIX[] = "/tmp/viewflow-sink-test-XXXXXX";
  std::memcpy(directoryTemplate.data(), PREFIX, sizeof(PREFIX));
  const char *directoryName = ::mkdtemp(directoryTemplate.data());
  if (!directoryName)
    return 1;

  const std::filesystem::path directory{directoryName};
  const auto socketPath = directory / "bridge.sock";
  if (::setenv("VIEWFLOW_HYPRLAND_SOCKET", socketPath.c_str(), 1) != 0)
    return fail(-1, -1, directory, 2);

  const int listener = ::socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  if (listener < 0)
    return fail(-1, -1, directory, 3);

  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  const auto nativePath = socketPath.string();
  std::memcpy(address.sun_path, nativePath.c_str(), nativePath.size() + 1);
  const auto addressLength = static_cast<socklen_t>(
      offsetof(sockaddr_un, sun_path) + nativePath.size() + 1);
  if (::bind(listener, reinterpret_cast<const sockaddr *>(&address),
             addressLength) != 0) {
    std::perror("bind");
    return fail(listener, -1, directory, 4);
  }
  if (::listen(listener, 1) != 0) {
    std::perror("listen");
    return fail(listener, -1, directory, 4);
  }

  viewflow::hyprland::SocketSink sink;
  if (!sink.ensureConnected())
    return fail(listener, -1, directory, 5);

  const int peer = ::accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
  if (peer < 0)
    return fail(listener, -1, directory, 6);

  const std::array payload{std::byte{0xaa}, std::byte{0xbb}, std::byte{0xcc}};
  if (!sink.send(viewflow::hyprland::protocol::MessageType::WINDOW_REMOVE,
                 payload))
    return fail(listener, peer, directory, 7);

  std::array<std::byte, viewflow::hyprland::protocol::MAX_PACKET_SIZE>
      received{};
  const auto count = ::recv(peer, received.data(), received.size(), 0);
  const auto packet = std::span{received}.first(
      static_cast<std::size_t>(count < 0 ? 0 : count));
  if (count != static_cast<ssize_t>(viewflow::hyprland::protocol::HEADER_SIZE +
                                    payload.size()) ||
      readU32(packet, 0) != viewflow::hyprland::protocol::MAGIC ||
      readU32(packet, 8) != payload.size() ||
      !std::equal(payload.begin(), payload.end(),
                  packet.begin() + viewflow::hyprland::protocol::HEADER_SIZE))
    return fail(listener, peer, directory, 8);

  viewflow::hyprland::protocol::PacketBuilder command{
      viewflow::hyprland::protocol::MessageType::INPUT_LEASE_RELEASE, 1};
  command.appendIntegral(std::uint64_t{77});
  const auto commandBytes = command.finish();
  if (::send(peer, commandBytes.data(), commandBytes.size(), MSG_NOSIGNAL) !=
      static_cast<ssize_t>(commandBytes.size()))
    return fail(listener, peer, directory, 9);
  const auto incoming = sink.receive();
  if (!incoming ||
      incoming->type !=
          viewflow::hyprland::protocol::MessageType::INPUT_LEASE_RELEASE ||
      incoming->sequence != 1 || incoming->payload.size() != 8)
    return fail(listener, peer, directory, 10);

  // Exercise the actual Wayland readable source with no tick or watchdog.
  // Successive drain-to-EAGAIN cycles must preserve level-triggered wakeup.
  struct ReadState {
    viewflow::hyprland::SocketSink *sink;
    std::uint64_t sequence = 1;
    unsigned callbacks = 0;
    bool invalid = false;
  } state{&sink};
  auto *loop = wl_event_loop_create();
  if (!loop) return fail(listener, peer, directory, 13);
  auto *source = wl_event_loop_add_fd(loop, sink.nativeFd(), WL_EVENT_READABLE,
      [](int, std::uint32_t mask, void *data) -> int {
        auto &state = *static_cast<ReadState *>(data);
        ++state.callbacks;
        if (mask != WL_EVENT_READABLE) state.invalid = true;
        while (auto packet = state.sink->receive()) {
          if (packet->sequence != state.sequence + 1) state.invalid = true;
          state.sequence = packet->sequence;
        }
        return 0;
      }, &state);
  bool readableOk = source != nullptr;
  for (std::uint64_t sequence = 2; readableOk && sequence <= 257; ++sequence) {
    viewflow::hyprland::protocol::PacketBuilder next{
        viewflow::hyprland::protocol::MessageType::INPUT_LEASE_RELEASE, sequence};
    next.appendIntegral(std::uint64_t{77});
    const auto bytes = next.finish();
    readableOk = ::send(peer, bytes.data(), bytes.size(), MSG_NOSIGNAL) ==
        static_cast<ssize_t>(bytes.size());
    readableOk = readableOk && wl_event_loop_dispatch(loop, 25) == 0 &&
        !state.invalid && state.sequence == sequence && sink.connected();
  }
  readableOk = readableOk && state.callbacks == 256;
  // Also wake an idle blocking dispatch, rather than only reading packets
  // already queued before dispatch starts. The writer owns only the peer FD.
  for (std::uint64_t sequence = 258; readableOk && sequence <= 289; ++sequence) {
    viewflow::hyprland::protocol::PacketBuilder next{
        viewflow::hyprland::protocol::MessageType::INPUT_LEASE_RELEASE, sequence};
    next.appendIntegral(std::uint64_t{77});
    const auto bytes = next.finish();
    bool sent = false;
    std::thread writer([&] {
      std::this_thread::sleep_for(std::chrono::milliseconds{2});
      sent = ::send(peer, bytes.data(), bytes.size(), MSG_NOSIGNAL) ==
          static_cast<ssize_t>(bytes.size());
    });
    const auto dispatched = wl_event_loop_dispatch(loop, 1000);
    writer.join();
    readableOk = sent && dispatched == 0 && !state.invalid &&
        state.sequence == sequence && sink.connected();
  }
  readableOk = readableOk && state.callbacks == 288;
  if (source) wl_event_source_remove(source);
  wl_event_loop_destroy(loop);
  if (!readableOk) return fail(listener, peer, directory, 14);

  // A replayed daemon command tears down the local control connection.
  if (::send(peer, commandBytes.data(), commandBytes.size(), MSG_NOSIGNAL) !=
      static_cast<ssize_t>(commandBytes.size()))
    return fail(listener, peer, directory, 11);
  if (sink.receive().has_value() || sink.connected())
    return fail(listener, peer, directory, 12);

  return fail(listener, peer, directory, 0);
}

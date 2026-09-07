// SPDX-License-Identifier: GPL-3.0-only
#include "window_pointer_command.hpp"
#include "window_pointer_authority.hpp"
#include <cstdlib>
#include <limits>

using namespace viewflow::hyprland;
void require(bool value) { if (!value) std::abort(); }
int main() {
  WindowPointerAuthority authority;
  require(!authority.begin(0, true));
  require(authority.begin(1, true));
  require(!authority.begin(1, true));
  require(authority.begin(2, true)); // ordinary fresh renewal
  authority.revoke(); // local takeover, retirement, or expiry
  require(!authority.begin(3, true));
  require(!authority.begin(100, true));
  require(authority.generation() == 100);
  authority.rearmForCapture(); // Explicit completed physical capture, not BEGIN renewal.
  require(!authority.begin(100, true)); // Retains the denied generation floor.
  require(authority.begin(101, true));
  authority.revoke();
  require(!authority.begin(102, true));
  authority.reset(); // A new connection resets continuity
  require(!authority.begin(1, false));
  require(!authority.begin(1, true)); // denied generation was consumed
  require(authority.begin(2, true));
  require(authority.suspendForResize());
  require(authority.resizeSuspended());
  require(!authority.begin(3, true)); // renewal cannot leave suspension
  require(authority.resizeSuspended());
  require(!authority.rebind(3, true)); // denied generation cannot be replayed
  require(!authority.rebind(4, false));
  require(authority.resizeSuspended());
  require(!authority.rebind(4, true));
  require(authority.rebind(5, true));
  require(!authority.resizeSuspended());
  require(!authority.rebind(6, true)); // requires a new observed resize
  require(authority.begin(7, true));
  require(authority.suspendForResize());
  authority.revoke(); // terminal event while suspended
  require(!authority.resizeSuspended());
  require(!authority.suspendForResize());
  require(!authority.rebind(8, true));
  require(!authority.begin(9, true));
  authority.reset();
  require(!authority.suspendForResize());
  require(!authority.rebind(1, true)); // reconnect has no resize guard
  require(!authority.begin(1, true));
  require(authority.begin(2, true));
  authority.retireTarget();
  require(!authority.begin(3, true)); // No BEGIN can bypass explicit END.
  require(authority.end(authority.generation(), true));
  require(!authority.begin(3, true)); // Preserve the generation floor.
  require(authority.begin(4, true));
  authority.revoke(); // Capture rollback must not poison the connection.
  require(!authority.end(3, true)); // Wrong-generation cleanup is insufficient.
  require(!authority.end(4, false)); // Failed cleanup cannot re-open input.
  require(!authority.begin(5, true));
  require(authority.end(5, true));
  require(!authority.begin(5, true));
  require(authority.begin(6, true));
  require(authority.suspendForResize());
  require(authority.end(6, true));
  require(authority.begin(7, true));
  using protocol::MessageType;
  protocol::PacketBuilder packet{MessageType::WINDOW_POINTER_BEGIN, 1};
  for (auto value : {std::uint64_t{7}, std::uint64_t{0x1234}, std::uint64_t{123}, std::uint64_t{900}})
    packet.appendIntegral(value);
  packet.appendDouble(791);
  packet.appendDouble(598);
  packet.appendIntegral(std::uint64_t{0x5678});
  const auto encoded = packet.finish();
  const auto payload = std::span{encoded}.subspan(protocol::HEADER_SIZE);
  const auto good = parseWindowPointerCommand(MessageType::WINDOW_POINTER_BEGIN, payload);
  const auto buttonGrant = parseWindowPointerCommand(MessageType::WINDOW_POINTER_BEGIN_BUTTONS, payload);
  const auto wheelGrant = parseWindowPointerCommand(MessageType::WINDOW_POINTER_BEGIN_BUTTONS_WHEEL, payload);
  const auto keyGrant = parseWindowPointerCommand(MessageType::WINDOW_INPUT_BEGIN_DIRECT_KEYBOARD, payload);
  const auto rebind = parseWindowPointerCommand(MessageType::WINDOW_INPUT_REBIND_RESIZED, payload);
  require(rebind && rebind->generation == 7 && rebind->windowAddress == 0x1234 &&
      rebind->surfaceAddress == 0x5678 && rebind->pid == 123 && rebind->x == 791 && rebind->y == 598);
  for (std::size_t size = 0; size < payload.size(); ++size)
    require(!parseWindowPointerCommand(MessageType::WINDOW_INPUT_REBIND_RESIZED, payload.first(size)));
  require(keyGrant && keyGrant->surfaceAddress == 0x5678 && keyGrant->generation == 7);
  require(wheelGrant && wheelGrant->surfaceAddress == 0x5678 && wheelGrant->generation == 7);
  require(buttonGrant && buttonGrant->surfaceAddress == 0x5678 &&
      buttonGrant->type == MessageType::WINDOW_POINTER_BEGIN_BUTTONS);
  require(good && good->pid == 123 && good->generation == 7 && good->x == 791 && good->surfaceAddress == 0x5678);
  for (std::size_t size = 0; size < payload.size(); ++size)
    require(!parseWindowPointerCommand(MessageType::WINDOW_POINTER_BEGIN, payload.first(size)));
  for (const std::size_t offset : {0U, 8U, 16U, 24U, 32U, 40U, 48U}) {
    auto bad = std::vector<std::byte>{payload.begin(), payload.end()};
    for (std::size_t i = 0; i < 8; ++i) bad[offset + i] = std::byte{0};
    require(!parseWindowPointerCommand(MessageType::WINDOW_POINTER_BEGIN, bad));
    require(!parseWindowPointerCommand(MessageType::WINDOW_INPUT_REBIND_RESIZED, bad));
  }
  for (double badPoint : {-1.0, std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()}) {
    protocol::PacketBuilder move{MessageType::WINDOW_POINTER_MOVE, 2};
    move.appendIntegral(std::uint64_t{7}); move.appendIntegral(std::uint64_t{900});
    move.appendDouble(badPoint); move.appendDouble(0);
    auto bytes = move.finish();
    require(!parseWindowPointerCommand(MessageType::WINDOW_POINTER_MOVE, std::span{bytes}.subspan(protocol::HEADER_SIZE)));
  }
  require(!parseWindowPointerCommand(MessageType::INPUT_LEASE_RELEASE, payload.first(8)));
  require(parseWindowPointerCommand(MessageType::WINDOW_POINTER_END, payload.first(8)).has_value());
  const auto preserved = parseWindowPointerCommand(MessageType::WINDOW_POINTER_END_PRESERVE_FOCUS, payload.first(8));
  require(preserved && preserved->generation == 7 && preserved->type == MessageType::WINDOW_POINTER_END_PRESERVE_FOCUS);
  for (std::size_t size = 0; size < payload.size(); ++size)
    if (size != 8) require(!parseWindowPointerCommand(MessageType::WINDOW_POINTER_END_PRESERVE_FOCUS, payload.first(size)));
  std::array<std::byte, 8> zeroGeneration{};
  require(!parseWindowPointerCommand(MessageType::WINDOW_POINTER_END_PRESERVE_FOCUS, zeroGeneration));
  for (std::uint32_t page : {0U, 7U, 0xffffU, 0x10000U}) {
    for (std::uint32_t usage : {0U, 4U, 0xffffU, 0x10000U}) {
      for (std::uint32_t state = 0; state <= 3; ++state) {
        for (std::uint32_t repeat = 0; repeat <= 2; ++repeat) {
          protocol::PacketBuilder key{MessageType::WINDOW_KEYBOARD_KEY, 8};
          key.appendIntegral(std::uint64_t{7}); key.appendIntegral(std::uint64_t{900});
          key.appendIntegral(page); key.appendIntegral(usage);
          key.appendIntegral(state); key.appendIntegral(repeat);
          const auto bytes = key.finish();
          const auto data = std::span{bytes}.subspan(protocol::HEADER_SIZE);
          const auto parsed = parseWindowPointerCommand(MessageType::WINDOW_KEYBOARD_KEY, data);
          const bool valid = page && page <= 0xffff && usage && usage <= 0xffff &&
              state >= 1 && state <= 2 && repeat <= 1 && (!repeat || state == 1);
          require(bool(parsed) == valid);
          if (parsed) require(parsed->usagePage == page && parsed->usageId == usage &&
              parsed->state == state && parsed->repeat == (repeat != 0) && parsed->deadlineNs == 900);
          for (std::size_t length = 0; length < data.size(); ++length)
            require(!parseWindowPointerCommand(MessageType::WINDOW_KEYBOARD_KEY, data.first(length)));
          for (const std::size_t offset : {0U, 8U}) {
            auto bad = std::vector<std::byte>{data.begin(), data.end()};
            std::fill_n(bad.begin() + static_cast<std::ptrdiff_t>(offset), 8, std::byte{0});
            require(!parseWindowPointerCommand(MessageType::WINDOW_KEYBOARD_KEY, bad));
          }
        }
      }
    }
  }
  for (const auto delta : {std::array<std::int32_t, 2>{30, -60}, {0, 1}, {-120, 0},
                          {MAX_WHEEL_120, -MAX_WHEEL_120}, {0, 0}, {INT32_MIN, 0},
                          {0, INT32_MAX}, {MAX_WHEEL_120 + 1, 0}}) {
    protocol::PacketBuilder wheel{MessageType::WINDOW_POINTER_WHEEL, 4};
    wheel.appendIntegral(std::uint64_t{7}); wheel.appendIntegral(std::uint64_t{900});
    wheel.appendDouble(49); wheel.appendDouble(99);
    wheel.appendIntegral(delta[0]); wheel.appendIntegral(delta[1]);
    const auto bytes = wheel.finish();
    const auto data = std::span{bytes}.subspan(protocol::HEADER_SIZE);
    const auto axes = windowWheelAxes(delta[0], delta[1]);
    const auto parsed = parseWindowPointerCommand(MessageType::WINDOW_POINTER_WHEEL, data);
    require(bool(parsed) == bool(axes));
    if (parsed) {
      require(parsed->vertical120 == delta[0] && parsed->horizontal120 == delta[1]);
      require((*axes)[0].value120 == -delta[0] && (*axes)[1].value120 == delta[1]);
      require((*axes)[0].distance == -double(delta[0]) / 8.0 && (*axes)[1].distance == double(delta[1]) / 8.0);
    }
    for (std::size_t length = 0; length < data.size(); ++length)
      require(!parseWindowPointerCommand(MessageType::WINDOW_POINTER_WHEEL, data.first(length)));
    require(!parseWindowPointerCommand(MessageType::WINDOW_POINTER_MOVE, data));
  }
  for (std::uint32_t button = 0; button <= 6; ++button) {
    for (std::uint32_t state = 0; state <= 3; ++state) {
      protocol::PacketBuilder event{MessageType::WINDOW_POINTER_BUTTON, 3};
      event.appendIntegral(std::uint64_t{7}); event.appendIntegral(std::uint64_t{900});
      event.appendDouble(49); event.appendDouble(99);
      event.appendIntegral(button); event.appendIntegral(state);
      const auto bytes = event.finish();
      const auto data = std::span{bytes}.subspan(protocol::HEADER_SIZE);
      const auto decoded = parseWindowPointerCommand(MessageType::WINDOW_POINTER_BUTTON, data);
      const bool valid = button >= 1 && button <= 5 && state >= 1 && state <= 2;
      require(bool(decoded) == valid);
      if (valid) require(decoded->button == button && decoded->state == state && decoded->x == 49 && decoded->y == 99);
      for (std::size_t length = 0; length < data.size(); ++length)
        require(!parseWindowPointerCommand(MessageType::WINDOW_POINTER_BUTTON, data.first(length)));
      require(!parseWindowPointerCommand(MessageType::WINDOW_POINTER_MOVE, data));
    }
  }
}

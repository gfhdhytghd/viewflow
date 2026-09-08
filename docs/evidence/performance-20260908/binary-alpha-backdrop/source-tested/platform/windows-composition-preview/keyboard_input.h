#pragma once
#include <array>
#include <cstdint>
#include <optional>
#include "qpc_deadline.h"

namespace viewflow::windows_preview {
struct PhysicalKey { uint16_t page{}, usage{}; bool released{}, repeat{}; };

// Windows Scan 1 make codes, independent of destination text layout. The
// canonical 0x2b mapping is HID 0x31 (HID 0x32 has the same Windows scan code).
// E1 Pause and OEM/unlisted scan codes are rejected, never treated as VK/text.
inline uint16_t keyboard_usage(uint16_t scan) {
  constexpr std::array<uint8_t, 26> letters{0x1e,0x30,0x2e,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,0x32,0x31,0x18,0x19,0x10,0x13,0x1f,0x14,0x16,0x2f,0x11,0x2d,0x15,0x2c};
  for (uint16_t i=0; i<letters.size(); ++i) if (scan == letters[i]) return 4+i;
  if (scan >= 2 && scan <= 0x0b) return 0x1e + scan - 2;
  if (scan >= 0x3b && scan <= 0x44) return 0x3a + scan - 0x3b;
  if (scan >= 0x64 && scan <= 0x6e) return 0x68 + scan - 0x64;
  switch (scan) {
    case 0x1c:return 0x28; case 1:return 0x29; case 0x0e:return 0x2a; case 0x0f:return 0x2b;
    case 0x39:return 0x2c; case 0x0c:return 0x2d; case 0x0d:return 0x2e; case 0x1a:return 0x2f;
    case 0x1b:return 0x30; case 0x2b:return 0x31; case 0x27:return 0x33; case 0x28:return 0x34;
    case 0x29:return 0x35; case 0x33:return 0x36; case 0x34:return 0x37; case 0x35:return 0x38;
    case 0x3a:return 0x39; case 0x57:return 0x44; case 0x58:return 0x45;
    case 0xe037:return 0x46; case 0x46:return 0x47;
    case 0xe052:return 0x49; case 0xe047:return 0x4a; case 0xe049:return 0x4b; case 0xe053:return 0x4c;
    case 0xe04f:return 0x4d; case 0xe051:return 0x4e; case 0xe04d:return 0x4f; case 0xe04b:return 0x50;
    case 0xe050:return 0x51; case 0xe048:return 0x52; case 0xe045:return 0x53;
    case 0xe035:return 0x54; case 0x37:return 0x55; case 0x4a:return 0x56; case 0x4e:return 0x57;
    case 0xe01c:return 0x58; case 0x4f:return 0x59; case 0x50:return 0x5a; case 0x51:return 0x5b;
    case 0x4b:return 0x5c; case 0x4c:return 0x5d; case 0x4d:return 0x5e; case 0x47:return 0x5f;
    case 0x48:return 0x60; case 0x49:return 0x61; case 0x52:return 0x62; case 0x53:return 0x63;
    case 0x56:return 0x64; case 0xe05d:return 0x65; case 0x59:return 0x67; case 0x76:return 0x73;
    case 0x73:return 0x87; case 0x70:return 0x88; case 0x7d:return 0x89; case 0x79:return 0x8a;
    case 0x7b:return 0x8b; case 0x5c:return 0x8c;
    case 0x1d:return 0xe0; case 0x2a:return 0xe1; case 0x38:return 0xe2; case 0xe05b:return 0xe3;
    case 0xe01d:return 0xe4; case 0x36:return 0xe5; case 0xe038:return 0xe6; case 0xe05c:return 0xe7;
    default:return 0;
  }
}

inline std::optional<PhysicalKey> physical_key(uint32_t flags, bool released) {
  // A batched autorepeat has no individual original timestamps; do not expand.
  if ((flags & 0xffff) != 1 || bool(flags & 0x80000000u) != released) return std::nullopt;
  const bool previous = flags & 0x40000000u;
  if (released && !previous) return std::nullopt;
  const uint16_t scan = uint16_t((flags >> 16) & 0xff) | ((flags & 0x01000000u) ? 0xe000 : 0);
  const uint16_t usage = keyboard_usage(scan);
  if (!usage) return std::nullopt;
  return PhysicalKey{7, usage, released, !released && previous};
}

// GetMessageTime and GetTickCount share a wrapping 32-bit millisecond clock.
// QPC is sampled BEFORE tick_now. Caller supplies a conservative upper bound
// on tick quantization; this routine only subtracts budget, never refreshes it.
inline std::optional<uint64_t> keyboard_deadline(uint32_t message_ms, uint32_t tick_now,
    uint64_t qpc_before, uint64_t qpc_now, uint64_t frequency, uint32_t quantum_ms) {
  if (!qpc_before || qpc_now < qpc_before || quantum_ms < 1 || quantum_ms > 32) return std::nullopt;
  const uint64_t age_ms = uint32_t(tick_now - message_ms);
  const uint64_t upper_age_ns = (age_ms + quantum_ms) * 1'000'000;
  if (upper_age_ns >= 5'000'000'000) return std::nullopt;
  const auto result = qpc_deadline::deadline_from_sender_remaining(qpc_before, qpc_now, frequency, 5'000'000'000 - upper_age_ns);
  if (result.status != qpc_deadline::Status::Ok) return std::nullopt;
  return result.deadline_ticks;
}

class KeyboardHeldState {
 public:
  // Geometry cancellation does not prove remote cleanup. Keep the admitted
  // ledger intact while independently draining the physical keys that were
  // down at this boundary. No method here reauthorizes native input.
  void cancel_for_geometry() {
    if (cancelled_) return;
    cancelled_ = true;
    cancelled_physical_ = held_;
  }
  bool cancelled() const { return cancelled_; }
  void invalidate_cancelled() { cancelled_invalid_ = true; }
  bool cancelled_physical_drained() const {
    if (!cancelled_ || cancelled_invalid_) return false;
    for (bool down : cancelled_physical_) if (down) return false;
    return true;
  }
  bool observe_cancelled(PhysicalKey key, uint8_t native_modifiers, bool allow_new_down = false) {
    if (!cancelled_ || cancelled_invalid_) return false;
    if (key.page != 7 || !key.usage || key.usage >= cancelled_physical_.size() ||
        (key.released ? (!cancelled_physical_[key.usage] || key.repeat) :
         (key.repeat != cancelled_physical_[key.usage] || (!cancelled_physical_[key.usage] && !allow_new_down)))) {
      cancelled_invalid_ = true;
      return false;
    }
    uint8_t expected{};
    for (unsigned i = 0; i < 8; ++i)
      if (cancelled_physical_[0xe0 + i]) expected |= uint8_t(1u << i);
    if (key.usage >= 0xe0 && key.usage <= 0xe7) {
      const auto bit = uint8_t(1u << (key.usage - 0xe0));
      expected = key.released ? uint8_t(expected & ~bit) : uint8_t(expected | bit);
    }
    if (expected != native_modifiers) {
      cancelled_invalid_ = true;
      return false;
    }
    cancelled_physical_[key.usage] = !key.released;
    return true;
  }
  bool any() const { for (bool down: held_) if (down) return true; return false; }
  bool only_win_modifiers() const {
    if (cancelled_) return false;
    bool found = false;
    for (size_t i = 0; i < held_.size(); ++i) {
      if (!held_[i]) continue;
      if (i != 0xe3 && i != 0xe7) return false;
      found = true;
    }
    return found;
  }
  bool only_move_modifiers() const {
    if (cancelled_) return false;
    for (size_t i = 0; i < held_.size(); ++i)
      if (held_[i] && i != 0xe1 && i != 0xe3 && i != 0xe5 && i != 0xe7) return false;
    return true;
  }
  uint8_t physical_modifiers() const {
    if (!cancelled_) return modifiers();
    uint8_t result{};
    for (unsigned i = 0; i < 8; ++i)
      if (cancelled_physical_[0xe0 + i]) result |= uint8_t(1u << i);
    return result;
  }
  uint8_t modifiers() const {
    uint8_t result{};
    for (unsigned i=0; i<8; ++i) if (held_[0xe0+i]) result |= uint8_t(1u << i);
    return result;
  }
  bool admit(PhysicalKey key, uint8_t native_modifiers) {
    if (cancelled_) return false;
    if (key.page != 7 || key.usage >= held_.size() || !key.usage) return false;
    const bool down = held_[key.usage];
    if (key.released ? (!down || key.repeat) : (key.repeat != down)) return false;
    auto expected = modifiers();
    if (key.usage >= 0xe0 && key.usage <= 0xe7) {
      const auto bit = uint8_t(1u << (key.usage - 0xe0));
      expected = key.released ? uint8_t(expected & ~bit) : uint8_t(expected | bit);
    }
    if (expected != native_modifiers) return false;
    held_[key.usage] = !key.released;
    return true;
  }
 private:
  friend class AtlasPointerState;
  // Physical drain alone is never sufficient; the atlas owner must validate
  // the source-confirmed recovery record before using this operation.
  void finish_confirmed_geometry_recovery() {
    held_.fill(false);
    cancelled_physical_.fill(false);
    cancelled_ = false;
    cancelled_invalid_ = false;
  }
  std::array<bool, 256> held_{};
  std::array<bool, 256> cancelled_physical_{};
  bool cancelled_{};
  bool cancelled_invalid_{};
};
} // namespace viewflow::windows_preview

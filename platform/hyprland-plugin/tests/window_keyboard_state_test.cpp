// SPDX-License-Identifier: GPL-3.0-only
#include "window_keyboard_state.hpp"
#include "window_keyboard_route.hpp"
#include "window_keyboard_admission.hpp"
#include <array>
#include <cstdlib>
#include <iostream>
#include <linux/input-event-codes.h>
#include <memory>

using namespace viewflow::hyprland;
static void check(bool condition, const char* message) {
  if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}

struct ContextDeleter { void operator()(xkb_context* value) const { xkb_context_unref(value); } };
struct KeymapDeleter { void operator()(xkb_keymap* value) const { xkb_keymap_unref(value); } };
struct StateDeleter { void operator()(xkb_state* value) const { xkb_state_unref(value); } };

int main() {
  int imeClient, foreignClient;
  check(compatibleImeSeatKeyboard(true, true, &imeClient, &imeClient), "registered IME seat remains compatible after text input deactivation");
  check(!compatibleImeSeatKeyboard(true, true, &foreignClient, &imeClient), "foreign virtual keyboard rejected");
  check(!compatibleImeSeatKeyboard(true, false, &imeClient, &imeClient), "destroyed registered IME rejected");
  check(!compatibleImeSeatKeyboard(false, true, &imeClient, &imeClient), "physical replacement cannot use IME exception");
  check(!compatibleImeSeatKeyboard(true, true, nullptr, nullptr), "missing owner never establishes compatibility");
  constexpr auto seatOnly = 1U << 16U;
  check(mayDeferEmptySeatFocus(true, false, seatOnly, true, true), "resendEnter null notification can defer once");
  check(restoredSeatFocus(0, true, true), "same exact binding restored synchronously survives");
  check(!restoredSeatFocus(seatOnly, true, true), "persistent null at idle revokes instead of deferring again");
  check(!mayDeferEmptySeatFocus(true, true, seatOnly, true, true), "non-null different seat focus revokes immediately");
  check(!mayDeferEmptySeatFocus(true, false, seatOnly | (1U << 17U), true, true), "desktop focus loss cannot defer");
  check(!mayDeferEmptySeatFocus(true, false, seatOnly | (1U << 12U), true, true), "missing target cannot defer");
  check(!mayDeferEmptySeatFocus(true, false, seatOnly, true, false), "expired lease cannot defer");
  check(!mayDeferEmptySeatFocus(false, false, seatOnly, true, true), "admission does not acquire transient exception");
  check(!restoredSeatFocus(0, false, true), "restoration without route cannot resume");
  check(!restoredSeatFocus(0, true, false), "restoration after expiry cannot resume");
  check(keyboardRouteFailure(true,true,true,true,false) == KeyboardRouteFailure::None, "complete direct keyboard route");
  check(keyboardRouteFailure(false,true,true,true,false) == KeyboardRouteFailure::SeatManagerMissing, "missing seat manager");
  check(keyboardRouteFailure(true,false,true,true,false) == KeyboardRouteFailure::InputManagerMissing, "missing input manager");
  check(keyboardRouteFailure(true,true,false,true,false) == KeyboardRouteFailure::SeatProtocolMissing, "missing seat protocol");
  check(keyboardRouteFailure(true,true,true,false,false) == KeyboardRouteFailure::KeyboardCapabilityMissing, "missing keyboard capability");
  check(keyboardRouteFailure(true,true,true,true,true) == KeyboardRouteFailure::InputMethodGrab, "active IME never bypassed by direct send");

  check(!keyboardAdmissionCandidateReady(true, true, true), "new BEGIN never binds transient IME virtual keyboard");
  check(!keyboardAdmissionCandidateReady(false, false, true), "missing replacement keyboard remains unready");
  check(keyboardAdmissionCandidateReady(true, false, true), "real keyboard may proceed to permission checks");
  check(keyboardAdmissionCandidateReady(true, true, false), "legacy immediate rebind selection is unchanged");
  check(keyboardRouteMayStartAdmission(KeyboardRouteFailure::InputMethodGrab, true), "explicit new BEGIN can wait for grab release");
  check(!keyboardRouteMayStartAdmission(KeyboardRouteFailure::InputMethodGrab, false), "resize rebind cannot silently opt into focus admission");
  check(!keyboardRouteMayStartAdmission(KeyboardRouteFailure::KeyboardCapabilityMissing, true), "admission cannot wait through missing capability");
  {
    using Gate = KeyboardAdmissionGate;
    using namespace std::chrono_literals;
    const auto start = Gate::Clock::time_point{} + 1s;
    Gate admission(start, start + 5s);
    check(admission.deadline() == start + 20ms, "IME wait has bounded original deadline");
    check(admission.observe(start, true, true) == Gate::Phase::Waiting, "focus alone never grants application input");
    check(admission.observe(start + 19ms, true, true) == Gate::Phase::Waiting, "live grab never bypassed");
    check(admission.deadline() == start + 20ms, "polling cannot extend admission");
    check(admission.observe(start + 19ms, true, false) == Gate::Phase::Ready, "actual grab release admits exact target");
    Gate replacement(start, start + 5s);
    check(replacement.observe(start + 1ms, true, true, false) == Gate::Phase::Waiting, "old IME keyboard not bound while grabbed");
    check(replacement.observe(start + 2ms, true, false, false) == Gate::Phase::Waiting, "grab release before virtual keyboard destruction is not ready");
    check(replacement.observe(start + 3ms, true, false, true) == Gate::Phase::Ready, "bind real permitted keyboard only after replacement");
    const auto seatMismatch = 1U << 14U;
    check(keyboardAdmissionWaitsForForeignVirtual(seatMismatch, true, true, false), "foreign virtual seat retirement can wait");
    check(!keyboardAdmissionWaitsForForeignVirtual(seatMismatch, false, true, false), "immediate rebind cannot wait for virtual retirement");
    check(!keyboardAdmissionWaitsForForeignVirtual(seatMismatch, true, false, false), "physical replacement remains an identity failure");
    check(!keyboardAdmissionWaitsForForeignVirtual(seatMismatch, true, true, true), "trusted IME seat is not a foreign retirement");
    for (auto otherFailure : {1U << 9U, 1U << 10U, 1U << 12U, 1U << 15U, 1U << 16U, 1U << 17U})
      check(!keyboardAdmissionWaitsForForeignVirtual(seatMismatch | otherFailure, true, true, false), "seat retirement cannot mask another binding failure");
    Gate retiring(start, start + 5s);
    const bool waitForRetirement = keyboardAdmissionWaitsForForeignVirtual(seatMismatch, true, true, false);
    check(retiring.observe(start + 2ms, waitForRetirement, false, !waitForRetirement) == Gate::Phase::Waiting, "grab gone with old virtual seat stays pending");
    check(retiring.deadline() == start + 20ms, "virtual retirement cannot renew deadline");
    check(retiring.observe(start + 20ms, true, false, false) == Gate::Phase::Rejected, "virtual retirement unresolved at original deadline rejects");
    check(retiring.observe(start + 21ms, true, false, true) == Gate::Phase::Rejected, "late virtual destruction cannot revive BEGIN");
    Gate late(start, start + 5s);
    check(late.observe(start + 20ms, true, false) == Gate::Phase::Rejected, "release at deadline is not admission");
    check(late.observe(start + 21ms, true, false) == Gate::Phase::Rejected, "rejected admission cannot replay");
    Gate shortLease(start, start + 3ms);
    check(shortLease.deadline() == start + 3ms, "admission never extends original lease");
    check(shortLease.observe(start + 3ms, true, false) == Gate::Phase::Rejected, "original lease expiry fences admission");
    Gate changed(start, start + 5s);
    check(changed.observe(start + 1ms, false, false) == Gate::Phase::Rejected, "focus or target change rejects even after grab release");
    Gate cancelled(start, start + 5s);
    cancelled.reject();
    check(cancelled.observe(start + 1ms, true, false) == Gate::Phase::Rejected, "cancelled admission cannot rearm");
  }
  check(keyboardUsageToEvdev(7, 4) == KEY_A, "A is physical evdev, not ASCII");
  check(keyboardUsageToEvdev(7, 0x1d) == KEY_Z, "Z mapping");
  check(keyboardUsageToEvdev(7, 0x27) == KEY_0, "zero mapping");
  check(keyboardUsageToEvdev(7, 0x45) == KEY_F12, "F12 mapping");
  check(keyboardUsageToEvdev(7, 0x68) == KEY_F13, "F13 mapping");
  check(keyboardUsageToEvdev(7, 0x73) == KEY_F24, "F24 mapping");
  check(keyboardUsageToEvdev(7, 0x48) == KEY_PAUSE, "Pause is not Ctrl or NumLock");
  check(keyboardUsageToEvdev(7, 0x58) == KEY_KPENTER, "keypad enter differs from enter");
  check(keyboardUsageToEvdev(7, 0x64) == KEY_102ND, "ISO extra physical key");
  check(keyboardUsageToEvdev(7, 0x89) == KEY_YEN, "JIS Yen physical key");
  check(keyboardUsageToEvdev(0xc, 0xe9) == KEY_VOLUMEUP, "consumer page volume up");
  constexpr std::array<std::uint32_t, 8> modifiers{KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_LEFTALT,
    KEY_LEFTMETA, KEY_RIGHTCTRL, KEY_RIGHTSHIFT, KEY_RIGHTALT, KEY_RIGHTMETA};
  for (std::uint16_t i = 0; i < modifiers.size(); ++i)
    check(keyboardUsageToEvdev(7, static_cast<std::uint16_t>(0xe0 + i)) == modifiers[i], "modifier physical side");
  for (std::uint16_t page : std::array<std::uint16_t, 3>{0, 1, 0xffff})
    for (std::uint16_t key : std::array<std::uint16_t, 4>{0, 4, 0xe9, 0xffff})
      check(!keyboardUsageToEvdev(page, key), "unsupported page has no fallback");
  for (std::uint16_t key : std::array<std::uint16_t, 6>{0, 1, 2, 3, 0x82, 0xffff})
    check(!keyboardUsageToEvdev(7, key), "reserved/error usages have no mapping");

  std::unique_ptr<xkb_context, ContextDeleter> context(xkb_context_new(XKB_CONTEXT_NO_FLAGS));
  check(bool(context), "XKB context");
  xkb_rule_names rules{}; rules.layout = "us";
  std::unique_ptr<xkb_keymap, KeymapDeleter> keymap(xkb_keymap_new_from_names(context.get(), &rules, XKB_KEYMAP_COMPILE_NO_FLAGS));
  check(bool(keymap), "US source keymap");
  auto keys = WindowKeyboardState::create(keymap.get());
  check(bool(keys) && keys->matchesKeymap(keymap.get()), "source keymap retained");
  check(!WindowKeyboardState::create(nullptr), "missing keymap");
  check(!WindowKeyboardState::create(keymap.get(), {1, 0, 0, 0}), "do not import local held modifiers");
  check(!WindowKeyboardState::create(keymap.get(), {0, 1, 0, 0}), "do not import local latched modifiers");
  check(!WindowKeyboardState::create(keymap.get(), {0, 0, 0, 1}), "reject nonexistent group");
  check(!WindowKeyboardState::create(keymap.get(), {0, 0, 0x80000000U, 0}), "reject unknown locked modifier bit");
  const auto shiftIndex = xkb_keymap_mod_get_index(keymap.get(), "Shift");
  const auto shiftMask = std::uint32_t{1} << shiftIndex;
  check(!keys->transition(7, 4, 2, false), "orphan up");
  check(!keys->transition(7, 4, 1, true), "orphan repeat");
  check(!keys->transition(7, 4, 0, false), "invalid transition");
  check(!keys->transition(7, 4, 2, true), "repeat cannot release");
  check(bool(keys->transition(7, 0xe1, 1, false)), "left shift down");
  check((keys->modifiers().depressed & shiftMask) != 0, "left shift modifies private state");
  check(bool(keys->transition(7, 0xe5, 1, false)), "right shift down");
  check(bool(keys->transition(7, 0xe1, 2, false)), "left shift up");
  check((keys->modifiers().depressed & shiftMask) != 0, "right shift remains held");
  const auto down = keys->transition(7, 4, 1, false);
  check(down && down->evdev == KEY_A && down->state == 1, "physical key down");
  check(!keys->transition(7, 4, 1, false), "duplicate ordinary down");
  const auto before = keys->modifiers();
  const auto repeat = keys->transition(7, 4, 1, true);
  check(repeat && repeat->state == 2 && repeat->modifiers == before, "repeat preserves modifier state");
  check(bool(keys->transition(7, 4, 2, false)), "A up");
  check(bool(keys->transition(7, 0xe5, 2, false)), "right shift up");
  check(keys->modifiers().depressed == 0 && keys->pressed().empty(), "balanced keys empty");

  check(bool(keys->transition(7, 0x31, 1, false)), "backslash down");
  check(!keys->transition(7, 0x32, 1, false), "reject alias double-down");
  check(!keys->transition(7, 0x32, 2, false), "alias cannot release original usage");
  check(bool(keys->transition(7, 0x31, 2, false)), "original backslash up");

  const auto capsMask = std::uint32_t{1} << xkb_keymap_mod_get_index(keymap.get(), "Lock");
  check(bool(keys->transition(7, 0x39, 1, false)), "caps down");
  check(bool(keys->transition(7, 0x39, 2, false)), "caps up");
  check((keys->modifiers().locked & capsMask) != 0, "source-side lock state");
  auto independent = WindowKeyboardState::create(keymap.get());
  check(independent->modifiers().locked == 0, "remote lock did not mutate keymap/global state");
  auto importedLock = WindowKeyboardState::create(keymap.get(), {0, 0, capsMask, 0});
  check(importedLock && (importedLock->modifiers().locked & capsMask) != 0, "explicit source lock snapshot preserved");

  rules.layout = "de";
  std::unique_ptr<xkb_keymap, KeymapDeleter> germanMap(xkb_keymap_new_from_names(context.get(), &rules, XKB_KEYMAP_COMPILE_NO_FLAGS));
  auto german = WindowKeyboardState::create(germanMap.get());
  check(bool(german), "German source map");
  check(!keys->matchesKeymap(germanMap.get()), "source keymap replacement is observable");
  check(bool(german->transition(7, 0xe6, 1, false)), "German AltGr down");
  const auto q = german->transition(7, 0x14, 1, false);
  check(q && q->evdev == KEY_Q, "Q keeps physical identity across source layouts");
  std::unique_ptr<xkb_state, StateDeleter> client(xkb_state_new(germanMap.get()));
  check(bool(client), "source application XKB state fixture");
  xkb_state_update_mask(client.get(), q->modifiers.depressed, q->modifiers.latched,
      q->modifiers.locked, 0, 0, q->modifiers.group);
  check(xkb_state_key_get_utf32(client.get(), KEY_Q + 8) == '@', "source layout resolves AltGr-Q");
  check(bool(german->transition(7, 0x14, 2, false)), "German Q up");
  check(bool(german->transition(7, 0xe6, 2, false)), "German AltGr up");
  check(german->pressed().empty() && german->modifiers().depressed == 0, "German state balanced");

  rules.layout = "us,de";
  std::unique_ptr<xkb_keymap, KeymapDeleter> multiMap(xkb_keymap_new_from_names(context.get(), &rules, XKB_KEYMAP_COMPILE_NO_FLAGS));
  auto secondLayout = WindowKeyboardState::create(multiMap.get(), {0, 0, 0, 1});
  check(secondLayout && secondLayout->modifiers().group == 1, "source active layout group preserved");
  const auto physicalY = secondLayout->transition(7, 0x1c, 1, false);
  check(physicalY && physicalY->evdev == KEY_Y && physicalY->modifiers.group == 1, "physical Y keeps source layout group");
  std::unique_ptr<xkb_state, StateDeleter> multiClient(xkb_state_new(multiMap.get()));
  check(bool(multiClient), "multiple layout client state");
  xkb_state_update_mask(multiClient.get(), physicalY->modifiers.depressed, physicalY->modifiers.latched,
      physicalY->modifiers.locked, 0, 0, physicalY->modifiers.group);
  check(xkb_state_key_get_utf32(multiClient.get(), KEY_Y + 8) == 'z', "source German group resolves Y position as z");
  check(bool(secondLayout->transition(7, 0x1c, 2, false)), "multiple layout key up");
  std::cout << "window keyboard physical mapping and isolated XKB tests passed\n";
}

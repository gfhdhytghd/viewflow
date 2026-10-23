#include "desktop_move_gesture.h"
#include "keyboard_input.h"
#include <cassert>

using namespace viewflow;
void test_source_win_keys() {
  using Keys = windows_preview::DesktopSourceWinKeys;
  using Action = Keys::Action;
  using windows_preview::KeyboardHeldState;
  for (const uint8_t bit : {uint8_t(8), uint8_t(128)}) {
    const uint16_t usage = bit == 8 ? 0xe3 : 0xe7;
    Keys keys;
    KeyboardHeldState held;
    // Win is forwarded immediately, before any second key or mouse decision.
    assert(keys.event(bit, true, true) == Action::Forward);
    assert(held.admit({7,usage,false,false},bit));
    assert(held.only_win_modifiers());
    assert(held.admit({7,0x2c,false,false},bit)); // Space sees source Win held.
    assert(!held.only_win_modifiers());
    assert(held.admit({7,0x2c,true,false},bit));
    assert(keys.event(bit,false,true) == Action::Forward);
    assert(held.admit({7,usage,true,false},0) && !held.any());

    assert(keys.event(bit,true,true) == Action::Forward);
    assert(held.admit({7,usage,false,false},bit));
    assert(held.only_win_modifiers());
    // A mouse-down causes a distinct source cleanup up before native Begin;
    // the receiver's existing FIFO/ACK gate then fences Begin until confirmed.
    assert(held.admit({7,usage,true,false},0));
    keys.consume_for_move_or_owner_loss();
    assert(!held.any() && keys.physical() == bit);
    assert(keys.event(bit,true,true) == Action::Suppress);
    assert(keys.event(bit,false,true) == Action::Suppress && !keys.physical());
    assert(!held.admit({7,usage,true,false},0)); // No duplicate physical up.

    assert(keys.event(bit,true,true) == Action::Forward);
    keys.consume_for_move_or_owner_loss();
    assert(keys.event(bit,false,false) == Action::Suppress); // Never replay on focus loss.
  }
  // Hook timestamps retain the original Win-down deadline even if UI delivery
  // is delayed. A later Space cannot give that old press a fresh timestamp.
  assert(windows_preview::keyboard_deadline(10,100,1000,1001,1000,20) == 5890);
  assert(!windows_preview::keyboard_deadline(10,5000,1000,1001,1000,20));
}

void test_key_reservation() {
  using Reservation = windows_preview::DesktopMoveKeyReservation;
  using Action = Reservation::Action;
  for (const uint32_t win : {0x5bu, 0x5cu}) {
    Reservation key;
    assert(key.event('E', true).action == Action::Pass);
    assert(key.reserve(win));
    assert(!key.reserve(win));
    assert(key.event(win, true).action == Action::Suppress);
    auto tap = key.event(win, false);
    assert(tap.action == Action::Replay && tap.replay_key == win && !key.key());

    assert(key.reserve(win));
    auto shortcut = key.event('E', true);
    assert(shortcut.action == Action::Replay && shortcut.replay_key == win);
    assert(key.event(win, false).action == Action::Pass);

    // After any actual drag, unrelated keys never resurrect the shell Win
    // modifier; repeats and the eventual physical Win-up remain swallowed.
    assert(key.reserve(win));
    key.mark_used();
    auto ordinary = key.event('E', true);
    assert(ordinary.action == Action::Pass && ordinary.cancel_owner && key.key() == win);
    assert(key.event('E', false).action == Action::Pass);
    assert(key.event(win, true).action == Action::Suppress);
    assert(key.event('R', true).action == Action::Pass);
    assert(key.event(win, false).action == Action::Suppress && !key.key());

    // Focus loss, hide and destruction share this drain-only transition,
    // including a Win press whose drag had not started yet.
    for (const bool used : {false, true}) {
      assert(key.reserve(win));
      if (used) key.mark_used();
      key.owner_lost();
      assert(!key.reserve(win == 0x5b ? 0x5c : 0x5b));
      assert(key.event('E', true).action == Action::Pass);
      assert(key.event(win, true).action == Action::Suppress);
      assert(key.event(win, false).action == Action::Suppress && !key.key());
    }
  }
}

int main() {
  test_key_reservation();
  test_source_win_keys();
  windows_preview::DesktopMoveGesture gesture;
  const vfgp::DesktopRect bounds{1000, 2000, 5000, 4000};
  assert(!gesture.begin(1, 10, 1000, 7, bounds, 1001, 2001));
  assert(gesture.win_down());
  assert(!gesture.begin(0, 10, 1000, 7, bounds, 1200, 2300));
  assert(!gesture.begin(42, 10, 1000, 7, bounds, 6000, 2300));
  auto begin = gesture.begin(42, 10, 1000, 7, bounds, 1200, 2300);
  assert(begin && begin->phase == windows_preview::DesktopMovePhase::Begin &&
         begin->sequence == 1 && begin->deadline_qpc == 260 &&
         begin->bounds.x_millidip == 1000 && gesture.input_suppressed());
  assert(!gesture.win_down());
  assert(!gesture.begin(43, 10, 1000, 7, bounds, 1200, 2300));
  auto update = gesture.update(20, 1000, 2200, 3300);
  assert(update && update->sequence == 2 && update->bounds.x_millidip == 2000 &&
         update->bounds.y_millidip == 3000);
  assert(gesture.win_up());
  auto end = gesture.end(30, 1000, 2200, 3300);
  assert(end && end->phase == windows_preview::DesktopMovePhase::End &&
         end->sequence == 3 && !gesture.active() &&
         !gesture.input_suppressed());
  assert(!gesture.armed());
  assert(!gesture.update(31, 1000, 2200, 3300));
  assert(gesture.win_down());
  assert(gesture.begin(43, 40, 1000, 8, bounds, 1200, 2300));
  auto cancel = gesture.end(50, 1000, 0, 0, true);
  assert(cancel && cancel->phase == windows_preview::DesktopMovePhase::Cancel &&
         cancel->bounds.x_millidip == bounds.x_millidip && !gesture.active());
  gesture.win_up();
  gesture.authoritative_placement(8, bounds);
  assert(gesture.input_suppressed() && gesture.draining_pointer());
  assert(gesture.drain_pointer(false, false, true)); // Held motion after Win-up.
  assert(gesture.draining_pointer());
  assert(gesture.drain_pointer(false, true, false)); // Matching up is swallowed.
  assert(!gesture.input_suppressed());
  assert(!gesture.drain_pointer(false, true, false));

  // Focus/capture-loss cancellation retains the same bounded physical tail.
  for (const bool release_outside : {false, true}) {
    assert(gesture.win_down());
    assert(gesture.begin(44, 60, 1000, 9, bounds, 1200, 2300));
    gesture.win_up();
    assert(gesture.end(70, 1000, 0, 0, true));
    assert(gesture.draining_pointer());
    if (release_outside)
      assert(!gesture.drain_pointer(true, false, true)); // Fresh click can proceed.
    else
      assert(gesture.drain_pointer(false, false, false)); // Neutral hover drains.
    assert(!gesture.draining_pointer() && !gesture.input_suppressed());
  }
}

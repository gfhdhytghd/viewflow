#include "keyboard_input.h"
#include <cassert>
using namespace viewflow::windows_preview;
int main() {
  using namespace viewflow::windows_preview;
  for (unsigned scenario = 0; scenario < 6; ++scenario) {
    KeyboardHeldState held;
    assert(held.admit(PhysicalKey{7,0xe1,false,false}, 2));
    assert(held.admit(PhysicalKey{7,4,false,false}, 2));
    held.cancel_for_geometry();
    assert(!held.cancelled_physical_drained());
    assert(!held.admit(PhysicalKey{7,4,true,false}, 2));
    if (scenario == 0) {
      assert(held.observe_cancelled(PhysicalKey{7,4,false,true}, 2));
      assert(held.observe_cancelled(PhysicalKey{7,4,true,false}, 2));
      assert(!held.cancelled_physical_drained());
      assert(held.observe_cancelled(PhysicalKey{7,0xe1,true,false}, 0));
      assert(held.cancelled_physical_drained());
      assert(held.any() && held.modifiers() == 2);
      held.cancel_for_geometry();
      assert(held.cancelled_physical_drained());
    } else {
      const PhysicalKey bad[] = {{7,5,false,false}, {7,4,true,true},
          {7,4,false,false}, {0,4,true,false}, {7,4,true,false}};
      assert(!held.observe_cancelled(bad[scenario - 1], scenario == 5 ? 0 : 2));
      assert(!held.cancelled_physical_drained());
      assert(!held.observe_cancelled(PhysicalKey{7,4,true,false}, 2));
      assert(held.any());
    }
  }
  KeyboardHeldState moving;
  assert(moving.admit(PhysicalKey{7,0xe3,false,false}, 8));
  assert(moving.admit(PhysicalKey{7,0xe1,false,false}, 10));
  assert(moving.only_move_modifiers() && !moving.only_win_modifiers());
  assert(moving.admit(PhysicalKey{7,0xe1,true,false}, 8));
  assert(moving.admit(PhysicalKey{7,0xe3,true,false}, 0));
  assert(!moving.any());
  assert(moving.admit(PhysicalKey{7,4,false,false}, 0));
  assert(!moving.only_move_modifiers());
  KeyboardHeldState duplicate;
  assert(duplicate.admit(PhysicalKey{7,4,false,false}, 0));
  duplicate.cancel_for_geometry();
  assert(duplicate.observe_cancelled(PhysicalKey{7,4,true,false}, 0));
  assert(duplicate.cancelled_physical_drained());
  assert(!duplicate.observe_cancelled(PhysicalKey{7,4,true,false}, 0));
  assert(!duplicate.cancelled_physical_drained());
  assert(duplicate.any());
  auto down = physical_key(0x001e0001, false).value();
  assert(down.usage == 4 && !down.repeat && !down.released);
  assert(physical_key(0xc01e0001, true)->released);
  assert(physical_key(0x401e0001, false)->repeat);
  assert(physical_key(0x011d0001, false)->usage == 0xe4);
  assert(!physical_key(0x001e0002, false));
  assert(!physical_key(0x801e0001, true));
  assert(!physical_key(0xc01e0001, false));
  assert(!physical_key(0x00450001, false)); // E1 Pause is not NumLock.
  assert(!physical_key(0x00ff0001, false));
  assert(keyboard_usage(0x1c) != keyboard_usage(0xe01c));
  assert(keyboard_deadline(100, 100, 1'000'000'000, 1'000'000'000, 1'000'000'000, 20) == 5'980'000'000);
  assert(keyboard_deadline(0xfffffffeu, 2, 1'000'000'000, 1'000'000'000, 1'000'000'000, 20) == 5'976'000'000);
  assert(keyboard_deadline(100, 140, 1'000'000'000, 1'000'000'000, 1'000'000'000, 20) == 5'940'000'000);
  assert(!keyboard_deadline(100, 5080, 1'000'000'000, 1'000'000'000, 1'000'000'000, 20));
  assert(!keyboard_deadline(101, 100, 1'000'000'000, 1'000'000'000, 1'000'000'000, 20));
  assert(!keyboard_deadline(100, 100, 1'000'000'000, 5'980'000'000, 1'000'000'000, 20));
  assert(!keyboard_deadline(100, 100, 1, 1, 0, 20));
  KeyboardHeldState state;
  assert(!state.admit(down, 2)); // A receiver-side held Shift is not imported.
  auto shift = physical_key(0x002a0001, false).value();
  assert(state.admit(shift, 2));
  assert(state.admit(down, 2));
  assert(!state.admit(down, 2));
  assert(state.admit(physical_key(0x401e0001, false).value(), 2));
  assert(state.admit(physical_key(0xc01e0001, true).value(), 2));
  assert(state.any());
  assert(state.admit(physical_key(0xc02a0001, true).value(), 0));
  assert(!state.any());
}

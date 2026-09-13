// SPDX-License-Identifier: GPL-3.0-only
#include "touchpad_capture.hpp"
#include "gesture_route.hpp"
#include <cassert>

using namespace viewflow::hyprland;
int main() {
  GestureRoute gesture;
  assert(!gesture.begin(false).suppress);
  auto crossed = gesture.update(true);
  assert(crossed.suppress && crossed.cancelLocal);
  assert(gesture.update(false).suppress); // remote tail cannot activate Linux.
  assert(gesture.end(false).suppress);
  assert(!gesture.begin(false).suppress); // local restored for next gesture.
  assert(!gesture.end(false).suppress);
  assert(gesture.begin(true).suppress);
  assert(gesture.update(true).suppress);
  assert(gesture.end(true).suppress);
  assert(!gesture.begin(false).suppress);
  auto endCrossed = gesture.end(true);
  assert(endCrossed.suppress && endCrossed.cancelLocal);
  TouchpadSlots state;
  state.x = {.value=0, .minimum=-4000, .maximum=4000, .fuzz=0, .flat=0, .resolution=80};
  state.y = {.value=0, .minimum=-2000, .maximum=2000, .fuzz=0, .flat=0, .resolution=80};
  auto set = [&](int slot, int id, int x, int y) {
    state.event(EV_ABS, ABS_MT_SLOT, slot);
    state.event(EV_ABS, ABS_MT_TRACKING_ID, id);
    state.event(EV_ABS, ABS_MT_POSITION_X, x);
    state.event(EV_ABS, ABS_MT_POSITION_Y, y);
  };
  set(0, 99, -2000, -1000);
  set(3, 100, 2000, 1000);
  state.event(EV_ABS, ABS_MT_PRESSURE, 21);
  state.event(EV_ABS, ABS_MT_TOUCH_MAJOR, 108);
  state.event(EV_ABS, ABS_MT_TOUCH_MINOR, 76);
  state.event(EV_ABS, ABS_MT_ORIENTATION, -2);
  auto frame = state.snapshot();
  assert(frame.contacts[1].pressure == 21 && frame.contacts[1].major == 108);
  assert(frame.contacts[1].minor == 76 && frame.contacts[1].orientation == -2);
  assert(frame.width == 10000 && frame.height == 5000 && frame.count == 2);
  assert(frame.contacts[0].id == 99 && frame.contacts[0].x == 2500 && frame.contacts[0].y == 1250);
  assert(frame.contacts[1].id == 100 && frame.contacts[1].x == 7500);
  set(0, -1, 0, 0);
  assert(state.snapshot().count == 1 && state.snapshot().contacts[0].id == 100);
  set(0, 101, 0, 0);
  assert(state.snapshot().contacts[0].id == 101); // slot reuse is a new contact.
  state.event(EV_ABS, ABS_MT_TOOL_TYPE, MT_TOOL_PALM);
  assert(state.snapshot().count == 1);
  state.event(EV_SYN, SYN_DROPPED, 0);
  assert(state.snapshot().count == 0);
  state.event(EV_ABS, ABS_MT_TRACKING_ID, 102);
  assert(state.snapshot().count == 0); // no partial-frame recovery.
  state.dropped = false;
  state.event(EV_ABS, ABS_MT_TOOL_TYPE, MT_TOOL_FINGER);
  for (int i = 0; i < 6; ++i) set(i, i + 1, 0, 0);
  assert(state.snapshot().count == 0); // overload lifts contacts, never truncates them.
  set(5, -1, 0, 0);
  assert(state.snapshot().count == 5);
  set(4, 200, 10000, -10000);
  frame = state.snapshot();
  assert(frame.contacts[4].x == frame.width && frame.contacts[4].y == 0);
}

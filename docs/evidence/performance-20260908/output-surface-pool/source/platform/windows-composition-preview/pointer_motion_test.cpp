#include "pointer_motion.h"

#include <cstdio>

using viewflow::windows_preview::PointerMotionState;

int main() {
  PointerMotionState disabled(false);
  disabled.commit_presented(7);
  if (disabled.client_move(1, 1, 4, 4)) return 1;

  PointerMotionState state(true);
  if (state.client_move(1, 1, 4, 4)) return 2;  // no committed surface
  state.commit_presented(7);
  if (state.client_move(-1, 0, 4, 4) || state.client_move(0, -1, 4, 4)) return 3;
  if (state.client_move(4, 0, 4, 4) || state.client_move(0, 4, 4, 4)) return 4;
  if (state.client_move(0, 0, 0, 4) || state.client_move(0, 0, 4, 0)) return 5;
  auto first = state.client_move(0, 3, 4, 4);
  if (!first || first->frame_identity != 7 || first->x_pixels != 0 ||
      first->y_pixels != 3 || first->viewport_width != 4 ||
      first->viewport_height != 4)
    return 6;
  if (state.client_move(0, 3, 4, 4)) return 7;  // duplicate same-frame pixel
  auto after_resize = state.client_move(0, 3, 8, 4);
  if (!after_resize || after_resize->frame_identity != 7 ||
      after_resize->viewport_width != 8)
    return 8;
  // An expired frame never calls commit_presented, so movement remains tied to
  // the last successfully committed visual identity.
  state.reject_unpresented(8);
  auto after_expired = state.client_move(1, 3, 4, 4);
  if (!after_expired || after_expired->frame_identity != 7) return 9;
  state.commit_presented(9);
  auto after_commit = state.client_move(1, 3, 4, 4);
  if (!after_commit || after_commit->frame_identity != 9) return 10;
  state.commit_presented(0);
  if (state.client_move(1, 3, 4, 4)) return 11;
  state.clear();
  if (state.client_move(2, 3, 4, 4)) return 12;
  state.commit_presented(10, 100);
  if (state.timed_client_move(1, 1, 4, 4, 99, 300, 1'000'000'000)) return 13;
  if (state.timed_client_move(1, 1, 4, 4, 301, 300, 1'000'000'000)) return 14;
  if (state.timed_client_move(1, 1, 4, 4, 200, 34'000'000, 1'000'000'000)) return 15;
  if (state.timed_client_move(1, 1, 4, 4, 200, 300, 0)) return 16;
  const auto timed = state.timed_client_move(1, 1, 4, 4, 200, 300, 1'000'000'000);
  if (!timed || timed->frame_identity != 10 || timed->not_after_qpc != 33'333'534 || timed->qpc_frequency != 1'000'000'000) return 17;
  std::puts("PASS committed-pointer motion client-pixel gates");
  PointerMotionState buttons(true, true);
  buttons.commit_presented(11, 100);
  if (buttons.timed_client_button(1, 1, 4, 4, 200, 300, 1'000'000'000, 1, 2)) return 18;
  if (!buttons.timed_client_button(1, 1, 4, 4, 200, 300, 1'000'000'000, 1, 1)) return 19;
  if (buttons.timed_client_button(1, 1, 4, 4, 200, 300, 1'000'000'000, 1, 1)) return 20;
  buttons.commit_presented(12, 400);
  if (!buttons.has_pressed_buttons()) return 21;
  const auto queued_up = buttons.timed_client_button(1, 1, 4, 4, 300, 600, 1'000'000'000, 1, 2);
  if (!queued_up || queued_up->frame_identity != 11) return 22;
  PointerMotionState delayed(true, true);
  delayed.commit_presented(1, 100);
  const auto delayed_down = delayed.timed_client_button(1,1,4,4,200,40'000'000,1'000'000'000,1,1);
  if (!delayed_down || delayed_down->not_after_qpc != 5'000'000'200) return 45;
  if (!delayed.timed_client_button(1,1,4,4,40'000'100,80'000'000,1'000'000'000,1,2) || delayed.has_pressed_buttons()) return 46;
  if (buttons.timed_client_button(1, 1, 4, 4, 500, 600, 1'000'000'000, 1, 2)) return 23;
  if (buttons.has_pressed_buttons()) return 24;
  if (state.timed_client_button(1, 1, 4, 4, 200, 300, 1'000'000'000, 1, 1)) return 25;
  buttons.retire();
  buttons.commit_presented(13, 700);
  if (buttons.timed_client_button(1, 1, 4, 4, 800, 900, 1'000'000'000, 1, 1)) return 26;
  std::puts("PASS explicit native button transitions and frame renewal");
  PointerMotionState history(true, true);
  for (uint64_t frame = 1; frame <= 33; ++frame) history.commit_presented(frame, frame * 100);
  if (history.timed_client_move(1, 1, 4, 4, 199, 3400, 1'000'000'000)) return 27;
  const auto oldest = history.timed_client_move(1, 1, 4, 4, 200, 3400, 1'000'000'000);
  if (!oldest || oldest->frame_identity != 2) return 28;
  const auto newest = history.timed_client_move(1, 1, 4, 4, 3300, 3400, 1'000'000'000);
  if (!newest || newest->frame_identity != 33) return 29;
  history.clear();
  if (history.timed_client_move(1, 1, 4, 4, 3300, 3400, 1'000'000'000)) return 30;
  history.commit_presented(40, 4000);
  history.commit_presented(39, 4100);
  if (history.timed_client_move(1, 1, 4, 4, 4050, 4200, 1'000'000'000)) return 31;
  std::puts("PASS bounded event-time presentation history");
  PointerMotionState scrolling(true, true);
  scrolling.commit_presented(1, 100);
  scrolling.commit_presented(2, 200);
  for (int i = 0; i < 2; ++i) {
    const auto event = scrolling.timed_client_wheel(1, 1, 4, 4, 150, 210, 1'000'000'000, 30, -60);
    if (!event || event->frame_identity != 1 || event->not_after_qpc != 5'000'000'150 || scrolling.has_pressed_buttons()) return 32;
  }
  if (!scrolling.timed_client_button(1, 1, 4, 4, 220, 230, 1'000'000'000, 1, 1)) return 33;
  if (!scrolling.timed_client_wheel(1, 1, 4, 4, 240, 250, 1'000'000'000, -1, 1) || !scrolling.has_pressed_buttons()) return 34;
  if (!scrolling.timed_client_button(1, 1, 4, 4, 260, 270, 1'000'000'000, 1, 2) || scrolling.has_pressed_buttons()) return 35;
  if (scrolling.timed_client_wheel(-1, 1, 4, 4, 280, 290, 1'000'000'000, 120, 0) ||
      scrolling.timed_client_wheel(4, 1, 4, 4, 280, 290, 1'000'000'000, 120, 0) ||
      scrolling.timed_client_wheel(1, 1, 4, 4, 280, 6'000'000'000, 1'000'000'000, 120, 0) ||
      scrolling.timed_client_wheel(1, 1, 4, 4, 280, 290, 1'000'000'000, 0, 0) ||
      scrolling.timed_client_wheel(1, 1, 4, 4, 280, 290, 1'000'000'000, 32768, 0)) return 36;
  scrolling.retire();
  if (scrolling.timed_client_wheel(1, 1, 4, 4, 280, 290, 1'000'000'000, 120, 0)) return 37;
  std::puts("PASS distinct event-time wheel samples and unchanged button state");
  const uint32_t native_bits[] = {0x01, 0x10, 0x02, 0x20, 0x40};
  for (uint32_t held = 0; held < 32; ++held) {
    PointerMotionState buttons(true, true);
    buttons.commit_presented(1, 100);
    uint32_t expected = 0;
    for (uint32_t button = 0; button < 5; ++button) {
      if (!(held & (1u << button))) continue;
      if (!buttons.timed_client_button(1, 1, 4, 4, 110 + button, 120, 1'000'000'000, button + 1, 1)) return 38;
      expected |= native_bits[button];
    }
    if (!buttons.wheel_key_state_matches(expected) ||
        buttons.wheel_key_state_matches(expected ^ 0x01) ||
        buttons.wheel_key_state_matches(expected | 0x04) ||
        buttons.wheel_key_state_matches(expected | 0x08) ||
        buttons.wheel_key_state_matches(expected | 0x80)) return 39;
    buttons.retire();
    if (buttons.wheel_key_state_matches(0)) return 40;
  }
  if (disabled.wheel_key_state_matches(0) || state.wheel_key_state_matches(0)) return 41;
  std::puts("PASS exact wheel key-state matching for all mouse button combinations");
}

#include "atlas_pointer.h"
#include <cassert>

static void rejected_input_recovery() {
  using namespace viewflow::windows_preview;
  using namespace viewflow::vfgp;
  AtlasLayout layout{{1,2},3,4,5,100,true,true,{}};
  AtlasTile tile{{6,7},5,9,80,100,0,0,64,64};
  AtlasPointerState state(true,true,true,true);
  state.commit(100,100,layout,tile);
  assert(state.pointer.timed_client_button(1,2,64,64,101,102,1000,1,1));
  assert(state.keyboard.admit({7,4,false,false},0));
  InputRecoveryConfirmation cancel{1,layout.stream,tile.window,layout.geometry_epoch,layout.config_generation,
      tile.geometry_epoch,tile.geometry_epoch,0,100,tile.source_frame,tile.placement_generation,200,1000,
      1,100,tile.source_frame,1};
  // The first hover can select a visible proxy without activating its HWND.
  AtlasPointerState hover(true,true,true,true);
  hover.commit(100,100,layout,tile);
  assert(!hover.recovery_recipient_allowed(2,true,false));
  assert(hover.cancel_rejected_input(cancel,110,1000));
  assert(hover.recovery_recipient_allowed(2,true,false));
  assert(!hover.recovery_recipient_allowed(0,true,false)); // V6 stays strict.
  assert(!hover.recovery_recipient_allowed(2,false,false));
  auto activated = hover;
  assert(activated.observe_cancelled_keyboard({7,4,false,false},0));
  assert(activated.observe_cancelled_keyboard({7,4,true,false},0));
  assert(!activated.recovery_recipient_allowed(2,true,false));
  assert(activated.recovery_recipient_allowed(2,true,true));
  auto clicked = hover;
  assert(clicked.observe_rejected_pointer(1,1));
  assert(clicked.observe_rejected_pointer(1,2));
  assert(!clicked.recovery_recipient_allowed(2,true,false));
  auto hover_resume = cancel;
  hover_resume.rejection_kind=2; hover_resume.sequence=2; hover_resume.grant_generation=1;
  auto wrong_hover = hover_resume; wrong_hover.window.first++;
  assert(!hover.confirm_geometry_recovery(wrong_hover,120,1000));
  assert(hover.confirm_geometry_recovery(hover_resume,120,1000));
  assert(!hover.recovery_recipient_allowed(2,true,false));
  for (int invalid = 0; invalid < 6; ++invalid) {
    auto candidate = state; auto bad = cancel;
    if (invalid == 0) bad.window.first++;
    if (invalid == 1) bad.source_frame++;
    if (invalid == 2) bad.placement_generation++;
    if (invalid == 3) bad.deadline_qpc = 110;
    if (invalid == 4) bad.cancel_sequence++;
    if (invalid == 5) bad.grant_generation = 1;
    assert(!candidate.cancel_rejected_input(bad,110,1000));
    assert(candidate.pointer.has_pressed_buttons() && candidate.keyboard.any());
  }
  assert(state.cancel_rejected_input(cancel,110,1000));
  assert(!state.recovery_recipient_allowed(2,true,false));
  assert(state.pointer.has_pressed_buttons() && state.keyboard.any());
  auto cancelled = state.take_recovery_notice();
  assert(cancelled && !cancelled->physical_drained && cancelled->cancel_sequence == 1);
  assert(!state.take_recovery_notice());
  assert(!state.pointer.timed_client_button(1,2,64,64,111,112,1000,1,2));
  assert(state.observe_shell_left_button(true));
  assert(!state.rejected_pointer_drained());
  assert(state.observe_shell_left_button(false));
  assert(state.observe_shell_left_button(false)); // No duplicate application up.

  assert(!state.physical_recovery_drained());
  assert(state.observe_cancelled_keyboard({7,4,true,false},0));
  auto drained = state.take_recovery_notice();
  assert(drained && drained->physical_drained && drained->cancel_sequence == 1);
  // Physical drain never clears the source-facing held ledger by itself.
  assert(state.pointer.has_pressed_buttons() && state.keyboard.any());
  auto resume = cancel; resume.rejection_kind=2; resume.sequence=2; resume.grant_generation=1;
  auto wrong_cause = resume; wrong_cause.rejection_kind=0;
  assert(!state.confirm_geometry_recovery(wrong_cause,120,1000));
  // Additional physical input while quarantined is drained, never emitted.
  assert(state.observe_rejected_pointer(3,1));
  assert(!state.confirm_geometry_recovery(resume,120,1000));
  assert(state.observe_rejected_pointer(3,2));
  assert(state.take_recovery_notice()->physical_drained);
  assert(state.observe_cancelled_keyboard({7,0xe1,false,false},2));
  assert(!state.confirm_geometry_recovery(resume,125,1000));
  assert(state.observe_cancelled_keyboard({7,0xe1,true,false},0));
  assert(state.take_recovery_notice()->physical_drained);
  auto wrapped = state;
  assert(wrapped.confirm_geometry_recovery(resume,130,1000,0xfffffff0u));
  assert(!wrapped.suppress_pre_recovery_key({7,4,false,false},5));
  assert(wrapped.suppress_pre_recovery_key({7,4,false,false},0xffffffefu));
  assert(wrapped.suppress_pre_recovery_key({7,4,true,false},6));
  assert(state.confirm_geometry_recovery(resume,130,1000,500));
  assert(state.suppress_pre_recovery_key({7,4,false,false},499));
  assert(state.suppress_pre_recovery_key({7,4,true,false},501));
  assert(!state.suppress_pre_recovery_key({7,4,false,false},501));
  assert(state.suppress_pre_recovery_key({7,0xe1,false,false},500));
  assert(state.suppress_pre_recovery_key({7,5,false,false},501));
  assert(state.suppress_pre_recovery_key({7,0xe1,true,false},502));
  assert(state.suppress_pre_recovery_key({7,5,true,false},503));
  assert(!state.suppress_pre_recovery_key({7,5,false,false},504));
  assert(state.suppress_pre_recovery_pointer(129,1,1));
  assert(state.suppress_pre_recovery_pointer(131,1,2));
  assert(!state.suppress_pre_recovery_pointer(132,1,1));
  assert(state.keyboard_enabled() && !state.pointer.has_pressed_buttons() && !state.keyboard.any());
  assert(!state.pointer.timed_client_button(1,2,64,64,129,131,1000,1,1));
  assert(!state.pointer.timed_client_button(1,2,64,64,131,132,1000,1,2));
  assert(state.pointer.timed_client_button(1,2,64,64,132,133,1000,1,1));
  assert(!state.confirm_geometry_recovery(resume,140,1000));
}

int main() {
  rejected_input_recovery();
  using namespace viewflow::windows_preview;
  viewflow::vfgp::AtlasLayout layout{{1, 2}, 3, 4, 5, 100, true, true, {}};
  viewflow::vfgp::AtlasTile first{{6, 7}, 5, 9, 80, 100, 0, 0, 64, 64};
  auto second = first;
  second.window = {8, 9}; second.source_frame = 17;
  AtlasPointerState a(true), b(true);
  assert(!a.wheel_enabled());
  AtlasPointerState wheel(true, true), wheel_disabled(false, true);
  assert(wheel.wheel_enabled() && !wheel_disabled.wheel_enabled());
  wheel.pointer.retire();
  assert(!wheel.wheel_enabled());
  assert(!a.pointer.timed_client_move(1, 2, 64, 64, 101, 102, 1000));
  a.commit(100, 100, layout, first);
  b.commit(100, 100, layout, second);
  AtlasPointerState keyboard(true, true, true), keyboard_target(true, true, true);
  keyboard.commit(100, 100, layout, first);
  keyboard_target.commit(100, 100, layout, second);
  assert(keyboard.keyboard_enabled() && keyboard.current_keyboard_binding()->tile.source_frame == 80);
  assert(keyboard.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  assert(!keyboard.permits_focus_transfer_to(keyboard_target));
  auto changed = first; changed.geometry_epoch += 1; changed.source_frame += 1;
  keyboard.commit(101, 110, layout, changed);
  assert(!keyboard.keyboard_enabled() && !keyboard.current_keyboard_binding());
  assert(keyboard.keyboard.any()); // Retiring does not invent release confirmation.
  assert(keyboard.keyboard.cancelled());
  assert(!keyboard.keyboard.cancelled_physical_drained());
  assert(keyboard.keyboard.observe_cancelled(PhysicalKey{7,4,false,true}, 0));
  assert(keyboard.keyboard.observe_cancelled(PhysicalKey{7,4,true,false}, 0));
  assert(keyboard.keyboard.cancelled_physical_drained());
  assert(keyboard.keyboard.any()); // Physical up is not remote cleanup proof.
  assert(!keyboard.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  auto still_suspended = changed;
  still_suspended.source_frame++;
  keyboard.commit(102, 120, layout, still_suspended);
  assert(keyboard.keyboard.cancelled_physical_drained()); // No recopy of held ledger.
  assert(!keyboard.keyboard_enabled()); // No authority restored by a visual commit.
  auto recovery_tile = still_suspended;
  recovery_tile.source_frame++;
  keyboard.commit(103, 130, layout, recovery_tile);
  viewflow::vfgp::InputRecoveryConfirmation confirmation{
      1, layout.stream, first.window, layout.geometry_epoch, layout.config_generation,
      first.geometry_epoch, recovery_tile.geometry_epoch, 1, 103, recovery_tile.source_frame,
      recovery_tile.placement_generation, 150, 1000};
  const auto rejected = [&](auto mutation) {
    auto candidate = keyboard;
    auto record = confirmation;
    mutation(record);
    assert(!candidate.confirm_geometry_recovery(record, 140, 1000));
    assert(!candidate.keyboard_enabled() && candidate.keyboard.any());
  };
  rejected([](auto& c) { c.sequence = 0; });
  rejected([](auto& c) { c.stream.first++; });
  rejected([](auto& c) { c.window.first++; });
  rejected([](auto& c) { c.atlas_epoch++; });
  rejected([](auto& c) { c.config_generation++; });
  rejected([](auto& c) { c.previous_epoch++; });
  rejected([](auto& c) { c.geometry_epoch++; });
  rejected([](auto& c) { c.grant_generation = 0; });
  rejected([](auto& c) { c.atlas_frame--; });
  rejected([](auto& c) { c.source_frame--; });
  rejected([](auto& c) { c.placement_generation++; });
  rejected([](auto& c) { c.deadline_qpc = 140; });
  rejected([](auto& c) { c.frequency++; });
  assert(!keyboard.confirm_geometry_recovery(confirmation, 129, 1000));
  auto fatal = keyboard;
  fatal.pointer.retire();
  assert(!fatal.confirm_geometry_recovery(confirmation, 140, 1000));
  auto regressed = keyboard;
  auto regressed_tile = recovery_tile;
  regressed_tile.source_frame++;
  regressed.commit(102, 131, layout, regressed_tile);
  assert(!regressed.confirm_geometry_recovery(confirmation, 140, 1000));
  auto reversed_clock = keyboard;
  reversed_clock.commit(104, 130, layout, recovery_tile);
  assert(!reversed_clock.confirm_geometry_recovery(confirmation, 140, 1000));
  auto invalid_drain = keyboard;
  invalid_drain.keyboard.invalidate_cancelled();
  assert(!invalid_drain.confirm_geometry_recovery(confirmation, 140, 1000));
  assert(keyboard.confirm_geometry_recovery(confirmation, 140, 1000));
  assert(keyboard.keyboard_enabled() && !keyboard.keyboard.any() && !keyboard.keyboard.cancelled());
  assert(!keyboard.find(100) && keyboard.find(103));
  assert(!keyboard.pointer.timed_client_move(1, 2, 64, 64, 139, 141, 1000));
  assert(keyboard.pointer.timed_client_move(1, 2, 64, 64, 140, 141, 1000));
  assert(!keyboard.confirm_geometry_recovery(confirmation, 141, 1000));
  assert(keyboard.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  recovery_tile.geometry_epoch++;
  recovery_tile.source_frame++;
  keyboard.commit(104, 142, layout, recovery_tile);
  confirmation.previous_epoch++;
  confirmation.geometry_epoch++;
  confirmation.atlas_frame++;
  confirmation.source_frame++;
  confirmation.sequence++;
  confirmation.grant_generation++;
  // Matching source confirmation cannot replace the missing physical release.
  assert(!keyboard.confirm_geometry_recovery(confirmation, 143, 1000));
  assert(keyboard.keyboard.observe_cancelled(PhysicalKey{7,4,true,false}, 0));
  auto stale_grant = confirmation;
  stale_grant.grant_generation--;
  assert(!keyboard.confirm_geometry_recovery(stale_grant, 143, 1000));
  auto stale_sequence = confirmation;
  stale_sequence.sequence--;
  assert(!keyboard.confirm_geometry_recovery(stale_sequence, 143, 1000));
  assert(keyboard.confirm_geometry_recovery(confirmation, 143, 1000));

  // Losing focus releases this HWND's ledgers without disabling later input.
  AtlasPointerState focus_release(true, true, true, true);
  focus_release.commit(100, 100, layout, first);
  assert(focus_release.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  focus_release.release_for_focus(120, 20);
  assert(!focus_release.keyboard.any() && !focus_release.pointer.has_pressed_buttons());
  assert(focus_release.keyboard_enabled() && focus_release.current_binding());
  assert(focus_release.suppress_pre_recovery_pointer(110, 0, 0));
  assert(focus_release.keyboard.admit(PhysicalKey{7,4,false,false}, 0));

  // A source geometry suspension emits one cancellation and, only after all
  // physically held keys are released, one drain notice.  The drain may name
  // a newer committed placement, but it retains the original cancellation
  // lineage and never grants input by itself.
  AtlasPointerState notices(true, true, true, true);
  notices.commit(100, 100, layout, first);
  assert(notices.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  notices.commit(101, 110, layout, changed);
  const auto cancelled_notice = notices.take_recovery_notice();
  assert(cancelled_notice && !cancelled_notice->physical_drained &&
      cancelled_notice->previous.atlas_frame == 100 &&
      cancelled_notice->previous.tile.geometry_epoch == first.geometry_epoch &&
      cancelled_notice->current.atlas_frame == 101 &&
      cancelled_notice->current.tile.geometry_epoch == changed.geometry_epoch &&
      !notices.take_recovery_notice());
  auto moved = changed;
  moved.placement_generation++;
  moved.source_frame++;
  auto moved_layout = layout;
  moved_layout.revision++;
  notices.commit(102, 120, moved_layout, moved);
  assert(!notices.take_recovery_notice());
  assert(notices.keyboard.observe_cancelled(PhysicalKey{7,4,true,false}, 0));
  const auto drained_notice = notices.take_recovery_notice();
  assert(drained_notice && drained_notice->physical_drained &&
      drained_notice->previous.atlas_frame == 100 &&
      drained_notice->current.atlas_frame == 102 &&
      drained_notice->current.tile.placement_generation == moved.placement_generation &&
      !notices.take_recovery_notice());

  // A pure atlas placement update does not advance source geometry.  It must
  // keep the held source key route intact instead of entering a VFGP6 state
  // whose source-geometry lineage could never be confirmed.
  AtlasPointerState placement_only(true, true, true, true);
  placement_only.commit(100, 100, layout, first);
  assert(placement_only.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  auto relocated = first;
  relocated.placement_generation++;
  relocated.source_frame++;
  placement_only.commit(101, 110, moved_layout, relocated);
  assert(placement_only.keyboard_enabled() && !placement_only.keyboard.cancelled() &&
      !placement_only.geometry_recovery_pending() && !placement_only.take_recovery_notice());
  assert(placement_only.keyboard.admit(PhysicalKey{7,4,true,false}, 0));

  // Recovery notices are a separate explicit capability.  A normal keyboard
  // launch still suspends safely but cannot expose the recovery control flow.
  AtlasPointerState no_recovery_opt_in(true, true, true);
  no_recovery_opt_in.commit(100, 100, layout, first);
  assert(no_recovery_opt_in.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  no_recovery_opt_in.commit(101, 110, layout, changed);
  assert(no_recovery_opt_in.geometry_recovery_pending() && !no_recovery_opt_in.take_recovery_notice());

  // A stream/atlas/configuration lineage break cannot satisfy VFGP6's exact
  // old/current binding.  It is retired permanently and sends no recovery
  // notification, even after physical key release.
  AtlasPointerState broken_lineage(true, true, true, true);
  broken_lineage.commit(100, 100, layout, first);
  assert(broken_lineage.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  auto broken_layout = layout;
  broken_layout.geometry_epoch++;
  auto foreign_tile = first;
  foreign_tile.source_frame++;
  broken_lineage.commit(101, 110, broken_layout, foreign_tile);
  assert(broken_lineage.keyboard.cancelled() && !broken_lineage.geometry_recovery_pending() &&
      !broken_lineage.take_recovery_notice());
  assert(!broken_lineage.keyboard.observe_cancelled(PhysicalKey{7,4,true,false}, 0));
  assert(!broken_lineage.take_recovery_notice());

  // An advancing atlas frame cannot repair a replayed source frame.  The
  // current tile must be source-monotonic throughout the pending suspension.
  AtlasPointerState source_replay(true, true, true, true);
  source_replay.commit(100, 100, layout, first);
  assert(source_replay.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  source_replay.commit(101, 110, layout, first);
  assert(source_replay.keyboard.cancelled() && !source_replay.geometry_recovery_pending() &&
      !source_replay.take_recovery_notice());
  AtlasPointerState placement_replay(true, true, true, true);
  placement_replay.commit(100, 100, layout, first);
  assert(placement_replay.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  auto replayed_placement = changed;
  replayed_placement.placement_generation--;
  placement_replay.commit(101, 110, layout, replayed_placement);
  assert(placement_replay.keyboard.cancelled() && !placement_replay.geometry_recovery_pending() &&
      !placement_replay.take_recovery_notice());

  auto held_buttons = AtlasPointerState(true, true, true);
  held_buttons.commit(103, 130, layout, changed);
  assert(held_buttons.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  assert(held_buttons.pointer.timed_client_button(1, 2, 64, 64, 131, 132, 1000, 1, 1));
  held_buttons.commit(104, 142, layout, recovery_tile);
  assert(held_buttons.keyboard.observe_cancelled(PhysicalKey{7,4,true,false}, 0));
  assert(!held_buttons.confirm_geometry_recovery(confirmation, 143, 1000));
  assert(a.permits_focus_transfer_to(b));
  assert(b.permits_focus_transfer_to(a));
  assert(!a.permits_focus_transfer_to(a));
  AtlasPointerState empty(true), disabled(false), foreign(true);
  assert(!a.permits_focus_transfer_to(empty));
  disabled.commit(100, 100, layout, second);
  assert(!a.permits_focus_transfer_to(disabled));
  auto foreign_layout = layout;
  foreign_layout.stream = {9, 9};
  foreign.commit(100, 100, foreign_layout, second);
  assert(!a.permits_focus_transfer_to(foreign));
  auto held_target = b;
  auto held = held_target.pointer.timed_client_button(1, 2, 64, 64, 101, 102, 1000, 1, 1);
  assert(held && !a.permits_focus_transfer_to(held_target) && !held_target.permits_focus_transfer_to(a));
  assert(held_target.pointer.timed_client_button(1, 2, 64, 64, 103, 104, 1000, 1, 2));
  assert(a.permits_focus_transfer_to(held_target));
  held_target.pointer.retire();
  assert(!a.permits_focus_transfer_to(held_target));
  first.source_frame = 81;
  a.commit(101, 110, layout, first);
  assert(!a.permits_focus_transfer_to(b));
  auto event = a.pointer.timed_client_move(1, 2, 64, 64, 105, 111, 1000);
  assert(event && event->frame_identity == 100);
  assert(a.find(event->frame_identity)->tile.source_frame == 80);
  auto other = b.pointer.timed_client_move(1, 2, 64, 64, 105, 111, 1000);
  assert(other && b.find(other->frame_identity)->tile.source_frame == 17);
  assert(a.find(100)->tile.window != b.find(100)->tile.window);
  auto down = a.pointer.timed_client_button(1, 2, 64, 64, 112, 113, 1000, 1, 1);
  assert(down && a.find(down->frame_identity)->tile.source_frame == 81);
  a.pointer.retire();
  assert(!a.pointer.has_pressed_buttons());
  assert(!a.pointer.timed_client_move(2, 2, 64, 64, 114, 115, 1000));
  assert(!a.find(99));
  for (uint64_t i = 102; i < 140; ++i) a.commit(i, i + 20, layout, first);
  assert(!a.find(100));
  assert(!a.pointer.timed_client_move(2, 2, 64, 64, 160, 161, 1000));
  // Repeated membership suspension drops old frame authority without reviving
  // a retired session or silently dropping a held application button/key.
  AtlasPointerState returning(true, true, true);
  returning.commit(200, 300, layout, first);
  assert(returning.suspend_absent());
  assert(!returning.current_binding() && !returning.find(200));
  assert(!returning.pointer.timed_client_move(1, 2, 64, 64, 301, 302, 1000));
  returning.commit(201, 310, layout, first);
  assert(!returning.pointer.timed_client_move(1, 2, 64, 64, 309, 311, 1000));
  assert(returning.pointer.timed_client_button(1, 2, 64, 64, 311, 312, 1000, 1, 1));
  assert(!returning.suspend_absent() && returning.pointer.has_pressed_buttons());
  assert(returning.pointer.timed_client_button(1, 2, 64, 64, 313, 314, 1000, 1, 2));
  assert(returning.keyboard.admit(PhysicalKey{7,4,false,false}, 0));
  assert(!returning.suspend_absent() && returning.keyboard.any());
  assert(returning.keyboard.admit(PhysicalKey{7,4,true,false}, 0));
  assert(returning.suspend_absent());
  returning.pointer.retire();
  assert(returning.suspend_absent());
  returning.commit(202, 320, layout, first);
  assert(!returning.pointer.timed_client_move(1, 2, 64, 64, 321, 322, 1000));
  AtlasPointerState pending_recovery(true, true, true, true);
  pending_recovery.keyboard.cancel_for_geometry();
  assert(!pending_recovery.keyboard.any());
  assert(!pending_recovery.suspend_absent());
}

#pragma once
#include "atlas_record.h"
#include "pointer_motion.h"
#include "keyboard_input.h"
#include "input_recovery_record.h"

namespace viewflow::windows_preview {
// Each HWND owns its own input history. Atlas IDs select a committed layout;
// native injection uses the tile's source frame, never the atlas frame number.
struct AtlasPointerBinding {
  uint64_t atlas_frame{};
  viewflow::vfgp::AtlasId stream;
  uint64_t atlas_epoch{}, config_generation{}, revision{};
  viewflow::vfgp::AtlasTile tile;
};
struct AtlasRecoveryNotice {
  AtlasPointerBinding previous, current;
  bool physical_drained{};
  uint64_t cancel_sequence{};
};
class AtlasPointerState {
 public:
  explicit AtlasPointerState(bool enabled, bool wheel = false, bool keyboard = false, bool recovery = false)
      : pointer(enabled, true), wheel_enabled_(enabled && wheel), keyboard_enabled_(enabled && wheel && keyboard),
        recovery_notifications_(enabled && wheel && keyboard && recovery) {}
  bool wheel_enabled() const noexcept { return wheel_enabled_ && pointer.buttons_enabled(); }
  bool keyboard_enabled() const noexcept { return keyboard_enabled_ && pointer.buttons_enabled(); }
  // Membership removal is reversible only after all application input drained.
  // Preserve permanent retirement and recovery counters, but drop every stale
  // visual/timestamp authority so queued events cannot use a hidden proxy.
  bool suspend_absent() {
    if (pointer.has_pressed_buttons() || keyboard.any() || keyboard.cancelled()) return false;
    pointer.clear();
    history_.clear();
    committed_ticks_ = 0;
    return true;
  }
  // A focus boundary queues an ordered source END before any later input.
  // Local held ledgers may then reset; late orphan key/button releases are ignored.
  void release_for_focus(uint64_t qpc, uint32_t ticks) {
    focus_release_frame_ = history_.empty() ? 0 : history_.back().atlas_frame;
    keyboard = KeyboardHeldState{};
    pointer.clear();
    if (!history_.empty()) pointer.commit_presented(history_.back().atlas_frame, qpc);
    cancelled_binding_.reset();
    cancel_sequence_ = 0;
    notified_cancel_ = notified_drain_ = false;
    resume_qpc_ = qpc;
    keyboard_boundary_ms_ = ticks;
    boundary_keys_.fill(false);
    boundary_buttons_ = 0;
  }
  bool recovery_superseded_by_focus(const vfgp::InputRecoveryConfirmation& c) const {
    return focus_release_frame_ && c.atlas_frame <= focus_release_frame_;
  }
  bool holds_key(uint16_t usage) const { return usage < keyboard.held_.size() && keyboard.held_[usage]; }
  KeyboardHeldState keyboard;
  PointerMotionState pointer;
  bool geometry_recovery_pending() const {
    return keyboard.cancelled() && pointer.geometry_suspended_ && cancelled_binding_.has_value();
  }
  std::optional<AtlasRecoveryNotice> take_recovery_notice() {
    if (!recovery_notifications_ || !geometry_recovery_pending() || history_.empty()) return {};
    if (!notified_cancel_) {
      notified_cancel_ = true;
      return AtlasRecoveryNotice{*cancelled_binding_, history_.back(), false, cancel_sequence_};
    }
    if (!notified_drain_ && physical_recovery_drained()) {
      notified_drain_ = true;
      return AtlasRecoveryNotice{*cancelled_binding_, history_.back(), true, cancel_sequence_};
    }
    return {};
  }
  bool rejected_recovery_pending() const { return cancel_sequence_ && geometry_recovery_pending(); }
  bool physical_recovery_drained() const {
    return keyboard.cancelled_physical_drained() &&
        (!cancel_sequence_ || pointer.rejected_physical_drained());
  }
  bool observe_rejected_pointer(uint32_t button, uint32_t transition) {
    if (transition == 1) rejected_hover_only_ = false;
    if (!rejected_recovery_pending() || !pointer.observe_rejected_button(button, transition)) {
      keyboard.invalidate_cancelled();
      return false;
    }
    if (transition == 1) notified_drain_ = false;
    return true;
  }
  bool observe_shell_left_button(bool physically_down) {
    if (!rejected_recovery_pending() || physically_down || !(pointer.rejected_physical_ & 1u)) return true;
    return observe_rejected_pointer(1, 2);
  }
  bool observe_cancelled_keyboard(PhysicalKey key, uint8_t modifiers) {
    rejected_hover_only_ = false;
    const bool rejected = rejected_recovery_pending();
    if (!keyboard.observe_cancelled(key, modifiers, rejected)) return false;
    if (rejected && !key.released) notified_drain_ = false;
    return true;
  }
  bool rejected_pointer_drained() const {
    return rejected_recovery_pending() && pointer.rejected_physical_drained();
  }
  bool recovery_recipient_allowed(uint32_t rejection_kind, bool visible, bool focused) const {
    if (!visible) return false;
    if (focused) return true;
    // V9 can recover a hover selection before this HWND has ever received
    // focus. It grants no keyboard recipient authority; keyboard delivery
    // still independently requires this proxy to own foreground focus.
    return rejection_kind == 2 && rejected_recovery_pending() &&
        rejected_hover_only_ && !keyboard.any() && !pointer.has_pressed_buttons() &&
        physical_recovery_drained();
  }
  bool suppress_pre_recovery_key(PhysicalKey key, uint32_t message_tick) {
    if (!keyboard_boundary_ms_ || key.page != 7 || !key.usage || key.usage >= boundary_keys_.size()) return false;
    const uint32_t delta = message_tick - *keyboard_boundary_ms_;
    bool draining = false;
    for (const bool held : boundary_keys_) draining |= held;
    if (delta && delta < 0x80000000u && !draining) return false;
    // Same-tick messages cannot be proven newer. Drain complete physical
    // tails, including other keys pressed while a dropped modifier is held.
    boundary_keys_[key.usage] = !key.released;
    return true;
  }
  bool suppress_pre_recovery_pointer(uint64_t event_qpc, uint32_t button, uint32_t transition) {
    if (!resume_qpc_ || !event_qpc || button > 5) return false;
    if (event_qpc > resume_qpc_ && !boundary_buttons_) return false;
    if (button) {
      const auto bit = uint32_t(1u << (button - 1));
      if (transition == 1) boundary_buttons_ |= bit;
      else if (transition == 2) boundary_buttons_ &= ~bit;
    }
    return true;
  }
  bool cancel_rejected_input(const vfgp::InputRecoveryConfirmation& c, uint64_t now, uint64_t frequency) {
    if (!recovery_notifications_ || keyboard.cancelled() || history_.empty() ||
        c.rejection_kind != 1 || !c.sequence || c.sequence <= recovery_sequence_ ||
        c.cancel_sequence != c.sequence || c.grant_generation || !now || now < committed_ticks_ ||
        !frequency || c.frequency != frequency || c.deadline_qpc <= now ||
        c.previous_epoch != c.geometry_epoch || c.previous_atlas_frame != c.atlas_frame ||
        c.previous_source_frame != c.source_frame) return false;
    const auto* old = find(c.atlas_frame);
    const auto& fresh = history_.back();
    if (!old || c.stream != old->stream || c.window != old->tile.window ||
        c.atlas_epoch != old->atlas_epoch || c.config_generation != old->config_generation ||
        c.geometry_epoch != old->tile.geometry_epoch || c.source_frame != old->tile.source_frame ||
        c.placement_generation != old->tile.placement_generation ||
        fresh.stream != old->stream || fresh.tile.window != old->tile.window ||
        fresh.atlas_epoch != old->atlas_epoch || fresh.config_generation != old->config_generation ||
        fresh.tile.geometry_epoch < old->tile.geometry_epoch || fresh.tile.source_frame < old->tile.source_frame ||
        fresh.tile.placement_generation < old->tile.placement_generation ||
        !pointer.suspend_for_rejection()) return false;
    cancelled_binding_ = *old;
    rejected_hover_only_ = !keyboard.any() && !pointer.has_pressed_buttons();
    keyboard.cancel_for_geometry();
    cancel_sequence_ = c.cancel_sequence;
    recovery_sequence_ = c.sequence;
    notified_cancel_ = notified_drain_ = false;
    return true;
  }
  bool permits_focus_transfer_to(const AtlasPointerState& target) const {
    if (this == &target || !pointer.buttons_enabled() ||
        !target.pointer.buttons_enabled() || pointer.has_pressed_buttons() ||
        target.pointer.has_pressed_buttons() || keyboard.any() || target.keyboard.any() || history_.empty() || target.history_.empty())
      return false;
    const auto& a = history_.back();
    const auto& b = target.history_.back();
    return a.stream == b.stream && a.atlas_frame == b.atlas_frame &&
        a.atlas_epoch == b.atlas_epoch && a.config_generation == b.config_generation &&
        a.revision == b.revision && a.tile.window != b.tile.window;
  }
  void commit(uint64_t frame, uint64_t ticks,
              const viewflow::vfgp::AtlasLayout& layout,
              const viewflow::vfgp::AtlasTile& tile) {
    if (keyboard.cancelled() && (history_.empty() || !ticks || !frame ||
        frame <= history_.back().atlas_frame || ticks <= committed_ticks_)) {
      keyboard.invalidate_cancelled();
      pointer.retire();
      return;
    }
    if (keyboard.cancelled() && !history_.empty() &&
        (!cancelled_binding_ || !recovery_lineage(*cancelled_binding_, layout, tile) ||
         tile.geometry_epoch < history_.back().tile.geometry_epoch ||
         tile.source_frame <= history_.back().tile.source_frame ||
         tile.placement_generation < history_.back().tile.placement_generation)) {
      // A VFGP6 confirmation binds the old and current stream, atlas epoch,
      // configuration and window exactly.  The pending current lineage must
      // also stay monotonic.  Once any of those values changes or regresses,
      // this suspension cannot become a recovery transaction.  Retire it
      // rather than retaining a misleading cancellation/drain notification.
      keyboard.invalidate_cancelled();
      pointer.retire();
    }
    if (!keyboard.cancelled() && keyboard.any() && !history_.empty()) {
      const auto& previous = history_.back();
      if (!recovery_lineage(previous, layout, tile) ||
          tile.geometry_epoch < previous.tile.geometry_epoch ||
          tile.source_frame <= previous.tile.source_frame ||
          tile.placement_generation < previous.tile.placement_generation) {
        // This includes an atlas/configuration lineage change, source replay,
        // or a window switch.  None can satisfy VFGP6's exact-old/current
        // checks, so this is a permanent retirement, not a recoverable pause.
        keyboard.cancel_for_geometry();
        keyboard.invalidate_cancelled();
        pointer.retire();
      } else if (tile.geometry_epoch > previous.tile.geometry_epoch) {
        // Placement generation (including an atlas-only move/resize) belongs
        // to the receiver composition.  It is carried by ordinary input
        // records but is not source geometry and must not manufacture a VFGP6
        // recovery requirement.  Only an advancing source geometry epoch can
        // enter the recoverable suspended state.
        keyboard.cancel_for_geometry();
        cancelled_binding_ = previous;
        if (!pointer.suspend_for_geometry()) pointer.retire();
      }
    }
    if (!keyboard.cancelled()) pointer.commit_presented(frame, ticks);
    committed_ticks_ = ticks;
    history_.push_back({frame, layout.stream, layout.geometry_epoch,
                       layout.config_generation, layout.revision, tile});
    if (history_.size() > 32) history_.pop_front();
  }
  const AtlasPointerBinding* find(uint64_t frame) const {
    const auto it = std::find_if(history_.rbegin(), history_.rend(),
        [frame](const auto& entry) { return entry.atlas_frame == frame; });
    return it == history_.rend() ? nullptr : &*it;
  }
  const AtlasPointerBinding* current_keyboard_binding() const {
    if (!keyboard_enabled() || history_.empty() || !pointer.committed_qpc()) return nullptr;
    return &history_.back();
  }
  const AtlasPointerBinding* current_binding() const {
    return history_.empty() ? nullptr : &history_.back();
  }
  // Called only for a trusted-local, source-post-cleanup confirmation. This is
  // not a network authorization parser. Exact current-frame matching prevents
  // a queued confirmation from reviving input on a later visual/geometry.
  bool confirm_geometry_recovery(const vfgp::InputRecoveryConfirmation& c,
      uint64_t now, uint64_t frequency, std::optional<uint32_t> message_tick = {}) {
    if (!keyboard_enabled_ || !physical_recovery_drained() ||
        !cancelled_binding_ || history_.empty() || !pointer.geometry_suspended_ ||
        !now || !committed_ticks_ || now < committed_ticks_ || !frequency ||
        c.frequency != frequency || c.deadline_qpc <= now ||
        !c.sequence || c.sequence <= recovery_sequence_ ||
        !c.grant_generation || c.grant_generation <= recovery_grant_) return false;
    const auto& old = *cancelled_binding_;
    const auto& fresh = history_.back();
    const bool rejected = c.rejection_kind == 2;
    if (rejected ? (!cancel_sequence_ || c.cancel_sequence != cancel_sequence_ ||
          c.previous_atlas_frame != old.atlas_frame || c.previous_source_frame != old.tile.source_frame) :
        (c.rejection_kind || cancel_sequence_)) return false;
    if (c.stream == vfgp::AtlasId{} || c.window == vfgp::AtlasId{} || c.stream == c.window ||
        c.stream != old.stream || c.stream != fresh.stream ||
        c.window != old.tile.window || c.window != fresh.tile.window ||
        !c.atlas_epoch || c.atlas_epoch != old.atlas_epoch || c.atlas_epoch != fresh.atlas_epoch ||
        !c.config_generation || c.config_generation != old.config_generation ||
        c.config_generation != fresh.config_generation ||
        !c.previous_epoch || c.previous_epoch != old.tile.geometry_epoch ||
        (rejected ? c.geometry_epoch < c.previous_epoch : c.geometry_epoch <= c.previous_epoch) || c.geometry_epoch != fresh.tile.geometry_epoch ||
        !c.atlas_frame || c.atlas_frame != fresh.atlas_frame || (rejected ? c.atlas_frame < old.atlas_frame : c.atlas_frame <= old.atlas_frame) ||
        !c.source_frame || c.source_frame != fresh.tile.source_frame || (rejected ? c.source_frame < old.tile.source_frame : c.source_frame <= old.tile.source_frame) ||
        !c.placement_generation || c.placement_generation != fresh.tile.placement_generation ||
        c.placement_generation < old.tile.placement_generation) return false;
    if (!pointer.resume_geometry(fresh.atlas_frame, now)) return false;
    keyboard.finish_confirmed_geometry_recovery();
    resume_qpc_ = now;
    keyboard_boundary_ms_ = message_tick;
    boundary_keys_.fill(false);
    boundary_buttons_ = 0;
    recovery_sequence_ = c.sequence;
    recovery_grant_ = c.grant_generation;
    cancelled_binding_.reset();
    cancel_sequence_ = 0;
    rejected_hover_only_ = false;
    notified_cancel_ = false;
    notified_drain_ = false;
    // Drop old lookup identities too; timestamped input before this recovery
    // boundary must not acquire authority from the newly enabled pointer.
    auto current = fresh;
    history_.clear();
    history_.push_back(current);
    return true;
  }
 private:
  static bool recovery_lineage(const AtlasPointerBinding& previous,
                               const viewflow::vfgp::AtlasLayout& layout,
                               const viewflow::vfgp::AtlasTile& tile) {
    return previous.stream == layout.stream && previous.tile.window == tile.window &&
        previous.atlas_epoch == layout.geometry_epoch &&
        previous.config_generation == layout.config_generation;
  }
  uint64_t focus_release_frame_{};
  bool wheel_enabled_{};
  bool keyboard_enabled_{};
  bool recovery_notifications_{}, notified_cancel_{}, notified_drain_{}, rejected_hover_only_{};
  std::deque<AtlasPointerBinding> history_;
  std::optional<AtlasPointerBinding> cancelled_binding_;
  uint64_t committed_ticks_{}, recovery_sequence_{}, recovery_grant_{}, cancel_sequence_{}, resume_qpc_{};
  std::optional<uint32_t> keyboard_boundary_ms_;
  std::array<bool,256> boundary_keys_{};
  uint32_t boundary_buttons_{};
};
} // namespace viewflow::windows_preview

#pragma once

#include "atlas_record.h"
#include <cstdint>
#include <optional>

namespace viewflow::windows_preview {
// Focused proxies forward Win immediately. A move consumes only the physical
// tail after emitting an explicit source release; that up must never replay.
class DesktopSourceWinKeys {
public:
  enum class Action { Pass, Forward, Suppress };
  uint8_t physical() const { return physical_; }
  Action event(uint8_t bit, bool down, bool may_start) {
    if (bit != 8 && bit != 128) return Action::Pass;
    if (!(physical_ & bit)) {
      if (!down || !may_start) return Action::Pass;
      physical_ |= bit;
      return Action::Forward;
    }
    const auto result = consumed_ & bit ? Action::Suppress : Action::Forward;
    if (!down) { physical_ &= uint8_t(~bit); consumed_ &= uint8_t(~bit); }
    return result;
  }
  void consume_for_move_or_owner_loss() { consumed_ |= physical_; }
private:
  uint8_t physical_{}, consumed_{};
};

// Pure policy for the Win key press held back from the shell. Losing the HWND
// retires its authority, but retains a drain-only key until its matching up.
class DesktopMoveKeyReservation {
public:
  enum class Action { Pass, Suppress, Replay };
  struct Decision { Action action; bool cancel_owner{}; uint32_t replay_key{}; };
  uint32_t key() const { return key_; }
  bool reserve(uint32_t key) {
    if (!key || key_) return false;
    key_ = key;
    used_ = false;
    return true;
  }
  void mark_used() { if (key_) used_ = true; }
  void owner_lost() { mark_used(); }
  Decision event(uint32_t key, bool down) {
    if (!key_) return {Action::Pass};
    if (key == key_ && down) return {Action::Suppress};
    if (key != key_ && !down) return {Action::Pass};
    const auto reserved = key_;
    if (used_) {
      if (key == key_) key_ = 0;
      return {key == reserved ? Action::Suppress : Action::Pass, true};
    }
    key_ = 0;
    return {Action::Replay, true, reserved};
  }
private:
  uint32_t key_{};
  bool used_{};
};

enum class DesktopMovePhase { Begin, Update, End, Cancel };
struct DesktopMoveEvent {
  DesktopMovePhase phase{};
  uint64_t drag_id{}, sequence{}, deadline_qpc{}, qpc_frequency{};
  vfgp::DesktopRect bounds;
};

// Win+left-drag is explicitly reserved locally. No titlebar inference is permitted:
// source decoration pixels remain pixels and carry no trusted hit-test data.
class DesktopMoveGesture {
public:
  bool win_down() { return !active_ && (armed_ = true); }
  bool win_up() {
    armed_ = false;
    return true;
  }
  bool armed() const { return armed_; }
  bool active() const { return active_; }
  bool input_suppressed() const { return input_suppressed_ || pointer_tail_; }
  bool draining_pointer() const { return pointer_tail_ && !active_; }
  bool drain_pointer(bool fresh_left_down, bool left_up, bool left_held) {
    if (!draining_pointer()) return false;
    // A new down proves the old release happened outside this proxy. A
    // release/neutral sample itself is swallowed before normal source input.
    if (fresh_left_down) { pointer_tail_ = false; return false; }
    if (left_up || !left_held) pointer_tail_ = false;
    return true;
  }
  // The source drops old grants at End; the next normal pointer selection is
  // deliberately eligible for a fresh grant. A V7 frame remains the sole way
  // to alter visual placement, but it is not a local-input deadlock gate.
  void authoritative_placement(uint64_t placement_generation,
                               const vfgp::DesktopRect &bounds) {
    if (input_suppressed_ &&
        placement_generation > base_placement_generation_ &&
        bounds.width_millidip && bounds.height_millidip)
      input_suppressed_ = false;
  }
  std::optional<DesktopMoveEvent> begin(uint64_t drag_id, uint64_t qpc,
                                        uint64_t frequency,
                                        uint64_t placement_generation,
                                        const vfgp::DesktopRect &bounds,
                                        int64_t pointer_x, int64_t pointer_y) {
    if (!armed_ || active_ || !drag_id || !qpc || !frequency ||
        !bounds.width_millidip || !bounds.height_millidip ||
        pointer_x < bounds.x_millidip || pointer_y < bounds.y_millidip)
      return {};
    const int64_t right =
        bounds.x_millidip + static_cast<int64_t>(bounds.width_millidip);
    const int64_t bottom =
        bounds.y_millidip + static_cast<int64_t>(bounds.height_millidip);
    if (pointer_x >= right || pointer_y >= bottom)
      return {};
    active_ = true;
    pointer_tail_ = true;
    input_suppressed_ = true;
    drag_id_ = drag_id;
    sequence_ = 1;
    base_placement_generation_ = placement_generation;
    base_ = bounds;
    grab_x_ = pointer_x - bounds.x_millidip;
    grab_y_ = pointer_y - bounds.y_millidip;
    return event(DesktopMovePhase::Begin, qpc, frequency, bounds);
  }
  std::optional<DesktopMoveEvent> update(uint64_t qpc, uint64_t frequency,
                                         int64_t pointer_x, int64_t pointer_y) {
    if (!active_ || !qpc || !frequency || pointer_x < INT64_MIN + grab_x_ ||
        pointer_y < INT64_MIN + grab_y_)
      return {};
    ++sequence_;
    auto desired = base_;
    desired.x_millidip = pointer_x - grab_x_;
    desired.y_millidip = pointer_y - grab_y_;
    return event(DesktopMovePhase::Update, qpc, frequency, desired);
  }
  std::optional<DesktopMoveEvent> end(uint64_t qpc, uint64_t frequency,
                                      int64_t pointer_x, int64_t pointer_y,
                                      bool cancel = false) {
    if (!active_ || !qpc || !frequency)
      return {};
    ++sequence_;
    auto desired = base_;
    if (!cancel) {
      if (pointer_x < INT64_MIN + grab_x_ || pointer_y < INT64_MIN + grab_y_)
        return {};
      desired.x_millidip = pointer_x - grab_x_;
      desired.y_millidip = pointer_y - grab_y_;
    }
    active_ = false;
    input_suppressed_ = false;
    if (!cancel) pointer_tail_ = false;
    return event(cancel ? DesktopMovePhase::Cancel : DesktopMovePhase::End, qpc,
                 frequency, desired);
  }

private:
  std::optional<DesktopMoveEvent> event(DesktopMovePhase phase, uint64_t qpc,
                                        uint64_t frequency,
                                        vfgp::DesktopRect bounds) const {
    // Bound each diagnostic/control record; the source rejects stale events.
    const uint64_t grace = (frequency / 4) ? frequency / 4 : 1;
    if (qpc > UINT64_MAX - grace)
      return {};
    return DesktopMoveEvent{phase,       drag_id_,  sequence_,
                            qpc + grace, frequency, bounds};
  }
  bool armed_{}, active_{}, input_suppressed_{}, pointer_tail_{};
  uint64_t drag_id_{}, sequence_{}, base_placement_generation_{};
  int64_t grab_x_{}, grab_y_{};
  vfgp::DesktopRect base_{};
};
} // namespace viewflow::windows_preview

#pragma once

#include <cstdint>
#include <algorithm>
#include <deque>
#include <optional>
#include "qpc_deadline.h"

namespace viewflow::windows_preview {

class AtlasPointerState;

struct PointerMotionEvent {
  uint64_t frame_identity{};
  int32_t x_pixels{};
  int32_t y_pixels{};
  int32_t viewport_width{};
  int32_t viewport_height{};
  uint64_t not_after_qpc{};
  uint64_t qpc_frequency{};
};

// Owns a committed visual identity, last coordinate, and explicitly enabled
// button transitions. It has no queue: callers emit returned events in order.
class PointerMotionState {
 public:
  explicit PointerMotionState(bool enabled, bool buttons = false)
      : enabled_(enabled), buttons_(enabled && buttons) {}

  bool buttons_enabled() const noexcept { return buttons_ && enabled_; }
  bool has_pressed_buttons() const noexcept { return pressed_ != 0; }
  bool wheel_key_state_matches(uint32_t keys) const noexcept {
    // PT_MOUSE wheel records carry Win32 MK_* button bits as well as modifiers.
    // Require exact agreement with admitted transitions; never invent a held key.
    const uint32_t expected = ((pressed_ & 1u) ? 0x01u : 0u) |
        ((pressed_ & 2u) ? 0x10u : 0u) | ((pressed_ & 4u) ? 0x02u : 0u) |
        ((pressed_ & 8u) ? 0x20u : 0u) | ((pressed_ & 16u) ? 0x40u : 0u);
    return buttons_enabled() && keys == expected;
  }
  uint64_t committed_qpc() const noexcept { return committed_qpc_; }
  void retire() noexcept { clear(); enabled_ = false; }

  // Call only after the new surface was bound and its VFGP identity committed.
  void commit_presented(uint64_t frame_identity, uint64_t committed_qpc = 0) {
    if (frame_identity == 0) {
      clear();
      return;
    }
    if (presented_ && (frame_identity <= *presented_ ||
        (committed_qpc_ && committed_qpc <= committed_qpc_))) {
      // An identity/clock reset cannot preserve evidence from the old timeline.
      // Do not silently establish a new timeline for an active button session.
      retire();
      return;
    }
    presented_ = frame_identity;
    committed_qpc_ = committed_qpc;
    if (committed_qpc) {
      history_.push_back({frame_identity, committed_qpc});
      if (history_.size() > 32) history_.pop_front();
    } else {
      history_.clear();
    }
    previous_.reset();
  }

  // An expired/unpresented frame cannot replace the current visible identity.
  void reject_unpresented(uint64_t) noexcept {}

  // Called by WM_DESTROY before the HWND is released.
  void clear() noexcept {
    geometry_suspended_ = false;
    rejected_physical_ = 0;
    rejected_invalid_ = false;
    presented_.reset();
    committed_qpc_ = 0;
    previous_.reset();
    pressed_ = 0;
    history_.clear();
  }

  std::optional<PointerMotionEvent> client_move(int32_t x_pixels, int32_t y_pixels,
                                                 int32_t viewport_width,
                                                 int32_t viewport_height) {
    if (!enabled_ || !presented_ || viewport_width <= 0 || viewport_height <= 0 ||
        x_pixels < 0 || y_pixels < 0 || x_pixels >= viewport_width ||
        y_pixels >= viewport_height)
      return std::nullopt;
    Coordinates current{x_pixels, y_pixels, viewport_width, viewport_height, *presented_};
    if (previous_ && *previous_ == current)
      return std::nullopt;
    previous_ = current;
    return PointerMotionEvent{*presented_, x_pixels, y_pixels, viewport_width,
                              viewport_height};
  }

  std::optional<PointerMotionEvent> timed_client_move(int32_t x, int32_t y,
      int32_t width, int32_t height, uint64_t event_qpc, uint64_t now_qpc,
      uint64_t frequency, uint64_t operation_budget_ns = 33'333'334) {
    // Select the visual that was committed at the OS event timestamp, not the
    // visual current when the message finally reaches this UI thread.
    if (!enabled_ || !event_qpc || event_qpc > now_qpc)
      return std::nullopt;
    const auto visual = std::find_if(history_.rbegin(), history_.rend(),
        [event_qpc](const Commit &entry) { return entry.qpc <= event_qpc; });
    if (visual == history_.rend()) return std::nullopt;
    const auto deadline = qpc_deadline::deadline_from_sender_remaining(
        event_qpc, now_qpc, frequency, operation_budget_ns);
    if (deadline.status != qpc_deadline::Status::Ok)
      return std::nullopt;
    if (width <= 0 || height <= 0 || x < 0 || y < 0 || x >= width || y >= height)
      return std::nullopt;
    Coordinates current{x, y, width, height, visual->frame};
    if (previous_ && *previous_ == current) return std::nullopt;
    previous_ = current;
    return PointerMotionEvent{visual->frame, x, y, width, height,
                              deadline.deadline_ticks, frequency};
  }

  std::optional<PointerMotionEvent> timed_client_button(int32_t x, int32_t y,
      int32_t width, int32_t height, uint64_t event_qpc, uint64_t now_qpc,
      uint64_t frequency, uint32_t button, uint32_t transition) {
    if (!buttons_ || !enabled_ || button < 1 || button > 5 ||
        (transition != 1 && transition != 2)) return std::nullopt;
    const uint32_t bit = 1u << (button - 1);
    if ((transition == 1) == ((pressed_ & bit) != 0)) return std::nullopt;
    // Ordered transitions use an operation watchdog. The 33ms motion target
    // must not discard a click while its frame/selection/preceding ACK settles.
    // Down/up at unchanged coordinates are distinct events, never deduplicated.
    auto previous = previous_;
    previous_.reset();
    auto event = timed_client_move(x, y, width, height, event_qpc, now_qpc, frequency, 5'000'000'000);
    if (!event) { previous_ = previous; return std::nullopt; }
    if (transition == 1) pressed_ |= bit;
    else pressed_ &= ~bit;
    return event;
  }

  std::optional<PointerMotionEvent> timed_client_wheel(int32_t x, int32_t y,
      int32_t width, int32_t height, uint64_t event_qpc, uint64_t now_qpc,
      uint64_t frequency, int32_t vertical, int32_t horizontal) {
    if (!buttons_ || !enabled_ || (!vertical && !horizontal) ||
        vertical < -32768 || vertical > 32767 || horizontal < -32768 || horizontal > 32767)
      return std::nullopt;
    // Each wheel message is a distinct action even at an unchanged point.
    // No pressed-button state or residual scrolling is synthesized here.
    const auto previous = previous_;
    previous_.reset();
    auto event = timed_client_move(x, y, width, height, event_qpc, now_qpc, frequency, 5'000'000'000);
    if (!event) previous_ = previous;
    return event;
  }

 private:
  friend class AtlasPointerState;
  // Only the atlas owner's validated recovery path can resume this suspension.
  // A subsequent retire/clear permanently removes the capability to resume.
  bool suspend_for_geometry() noexcept {
    if (!enabled_ || pressed_) return false;
    clear();
    geometry_suspended_ = true;
    enabled_ = false;
    return true;
  }
  bool suspend_for_rejection() noexcept {
    if (!enabled_ || geometry_suspended_) return false;
    rejected_physical_ = pressed_; // Preserve admitted pressed_ until confirmation.
    rejected_invalid_ = false;
    previous_.reset();
    history_.clear();
    committed_qpc_ = 0;
    presented_.reset();
    geometry_suspended_ = true;
    enabled_ = false;
    return true;
  }
  bool rejected_physical_drained() const {
    return geometry_suspended_ && !rejected_invalid_ && !rejected_physical_;
  }
  bool observe_rejected_button(uint32_t button, uint32_t transition) {
    if (!geometry_suspended_ || rejected_invalid_ || button > 5 ||
        (button ? (transition != 1 && transition != 2) : transition != 0)) {
      rejected_invalid_ = true;
      return false;
    }
    if (!button) return true; // Motion does not create authority or synthesize ups.
    const uint32_t bit = 1u << (button - 1);
    if ((transition == 1) == bool(rejected_physical_ & bit)) { rejected_invalid_ = true; return false; }
    if (transition == 1) rejected_physical_ |= bit;
    else rejected_physical_ &= ~bit;
    return true;
  }
  bool resume_geometry(uint64_t frame, uint64_t ticks) {
    if (!geometry_suspended_ || !frame || !ticks) return false;
    clear();
    enabled_ = true;
    commit_presented(frame, ticks);
    return true;
  }
  uint32_t rejected_physical_{};
  bool rejected_invalid_{};
  bool geometry_suspended_{};
  struct Coordinates {
    int32_t x{};
    int32_t y{};
    int32_t viewport_width{};
    int32_t viewport_height{};
    uint64_t frame{};
    constexpr bool operator==(Coordinates const&) const = default;
  };
  bool enabled_ = false;
  bool buttons_ = false;
  uint32_t pressed_ = 0;
  std::optional<uint64_t> presented_;
  uint64_t committed_qpc_ = 0;
  struct Commit { uint64_t frame; uint64_t qpc; };
  std::deque<Commit> history_;
  std::optional<Coordinates> previous_;
};

}  // namespace viewflow::windows_preview

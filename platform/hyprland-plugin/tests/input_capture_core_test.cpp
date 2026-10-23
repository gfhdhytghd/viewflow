// SPDX-License-Identifier: GPL-3.0-only
#include "input_capture_core.hpp"

#include <array>
#include <cstdint>

using namespace viewflow::hyprland;

static_assert(windowPointerRouteAllowed(CapturePhase::LOCAL));
static_assert(windowPointerRouteAllowed(CapturePhase::EDGE_ARMED));
static_assert(!windowPointerRouteAllowed(CapturePhase::CAPTURE_PENDING));
static_assert(!windowPointerRouteAllowed(CapturePhase::REMOTE_CAPTURED));

int main() {
  CaptureSeat seat;
  int windows = 0, macos = 0;
  if (!seat.claim(&windows) || seat.claim(&macos)) return 70;
  seat.release(&macos); // An unrelated disconnect must retain Windows input.
  if (seat.available(&macos)) return 71;
  seat.release(&windows);
  if (!seat.claim(&macos) || seat.available(&windows)) return 72;
  seat.release(&macos);
  const std::array three{
      InputRect{0, 0, 0, 3072, 1728},
      InputRect{1, 3072, 390, 1920, 1200},
      InputRect{2, 3072, 1590, 1539, 1155},
  };
  // Only an explicitly returned remote gesture may cross to an adjacent
  // remote while held. A local drag, another destination, and a later press
  // cannot reuse that ownership.
  seat.returnHeldLeft(&macos, three[2], 3300, 1589);
  if (!seat.inheritsHeldLeft(&windows, three[1]) || seat.inheritsHeldLeft(&macos, three[1]) ||
      seat.inheritsHeldLeft(&windows, three[0])) return 170;
  InputCaptureCore continuation;
  if (!continuation.configureRemote(three[1])) return 171;
  (void)continuation.button(272, true);
  continuation.observePosition(3300, 1589, three);
  if (continuation.observeMotion(0, -2)) return 172; // Ordinary local held drag.
  continuation.allowHeldLeftReturn(seat.inheritsHeldLeft(&windows, three[1]));
  continuation.observePosition(3300, 1589, three);
  if (!continuation.observeMotion(0, -2)) return 173;
  InputLeaseIdentity inherited{.generation=1}; inherited.targetDevice[0]=1;
  if (!continuation.activate(inherited)) return 174;
  (void)continuation.button(272, true); // Ordered inherited press after activate.
  if (!continuation.button(272, false)) return 175;
  if (!continuation.release().buttons.empty()) return 176;
  seat.clearHeldLeft();
  if (seat.inheritsHeldLeft(&windows, three[1])) return 177;
  continuation.allowHeldLeftReturn(false);
  (void)continuation.button(272, true);
  continuation.observePosition(3300, 1589, three);
  if (continuation.observeMotion(0, -2)) return 178;
  seat.returnHeldLeft(&macos, three[2], 3300, 1589);
  seat.forget(&macos);
  if (seat.inheritsHeldLeft(&windows, three[1])) return 179;
  InputCaptureCore mac;
  if (!mac.configureRemote(three[2])) return 73;
  mac.observePosition(3071.5, 1660, three);
  if (!mac.observeMotion(2, 0)) return 74;
  (void)mac.release();
  mac.observePosition(3300, 1589.5, three);
  if (!mac.observeMotion(0, 2)) return 75;
  (void)mac.release();
  mac.observePosition(3300, 1600, three);
  auto crossed = mac.observeMotion(0, 2);
  if (!crossed || !crossed->entryPosition) return 76;

  // A forced local return cancels pending activation; a late reply must not
  // recapture the seat. Clearing drag continuation also rejects delayed returns.
  InputCaptureCore detached;
  if (!detached.configureRemote(three[1])) return 180;
  detached.observePosition(3071.5, 500, three);
  if (!detached.observeMotion(2, 0)) return 181;
  (void)detached.release();
  InputLeaseIdentity lateActivation{.generation=20}; lateActivation.targetDevice[0]=1;
  if (detached.activate(lateActivation) || detached.phase()!=CapturePhase::LOCAL) return 182;
  (void)detached.button(272, true);
  detached.armDragReturn(20);
  detached.finishDragReturn();
  if (detached.canContinueDrag(20)) return 183;

  const std::array monitors{
      InputRect{1, 0, 0, 100, 100},
      InputRect{2, 100, 0, 100, 100},
  };

  InputCaptureCore core;
  core.observePosition(99.5, 50, monitors);
  if (core.phase() != CapturePhase::LOCAL)
    return 1; // The shared edge must stay local.

  core.observePosition(0.5, 25, monitors);
  if (core.phase() != CapturePhase::EDGE_ARMED ||
      core.observeMotion(1.5, 0).has_value())
    return 2;
  const auto candidate = core.observeMotion(-1.5, 0);
  if (!candidate || candidate->edge != protocol::Edge::LEFT ||
      candidate->monitorId != 1 || candidate->edgePosition != 0.25 ||
      core.phase() != CapturePhase::CAPTURE_PENDING)
    return 3;

  InputLeaseIdentity lease{.generation = 7};
  lease.targetDevice[0] = 0xaa;
  if (!core.activate(lease) || !core.captured())
    return 4;
  if (!core.button(0x110, true) || !core.key(30, true))
    return 5;

  const auto released = core.release();
  if (!released.lease || released.lease->generation != 7 ||
      !released.buttons.contains(0x110) || !released.keys.contains(30) ||
      core.phase() != CapturePhase::LOCAL)
    return 6;

  if (!core.physicalButtonHeld(0x110)) return 160; // Return retains the actual held gesture.
  (void)core.button(0x110, false);
  if (core.physicalButtonHeld(0x110)) return 161;
  (void)core.key(30, false);
  core.observePosition(199.5, 99.5, monitors);
  const auto bottom = core.observeMotion(0.25, 2.0);
  if (!bottom || bottom->edge != protocol::Edge::BOTTOM)
    return 7; // Direction resolves a corner unambiguously.

  if (core.activate(lease))
    return 8; // A released generation cannot be replayed.
  lease.generation = 8;
  lease.targetDevice.fill(0);
  if (core.activate(lease))
    return 9; // The zero device ID is reserved.

  bool enabled = true;
  EnabledStateLease enabledState;
  enabledState.suppress(enabled);
  if (enabled || !enabledState.active() || !enabledState.permitted(enabled))
    return 10;
  enabled = true;
  enabledState.suppress(enabled);
  if (enabled)
    return 11; // Suppression must survive an external flag rewrite.
  enabledState.restore(enabled);
  if (!enabled || enabledState.active())
    return 12; // Repeated suppression must preserve the first saved state.

  enabled = false;
  enabledState.suppress(enabled);
  if (enabledState.permitted(enabled)) return 131; // Suppression never upgrades configured denial.
  enabled = true;
  if (enabledState.permitted(enabled)) return 132; // External rewrite does not upgrade the saved permission.
  enabledState.restore(enabled);
  if (enabled)
    return 13; // A keyboard that was disabled before capture stays disabled.

  // Two routes can consume the same shortcut or IME event. Neither may save
  // the other's temporary suppression as the configured state.
  for (const bool original : {false, true}) {
    for (const bool reverse : {false, true}) {
      enabled = original;
      EnabledStateLease first, second;
      first.suppress(enabled);
      second.suppress(enabled);
      if (enabled || first.permitted(enabled) != original || second.permitted(enabled) != original)
        return 133;
      auto& early = reverse ? second : first;
      auto& late = reverse ? first : second;
      early.restore(enabled);
      if (enabled || early.active() || !late.active()) return 134;
      late.suppress(enabled);
      late.restore(enabled);
      if (enabled != original || late.active()) return 135;
    }
  }
  // Device destruction drops all leases without touching the dead flag. A
  // new keyboard at the same address must get a fresh original state.
  enabled = false;
  {
    EnabledStateLease destroyed;
    destroyed.suppress(enabled);
  }
  enabled = true;
  enabledState.suppress(enabled);
  enabledState.restore(enabled);
  if (!enabled) return 136;

  // Explicit owned rectangle bypasses only that output's shared seam.
  InputCaptureCore spatial;
  const std::array desktop{
    InputRect{1, 0, 0, 3072, 1728},
    InputRect{6, 3072, 390, 1920, 1200},
    InputRect{7, 3072, 1590, 1920, 1080},
  };
  if (!spatial.configureRemote(desktop[1])) return 14;
  spatial.observePosition(3071.5, 800, desktop);
  if (!spatial.observeMotion(2, 0)) return 15;
  InputLeaseIdentity spatialLease{.generation = 1};
  spatialLease.targetDevice[0] = 1;
  (void)spatial.button(0x110, true);
  if (spatial.activate(spatialLease)) return 16;
  (void)spatial.button(0x110, false);
  if (!spatial.activate(spatialLease)) return 17;
  (void)spatial.key(29, true);
  (void)spatial.key(56, true);
  if (spatial.emergencyEscape()) return 18;
  (void)spatial.key(1, true);
  if (!spatial.emergencyEscape()) return 19;
  (void)spatial.release();
  spatial.observePosition(3071.5, 1600, desktop);
  if (spatial.observeMotion(2, 0)) return 20; // Other headless output remains local.
  spatial.observePosition(3071.5, 200, desktop);
  if (spatial.observeMotion(2, 0)) return 21; // No cross-seam outside overlap.
  spatial.observePosition(4991.5, 800, desktop);
  if (spatial.observeMotion(2, 0)) return 22; // Remote output is never source.
  auto changed = desktop;
  changed[1].width = 1919;
  spatial.observePosition(3071.5, 800, changed);
  if (spatial.observeMotion(2, 0)) return 23; // Stale remote rectangle fails closed.
  auto gap = desktop[1];
  gap.x += 0.5;
  auto gapDesktop = desktop;
  gapDesktop[1] = gap;
  if (!spatial.configureRemote(gap)) return 24;
  spatial.observePosition(3071.5, 800, gapDesktop);
  if (spatial.observeMotion(2, 0)) return 25; // A subpixel gap is not adjacency.

  InputCaptureCore dragged;
  if (!dragged.configureRemote(desktop[1])) return 26;
  (void)dragged.button(272, true);
  (void)dragged.key(125, true);
  dragged.observePosition(3400, 900, desktop);
  if (dragged.observeMotion(1, 0)) return 27;
  (void)dragged.button(272, false);
  dragged.observePosition(3400, 900, desktop);
  if (dragged.observeMotion(1, 0)) return 28; // Wait for the modifier too.
  (void)dragged.key(125, false);
  dragged.observePosition(3400, 900, desktop);
  const auto afterDrag = dragged.observeMotion(-1, 0);
  if (!afterDrag || !afterDrag->entryPosition ||
      (*afterDrag->entryPosition)[0] != 3400 || (*afterDrag->entryPosition)[1] != 900 ||
      afterDrag->monitorId != 1 || afterDrag->anchorX != 3071) return 29;

  // A decoded proxy may arrive after native release, but only the original
  // physical press can resume. Encoded End/new press cannot revive the ticket.
  InputCaptureCore late;
  (void)late.button(272, true);
  (void)late.release();
  late.armDragReturn(42);
  if (!late.canContinueDrag(42) || late.canContinueDrag(41)) return 31;
  (void)late.button(272, false);
  (void)late.button(272, true);
  if (late.canContinueDrag(42)) return 32;
  late.armDragReturn(43);
  late.finishDragReturn();
  if (late.canContinueDrag(43)) return 33;
  late.armDragReturn(44);
  late.resetConnection();
  if (late.canContinueDrag(44)) return 34;

  return 0;
}

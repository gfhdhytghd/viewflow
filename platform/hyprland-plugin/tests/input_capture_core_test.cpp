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

  (void)core.button(0x110, false);
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

  return 0;
}

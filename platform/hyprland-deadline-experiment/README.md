# Viewflow render-deadline experiment

An optional Hyprland 0.56 plugin prototype. It is disabled on load, has no
persistent configuration, and does not replace the existing Viewflow or
Hymission plugins. Physical 6K measurements show a latency improvement at 3 ms lead, but the
60 fps / one-frame goal remains unmet; this is not a persistent default.

The normal output loop begins composition just after the preceding page flip.
This experiment delays the selected output's `CMonitorFrameScheduler::onFrame`
until an estimated next refresh minus a configurable lead (initially 3 ms),
allowing newer client buffers to enter the same composition. Repeated frame
requests coalesce without pushing the original deadline later.

The estimate uses observed presentation-event arrival on the compositor's
steady clock. It is not a hardware-vblank timestamp or photon measurement.
Missing, stale, future or already-late timing renders immediately. Refresh-mode
changes reset timing. Actual adaptive sync, tearing, direct scanout, DPMS-off
and the alternative render scheduler use the original path. A pending page flip
at timer expiry waits for its next normal frame event instead of double-committing.
Disabling or unloading cancels the timer and services an owed render if possible.

Build and policy test:

```sh
cmake -S platform/hyprland-deadline-experiment -B build/hyprland-deadline-experiment -DCMAKE_BUILD_TYPE=Release
cmake --build build/hyprland-deadline-experiment -j4
ctest --test-dir build/hyprland-deadline-experiment --output-on-failure
```

Once explicitly loaded in a test compositor, the Lua controls are:

```lua
hl.plugin.viewflow_deadline.set("WAYLAND-1", true, 3)
hl.plugin.viewflow_deadline.status()
hl.plugin.viewflow_deadline.set("WAYLAND-1", false, 3)
```

Status exposes armed/fired/coalesced counts, pending work and a fallback mask:
1 disabled monitor, 2 DPMS off, 4 missing output, 8 actual adaptive sync,
16 tearing, 32 direct scanout, 64 alternative scheduler enabled.

The isolated test runner is
`docs/evidence/6k60-20261008/run-deadline-nested.py`. It creates a private Weston
headless parent and nested Hyprland, with a separate runtime directory and no
connection to the user's Wayland display. The forced nonexistent seatd socket
prevents the nested compositor from acquiring the user's DRM seat. Systemd
environment import/notification is disabled. Child processes are cleaned up.

The installed Aquamarine Wayland backend required test-only compatibility fixes
for Weston: negotiated compositor/xdg-shell versions, an optional absent input
seat, and flushing the initial output request. Those changes are isolated in
`build/aquamarine-nested`, loaded only by the child through LD_LIBRARY_PATH;
`nested-aquamarine-version-negotiation.patch` records them. No system library was
changed. This environment validates hook/timer lifecycle, not DRM performance.

Verified so far: policy tests, ABI-checked load, enabled frame processing,
coalescing, disable with pending work, and unload while pending. Physical-output
6K timing is recorded in `docs/evidence/6k60-20261008/README.md`: the first
3 ms lead comparison reduced sampled capture-to-feedback p50 from 34.9 to
24.6 ms. A 1.5 ms lead regressed to 38.5 ms and 4.5 ms measured 26.0 ms.
These runs do not establish sustained 60 fps or photon latency.

Status also reports observed presentation intervals above 1.5 refresh periods,
timer lateness totals/maxima, and original render-call CPU duration totals/maxima.
Long intervals can indicate missed refresh, idle output, or event delivery delay;
they are not hardware vblank counters. CPU render time does not measure GPU
completion. These diagnostics do not change scheduling or session availability.

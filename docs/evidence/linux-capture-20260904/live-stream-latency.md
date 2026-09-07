# Decorated live-stream measurements, 2026-09-04

Hyprland PID 4832, 0.56.2, Dolphin address 0x56057975e2b0.
Source pixels 2674x2514, 26,889,744 RGBA bytes; logical size 1337x1257.
Three-second `hyprcapture_stream_probe` runs, Release build. These are
capture CLOCK_MONOTONIC to Linux imported-pixels ages, **not** network,
decode, blur, or physical-display latency. Original timestamps are preserved.

| Stream PBO configuration | Frames | P50 ms | P95 ms | Maximum ms |
| --- | ---: | ---: | ---: | ---: |
| Three slots, render-full backpressure | 81 | 70.492 | 73.632 | 78.278 |
| Three slots, requested SO_SNDBUF 4096 | 81 | 70.801 | 74.227 | 83.985 |
| Two slots, requested SO_SNDBUF 4096 | 96 | 59.540 | 62.240 | 62.973 |
| One slot, bounded latest-only Rust import | 96 | 59.941 | 63.161 | 70.098 |

The small socket queue limits backlog but did not materially lower the steady
state age. Two slots improved measured age; one slot did not improve it
further in this run. These short sequential measurements are not a controlled
performance benchmark. Recording's independent three-slot PBO is unchanged.

Intervening probes produced zero frames. Later instrumentation proved the
timer still ran 180 times in three seconds, but no readback occurred. Root
then verified active workspace 2 while the selected Dolphin remained mapped
on workspace 5: the stream called `shouldCaptureWindow`, which delegates to
the compositor's current-screen `shouldRenderWindow` filter. This is an
incorrect visibility condition for an explicitly selected remote window.
The scoped fix uses `isLiveWindowCaptureTarget` for explicit streams only.
After hot-loading it, root verified active workspace 3 while Dolphin remained
on workspace 5: the three-second probe received 123 frames. That run's source
size had changed to 1936x1732 (13,412,608 bytes), with P50 39.814ms, P95
43.604ms and maximum 47.611ms. It proves background-workspace capture, but
the size change prevents attributing the lower age solely to the LUT change.

The two-frame end-to-end requirement is **not met**. No deadline was relaxed.
No Windows real-time visual acceptance follows from these measurements.

## Absolute scheduling follow-up

After the absolute-cadence fix (capture timestamps unchanged), the same
1936x1732 size produced 179 frames in three seconds, P50 31.983ms, P95
34.045ms, maximum 38.722ms. This is approximately 60fps instead of work time
plus a full 16.666ms sleep. It still excludes network/decoder/display costs
and does not establish the end-to-end requirement.

## Timestamp attribution correction

The former timestamp preceded draining/finalizing the previous frame, although
the matching new render began afterward. It now samples immediately before
the matching render, still including that render and all its readback,
postprocessing, transport and import time. Stored frame timestamps are never
refreshed during later drain/send. This is a measurement correction, not an
optimization. After loading it, the same size yielded 179 frames/3s, P50
25.428ms, P95 28.589ms, maximum 37.938ms. The maximum alone still exceeds
two 60Hz frames, even before network/decode/display.

## Independent early drain

A pending-only 1 ms timer now checks the stream PBO fence without waiting
or rendering another frame; the original render cadence remains 60 Hz.
Original capture timestamps are retained. Same Dolphin and physical size
1936x1732: preceding baseline 179 frames/3s, P50 25.365912 ms,
P95 29.228711 ms, max 38.273274 ms. After build-codex rebuild, 14/14
CTest pass and plugin reload: 180 frames/3s, P50 19.161265 ms,
P95 23.406001 ms, max 27.932461 ms. Configerrors was empty.
This is capture-to-import only, not cross-host deadline acceptance.

After extracting and testing drain poll lifecycle (pending arm, ready disarm,
stale callback rejection, stopped rejection), build-codex and 14/14 CTest
passed again. Reloaded exact rebuilt plugin, configerrors empty: 180 frames,
same dimensions, P50 19.172358 ms, P95 22.063912 ms, max 32.158804 ms.
Real GPU fence behavior is covered by this probe, not by the pure helper tests.

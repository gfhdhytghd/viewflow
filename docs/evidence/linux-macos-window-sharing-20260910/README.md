# Linux to Mac window sharing — 2026-09-10

The user requested switching the right display to Mac, enabling its HID input
bridge, and bringing up Linux → Mac window sharing first. The later cursor
report (entry in the middle of the Mac screen) was corrected before finishing
this deployment. Existing Windows and cross-display workspace changes remain.

## Deployed behavior

- HDMI `input2` acknowledged by the existing switch tool; the persisted HDMI
  and Viewflow target are `macos`.
- Linux viewport HEADLESS-158 is 3840×2400 physical pixels, scale 2, at logical
  (3072,390). Mac reports 1920×1200 logical points, 3840×2400 backing pixels.
  Both use 1920×1200 for cursor output; no resolution change was needed.
- `viewflow-macos-input.service` reuses the existing live headless output and
  prepares the current
  compositor config. The HID service now follows `desktop-drag/config` instead
  of the stale standalone `macos-cursor.json`; it starts and stops with the Mac
  input target. DriverKit v12 is activated with ABI 2/native profile 1 and the
  native multitouch device attached. Read-only status progressed from 5911 to
  8179 submitted reports during the user's physical use; errors remained zero.
  This HID path covers the Magic Trackpad. Keyboard/absolute cursor placement
  continue through the existing Quartz receiver.
- `macos-window-share-linux.py` automatically selects visible Linux windows
  intersecting the Mac viewport, supervises one capture stream per window, and
  retires windows that close or leave that viewport. It leaves window placement
  and focus to the user/window managers. Linux GPU capture → NVENC → paired QUIC
  → VideoToolbox → Metal → native macOS window is active.
- A QUIC listener accepts concurrent window sources. Closing or recovering one
  source retains unrelated native windows. The supervisor runs as
  `viewflow-macos-windows.service`, attached to the Mac input target. It uses
  installed binaries under `/home/wilf/.local/lib/viewflow/macos/`, protecting
  the GPU-enabled source from Cargo integration tests that rebuild binary
  targets without native capture features.
- Mac GUI LaunchAgent `org.viewflow.window-presenter` listens on port 44220,
  using the existing Mac pairing certificates and `present --scale 2
  --origin-x -3072 --origin-y -390`. No new pairing identity was created.

## Mac performance deployment

- The macOS native source and presenter now expose `--performance-mode
  frame-rate|latency` and `--performance-status`. The deployed LaunchAgent uses
  `latency` mode.
- Latency mode limits queued capture frames and Metal command buffers to one,
  uses user-interactive dispatch QoS, keeps VideoToolbox real-time with frame
  reordering disabled, requires hardware encode/decode, and prefers encoding
  speed with an expected frame rate, 24 Mbit/s target, and two-second GOP.
  Frame-rate mode retains deeper queues and three in-flight command buffers.
- Source and presenter log queue/coalescing state so late work can be measured
  and replaced locally without treating 33 ms as a disconnect boundary.
- The current VideoToolbox runtime rejected the optional maximum-frame-delay
  property with status `-12900`; that property is reported as unsupported and
  is not claimed as active. The rest of the latency configuration remains
  active.
- The Mac binary was rebuilt with Xcode beta, passed codec and Metal self-tests,
  and was atomically deployed at
  `/Users/linhaikuo/viewflow-window-share.O2SjgD/viewflow-macos-windows-multi`.
  Its SHA-256 is
  `3954bcceb6594d33250efef07504d1ba658bf0ae3911e2bf5883d60e9171fcc7`; the
  previous binary is retained as the `before-perf` backup.
- An eight-second read-only smoke run used the existing Linux source and sent no
  mouse, keyboard, focus, window-move, or gesture input. The Mac log confirmed
  `performance-mode=latency`, two drawables, one command buffer,
  user-interactive QoS, and a presented frame with no coalescing.

## Cursor correction

An attempted receiver update changed the ad-hoc designated code hash. The Mac
then explicitly rejected actual user position events with `InjectionFailed` /
`macOS event posting permission missing`, while the HID touch stream continued.
The previously authorized receiver was restored at its original executable
path; its installed and backup SHA-256 both equal
`ce2a408dbef7a4daeb4b31eebe09abc0ea3ef70bd875d6d1cb4e318c3f02401b`.
The newer build remains separate pending normal macOS authorization.

After restoration, actual user crossings logged accepted first positions at
x=45 and x=42 logical points near the left edge. A later read-only Quartz cursor
sample was (148.2030029,145.6529999), matching the latest accepted wire position
(148203,145653) millidips. This verifies the observed coordinate application;
physical entry feel remains for the user to assess.

## Verification

- Four Rust checks pass: peer config roles, both TLS role assignments with
  delayed ordered input, native failure recovery on the same connection, and
  two simultaneous source connections with independent shutdown/EOF cleanup.
- Pure viewport selection covers scaled and rotated outputs, partial crossing,
  edge-only contact, hidden workspaces, hidden windows, reverse-proxy exclusion
  and missing output. The native Linux input helper builds and its help CTest
  passes; no synthetic input was sent.
- Mac native build passes; generated H.264/HEVC encode/decode, alpha, resize and
  Metal color/orientation self-tests pass.
- The existing Linux terminal on workspace 8 is captured. Mac WindowServer
  reports an on-screen native proxy; Metal completion logs reach frame 3120.
  `mac-runtime.json` contains the read-only window bounds and cursor sample.
- Native source logs still include 33 ms performance misses while retaining the
  session. The Windows-derived optimizations are active, but this smoke run does
  not prove that the end-to-end latency target is met.
- Continuous held-button handoff, drag/resize, keyboard and gesture behavior
  are user-operated acceptance items. Mac → Linux is the subsequent direction
  and requires Mac Screen Recording authorization; its source is not enabled.

Build/test logs and installed binary hashes are alongside this record. No real
mouse, keyboard, focus or gesture input was synthesized. No changes were
committed or pushed.

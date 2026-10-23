# macOS blur and performance, 2026-09-10

This work continues the earlier Mac performance and shortcut deployment, preserving
its current changes. The receiver now places a passive AppKit behind-window blur
under the decoded Metal surface. Its cropped source-alpha mask is cached exactly;
opaque and empty tiles disable backdrop work. The foreground retains its original
lossless alpha. Background and surface subviews do not intercept proxy input.

The public AppKit material follows native window/desktop changes without screen
capture permission. It is **not** a numerical port of the Windows Hyprland Dual
Kawase shader: AppKit controls its kernel and tint. Exact Windows shader parity and
physical visual acceptance remain unproven. An SSH `screencapture` attempt could
not obtain a display image; no OS permission was changed.

## Performance changes and measurements

- Scalar `L8` alpha replaces the per-frame BGRA alpha expansion; the immutable
  bitmap is retained through Core Image/Metal consumers.
- Source pixel buffers use CoreVideo pools for four recent geometries. In-flight
  buffers retain independent ownership; no buffer is recycled while in use.
- A presenter-wide command budget prevents multiple windows from blocking AppKit
  on the same queue. Pending windows rotate fairly. GPU completion schedules
  further work; a retired proxy's completion cannot clear a replacement proxy's
  draw state. Encoded reference frames remain ordered.
- Linux window sources accept `--performance-mode frame-rate|latency`; the Mac
  supervisor is deployed with `VIEWFLOW_WINDOW_PERFORMANCE_MODE=latency` and uses
  the existing commit-driven capture path. Omission retains frame-rate mode.

An ABBA generated-pixel test at **3840x2400**, 40 measured samples per run after
four warm-ups, measured alpha reconstruction plus completed GPU output. The
baseline's median was **6.0992 / 5.0199 ms**; the new path's median was
**3.4685 / 3.1901 ms**. P95 was **9.3310 / 8.6336 ms** before and
**3.8735 / 3.8350 ms** after. Raw per-frame samples and both benchmark source inputs
are included. This is a stage benchmark, not end-to-end display latency or proof
of 4K60. Pool reuse was not independently attributed by this experiment.

## Recovery correction

A real reconnect exposed eight stale plugin capture slots, all with no living
UNIX socket listener. Those exact stream IDs were explicitly stopped, with
matching receipts in `orphan-recovery.json`. Source exhaustion was causing Mac
EOF/restarts with both the previous binary and the candidate.

The plugin now reaps retired streams before admitting a new source and treats
cleanup of an already-removed stream as idempotent. Twelve consecutive real GPU
capture/disconnect cycles passed against the deployed plugin, exceeding the
8-active-stream capacity without exhaustion. The probe receives and closes DMA
buffer/fence descriptors without reading pixels or fabricating release receipts;
all test streams are explicitly stopped afterward. No input was injected.

## Validation and deployment

- Native arm64 Xcode beta build with `-Wall -Wextra -Werror` passed.
- H.264/HEVC codec, alpha, resize and Metal color/orientation tests passed.
- New presenter test covers cropped mask values, unchanged cache identity,
  invalidation, opaque/empty suppression and passive hit testing; opens no windows.
- All eight capture CTests passed, as did the offline Mac viewport-selection test.
- Mac installed binary:
  `/Users/linhaikuo/viewflow-window-share.O2SjgD/viewflow-macos-windows-multi`,
  SHA-256 `a1af12856f5e9d5dde9ea1294ae75b6fe2acc3ea2784b48046df022ff3a5bc83`.
  This final receiver is built with `-O2 -DNDEBUG`. The source app retains its
  earlier Release build to preserve its OS permission identity.
  Original backup: `viewflow-macos-windows-multi.before-blur-pool-20260910`,
  SHA-256 `3a04400657a5a1d4aae3a56a5e7de5b709cb0c999d54cc01dae34209a1d4e4df`.
- The GUI LaunchAgent and existing paired Linux source reconnected. Runtime logs
  report hardware decoding, a cached **3836x2300** AppKit backdrop mask, and more
  than **1000** completed Metal frames after deployment. Completion is not a
  physical scanout measurement.
- Linux capture plugin installed at `build/desktop/capture/viewflow-capture.so`,
  with `viewflow-capture.before-mac-recovery-20260910.so` backup. GPU-enabled source
  installed under `/home/wilf/.local/lib/viewflow/macos/`, with a dated backup.

The cursor/HID receiver and OS permissions were not changed. Mouse, keyboard,
gesture, focus, and physical visual acceptance remain user-operated. No commits
or pushes were requested or performed.


## Release, input worker and native decode follow-up

The initially deployed native executable was built without optimization. The
final receiver uses `-O2 -DNDEBUG`; the CMake default is now Release for a
single-configuration generator. Linux and Mac/Windows peer deployments use Rust
Release builds. Build mode was a real deployment difference, not an attributed
speedup in the earlier alpha-only experiment.

The serial input worker now decompresses alpha and constructs the immutable Core
Image graph before handing it to AppKit. The synchronous block captures a frame
pointer and alpha span, avoiding copies of large frame vectors. AppKit still owns
native window/mask updates and GPU submission. Translucency classification stops
once a fractional alpha sample is found; exact mask equality remains checked.

VideoToolbox now returns native NV12 IOSurfaces instead of requiring BGRA output.
Core Image handles color conversion in the composition path. Codec tests check
both decoder outputs for H.264/HEVC across resize; the Metal test also verifies
asymmetric color, lossless alpha and orientation with NV12. No new CPU pixel
conversion was added to the production path.

`decoder-benchmark.mm` generates 44 H.264 frames at **3840x2400** once, then
measures four decode-plus-alpha-composition runs in BGRA/NV12/NV12/BGRA order.
Each run discards four warm-ups and locks the rendered output to await completed
GPU work. Median BGRA: **16.3474 / 15.8458 ms**; median NV12:
**10.4909 / 9.5797 ms**. P95 BGRA: **17.1382 / 19.3025 ms**; NV12:
**16.5238 / 11.4019 ms**. Raw samples are in `decoder-benchmark.log`. Live
receivers continued running during the test, so this is an observed stage
comparison under concurrent load, not an isolated throughput guarantee or
end-to-end latency measurement.

The old `coalesced` counter incorrectly counted an arriving image while the
previous image was merely executing on the GPU. It now counts only an image
replacing another image that has not been submitted. Completion statistics report
five-second aggregate window-submission rates and Metal GPU durations. The BGRA
worker run included successive **60.01 / 59.98** completion/s samples with zero
replaced pending images. NV12 also reached 60 completion/s; other intervals were
lower, and source activity and concurrent benchmark load varied. These logs do
not establish a fixed frame rate or physical scanout timing.

Windows/Mac pairing, source enrollment, idle keepalive and the three-device
preparation are documented in [window-mesh.md](window-mesh.md). The user explicitly
deferred Screen Recording authorization and requested continued optimization.
Real Mac→Windows capture remains pending; no permission dialog or input was
synthesized.


## Stable alpha reuse and AppKit handoff

The receiver reuses decoded alpha and its immutable Core Image mask when the
encoded alpha bytes and geometry are identical. A changed alpha payload or even
an equal-area resize rebuilds the mask. Each proxy tracks the alpha revision and
crop rectangle, so a crop move still updates its backdrop and stable opaque/empty
crops skip repeated scanning. Tests cover these cases without opening windows.

For changed alpha, NSData wraps a shared immutable vector instead of adding a
separate full-size data copy. Core Image may upload or copy internally; this is
not a claim of zero-copy GPU storage. The pixel test releases the producer's
reference before rendering and checks the resulting color/alpha/orientation.

Live samples progressed from about 2.3 ms mean alpha reconstruction with copying,
to about 1.0 ms with shared storage, to **0.049 ms** on a stable cached window.
The cached sample covered 300 frames with `alpha-updates-total=1`; source content
and scheduling were live, so these are diagnostic observations rather than a
controlled isolated benchmark. Raw snapshots are `alpha-copy-runtime.log`,
`alpha-owned-runtime.log` and `alpha-cache-runtime.log`.

The input worker now queues its AppKit handoff in common run-loop modes and
explicitly wakes that run loop, retaining synchronous completion before releasing
frame references. This also allows processing during native tracking modes.
It does not synthesize an event or input. Apple documents the explicit wakeup
requirement for [CFRunLoopPerformBlock](https://developer.apple.com/documentation/corefoundation/cfrunloopperformblock(_:_:_:)).
The receiver's shutdown drain continues to service the run loop until the input
worker and outstanding GPU commands have finished.


After the explicit run-loop wakeup, one steady 301-frame sample reported mean
**2.032 ms decode, 0.092 ms alpha, 0.007 ms main-thread wait and 1.732 ms
presentation call**, with **60.00** completed window submissions/s. The preceding
cached-alpha implementation still showed roughly 4.7–5.1 ms main-thread waiting.
These CPU stage averages are separate from the roughly 5.8 ms GPU duration and
must not be added to assert end-to-end latency. `final-runtime.log` preserves
these observations and later samples.

The final native executable also passed an actual presenter-loop EOF/drain test
in both performance modes using four generated H.264 frames stripped to zero
tiles. Both runs exited 0, created no proxy windows and emitted zero return input
bytes. The test and raw JSONL are included as `empty-window-drain-test.*`.

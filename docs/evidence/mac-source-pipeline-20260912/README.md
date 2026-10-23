# Mac-to-Linux source pipeline — 2026-09-12

The live source was spending main-thread time in VideoToolbox completion,
Core Image rendering and exact BGRA image comparison. `source-before.txt`
contains the initial two-second read-only process sample. `source-after.txt`
is the intermediate offloaded version, before the GPU alpha follow-up.

## Changes

- One accepted image job on a dedicated interactive-QoS thread. Main-thread
  capture snapshots and ordered input continue while color, alpha, encoding
  and packing execute. New captures replace only unsubmitted state.
- Submitted frame versions/geometry advance only after successful output
  enqueue. Failed work remains eligible; shutdown services completion and
  final capture callbacks before releasing the source.
- Exact BGRA comparison runs on the capture worker after retaining a short
  main-thread snapshot. It no longer scans entire images on the input thread.
- A full-extent single window uses its retained capture buffer directly,
  eliminating the intermediate atlas render.
- Metal extracts exact alpha bytes into a shared buffer concurrently with
  color rendering. Completion precedes CPU consumption and resource reuse.
  Unsupported/failed extraction falls back to the CPU path; diagnostics can
  force it with `VIEWFLOW_MACOS_GPU_ALPHA=0`.
- A fixed thread retains the CoreVideo/Metal caches. A serial GCD queue used
  in the first iteration migrated between threads and duplicated these caches.

VideoToolbox still completes one frame at a time on this worker. Window
inventory/geometry polling still uses the main loop. This does not claim parity
with Windows' dual-task encoder or eliminate every source of latency.

## Validation

Strict native arm64 Release build passed. H.264/HEVC, NV12/BGRA, resize, exact
alpha and color/orientation self-tests passed with GPU extraction both enabled
and disabled. Alpha tests include all 256 values, odd row dimensions and
size changes. The serial-worker test passed on Linux and Mac: bounded pending
work, fixed-thread execution, ordering and shutdown drain. No input is posted
by these tests.

`split-benchmark.mm` renders generated pixels into a 2560x1440 IOSurface,
measures split plus completed color output, and discards eight warm-ups before
40 samples. ABBA uses the same implementation with GPU alpha disabled/enabled:

| Run | Median ms | P95 ms (floor-index) |
| --- | ---: | ---: |
| CPU A1 | 6.5884 | 16.3595 |
| GPU B1 | 3.2579 | 15.8754 |
| GPU B2 | 4.3626 | 14.6833 |
| CPU A2 | 4.8699 | 15.5235 |

Other real streams remained active. These stage results show lower medians but
do not establish a stable tail-latency improvement or end-to-end FPS/latency.
The optional VideoToolbox max-frame-delay property still reports `-12900` on
this host; no claim is made that that property was accepted.

## Deployment

Final native helper SHA-256:
`2b67ce0816b225a76ddb99227c9095a3d17f9519caa63744393c33fc11fdc8a2`.
Installed app and actual source-2441-38679-linux helper match. Final source PID
21429 was verified after restart; native capture, GPU alpha and output continued.
The app passed deep strict signature verification. The running main app and
desktop input process were retained; only Mac-to-Linux source helpers restarted.
The final update started from the current installed bundle and checked that its
main executable and native helper had not changed since the backup.

Mac build and rollback bundles are under `~/viewflow-mac-pipeline-20260912/`;
`pre-r4.app` is the immediate previous version, and `previous.app` predates this
work. User-operated drag/scroll/click and physical end-to-end acceptance remain
separate from this build and process evidence.

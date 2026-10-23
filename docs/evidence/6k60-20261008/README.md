# 6K60 IVSHMEM optimization, 2026-10-08

Target: 6144 × 3456 at sustained 60 fps, capture-to-presentation within 16.67 ms.
**Target not yet demonstrated end to end.** These initial numbers measure an
Intel D3D11 offscreen render target → IVSHMEM → NVIDIA offscreen texture. They
exclude WGC capture, the production QUIC control path, window composition,
Wayland presentation and display scanout. Do not add independent percentiles
and label the result end-to-end latency.

## Measurements

| Variant | Host copy p50/p95 ms | Upload completed p50/p95 ms | Received / requested |
|---|---:|---:|---:|
| Original copy + GL upload, unpaced | 8.040 / 12.665 | 14.355 / 21.552 | 189 / 300 |
| CUDA pageable, unpaced | 7.680 / 13.338 | 10.629 / 15.850 | 206 / 300 |
| Register CPU copy each frame, unpaced | 7.977 / 13.038 | 5.611 / 8.740 | 275 / 300 |
| Shared slot lease + per-frame registration | 0.002 / 0.002 | 8.083 / 10.771 | 286 / 300 |
| Shared lease + persistent prefix registration | 0.001 / 0.002 | 2.356 / 3.630 | 283 / 300 |
| Streaming producer + persistent registration, 60 fps, 60 s | 0.002 / 0.003 | 1.999 / 3.070 | 3594 / 3600 |

Last run: first 60 source frames are warmup; subsequent **3540 received,
0 obsolete, 60.000 delivered fps**. Six startup frames were overwritten while
initializing CUDA/registrations. The run overlapped a Windows release build
for part of its duration; retain this as a loaded exploratory run, not an
isolated timing comparison. A paced vs unpaced source changes queuing, so
source readback figures across those modes are not an A/B latency comparison.

Source paced run: staging-copy enqueue to published slot p50 9.797 ms,
p95 11.444 ms; within that, CPU publication p50 5.348 ms, p95 6.974 ms.
Original unpaced publication p50 8.177 ms, p95 9.509 ms. Upload timings include
`glFinish`, unlike production CPU submit logging. Performance fixture changes
the whole render target with GPU ClearRenderTargetView each frame; it does not
claim to model WGC or arbitrary application rendering.

## Changes

- Exclusive shared-slot leases remove the host's 85 MB/frame CPU copy. Slot
  state remains reading until all owners release it. Overwritten queue entries
  release promptly; mapping ownership survives asynchronous reader shutdown.
- NVIDIA CUDA/GL interop pins only used bank prefixes, at most four registered
  ranges, and copies directly to the GL texture. Registration reuse removes
  per-frame page-pin overhead. Resize grows a registration when needed; pages
  are released at receiver teardown. This is actual workload/high-water usage,
  not startup allocation of four GiB. CUDA failures select the existing GL path.
- Each window owns its retained GPU snapshot before the source lease is released.
  Later expose/resize uses that snapshot, never released shared pixels.
- Large Windows publications use aligned SSE2 non-temporal writes, with an
  sfence before slot release. Small frames use memcpy. Pitched/unaligned tails
  retain exact contents.
- Retained alpha revisions advance only when alpha or geometry changes. Color
  animation no longer rebuilds the input region or refits the shadow every frame.
- Host logs separate alpha extraction, window preparation and drawing CPU time;
  the over-target counter now uses 16.67 ms. It is not a session cutoff.

## Verification / deployment

Linux 11/11 tests passed, including actual NVIDIA retained-snapshot rendering,
shared-slot lifetime/overwrite tests and odd-width/pitched streaming copies.
Windows 19/19 tests passed. `correctness-6k-*` validates every CPU pixel and
three GPU RGBA samples of each accepted 6K frame; the deliberately unpaced
correctness run accepted five frames and rejected three obsolete references.
No desktop input or focus was injected.

Installed host binary `~/.local/lib/viewflow/ivshmem/viewflow_linux_reverse`,
backup `.before-6k-perf`. Host drop-in `20-raw-upload.conf` enables
`VIEWFLOW_SHM_LEASE=1` and `VIEWFLOW_RAW_CUDA=persistent`; its source is
`deploy/linux/viewflow-ivshmem-nvidia.conf`.
Windows `fusion-20261007/build-16k/Release/viewflow_windows_reverse.exe` copied
to active `build-banks/Release`; backup `.before-6k-perf`. VM was not restarted.

## Reproduction

`run-probe.py` records both outputs and restores the stopped IVSHMEM services
in `finally`. It is an evidence runner for this host/VM setup, not a portable
installer. Build both shared probes first. Example from repo root:

```sh
PROBE_TAG=repeat-60 PROBE_ARGS='6144 3456 3600 60 --performance --streaming' \
VIEWFLOW_SHM_LEASE=1 VIEWFLOW_RAW_CUDA=persistent \
python3 docs/evidence/6k60-20261008/run-probe.py
```

Correctness mode: replace arguments with
`6144 3456 8 0 correctness --streaming`. The normal fixture and CPU/GPU pixel
checks remain enabled in that mode. The probes share production readback,
shared-slot and GPU upload implementations.

## Remaining

- Correlate capture/source timestamps to host presentation on a common measured
  clock, including uncertainty. CPU submit is not GPU completion/presentation.
- Run an actual WGC 6K moving fixture through the production transport and
  retained-window composition; inspect steady-state tail latency and cadence.
- Measure Wayland presentation feedback and scanout separately. Physical photon
  timing cannot be inferred from the offscreen benchmark.

## Follow-up: actual window CPU and presentation measurements

The first deployed pipeline exposed another bottleneck: alpha extraction for
4608 × 3840 atlases took about 7–8 ms median. SSE2 extraction plus a three-buffer
reuse pool reduced this to about 3.4–3.7 ms in subsequent passive logs at the
same atlas size. Tests exhaustively compare scalar expected alpha across all
16 input alignments and lengths 0..1023, with output sentinels. This is a passive
before/after observation, not a controlled moving-6K benchmark.

Retained-alpha tests also assert that identical updates do not advance the
revision. Alpha/body changes still invalidate input regions and shadow hints.

`wp_presentation` feedback is now bound when available, using its advertised
clock for both the submission and presented timestamps. At most 128 feedback
objects and 4096 timing samples are retained; missing or delayed measurements
never stall the stream. `draw_to_present` and `commit_to_present` are local-host
metrics, not capture-to-photon. Flags are reported (the union in each interval),
but outputs are not yet separated. Some observed intervals include only vsync
flag 1, others include hardware-completion flag 4; hardware-clock flag 2 was
not observed. Feedback therefore must not be described as a photon timestamp.

Immediately flushing Wayland after EGL swap removes synchronous geometry IPC
from the commit-delivery critical path. Subsequent passive logs still include
commit-to-presentation intervals above 16.67 ms, sometimes above 25 ms; the one
frame end-to-end goal remains unmet. Do not claim the flush alone solved the
compositor scheduling delay. The live window/atlas was also resized by the
user, so the later 3072 × 3584 figures are not same-size comparisons.

Next measurements must separate DP-4 and HEADLESS-1 feedback, correlate source
capture timestamps (frame PTS currently marks atlas submission, not WGC
capture), and run a controlled moving fixture through the real presentation
path. The deployed service remains active; no user input was injected.

## Output attribution and cross-system clock correlation

The receiver now binds `wl_output` names and groups presentation samples by
`sync_output`. Union **and intersection** of presentation flags are logged.
This confirmed that the very short feedback often came from HEADLESS-1, while
DP-4 had distinctly longer feedback. A surface spanning outputs receives one
presentation feedback result; these are not independent observations of both
outputs for every frame. The live Word window extended beyond DP-4's logical
bounds, so a user-operated move fully onto DP-4 was requested for the physical
screen test. No window/focus/input was moved automatically for this test.

`viewflow_shared_probe.exe --clock` is a native QPC responder without D3D or
IVSHMEM initialization. `measure-clock.py` exchanges 100 requests over the
existing authenticated SSH connection. Each response timestamp lies between
host send and host receive. The best initial RTT was 0.225849 ms (half-width
0.1129245 ms). This measures an offset interval, not an assumption that Windows
and Linux monotonic clocks start at the same epoch.

`VIEWFLOW_PRESENTATION_TRACE=1` adds at most 16 sampled timestamp rows per
output per five-second report. Rows include window id, atlas-submit QPC time,
presentation clock id, presented timestamp and flags. Windows opt-in diagnostic
logging now records the exact WGC timestamp/version copied for each window,
joined by atlas PTS and window id. It does not use a newer capture callback's
timestamp after the atlas copy. The native source was rebuilt and deployed;
backup `.before-capture-timing`. Temporary source diagnostic environment is
set in `windows-linux.ps1` (backup `.before-capture-timing`), and the host trace
is enabled by `30-presentation-trace.conf`. Remove these temporary profiling
settings when the ongoing investigation ends.

`analyze-presentation.py` joins the two logs within the calibration interval.
It separates atlas-submit delay from WGC capture delay, deduplicates observed
capture timestamps, and excludes captures predating calibration from the
new-capture metric. Static cached content must not be reported as seconds of
pipeline latency. The collected interval had **no new WGC capture**, so it
provides no moving-capture FPS or capture latency proof.

`capture-analysis.json`: DP-4 had only three calibrated idle samples, atlas
submission to presentation 30.25–36.49 ms; HEADLESS-1 had 51 samples, median
14.72 ms. Endpoint offset changed 42.166 microseconds; the combined measured
interval half-width was 0.123558 ms. Endpoint agreement does not establish a
hardware bound on unobserved drift. Neither interval proves 6K60 or the final
one-frame objective. The new measurement distinguishes these gaps explicitly.

### Reversible VFR scheduling experiment

Live `hyprctl descriptions -j` showed `debug:vfr=false`, default true,
`render:new_render_scheduling=false`, and tearing disabled. A 25-second
true/false/true sequence changed only live `debug:vfr`, then restored the
original false value in `finally`; read-back confirmed the restoration. No
persistent config or focus/input was changed. Phase times and raw journal are
saved as `vfr-ab*.json` / `vfr-journal.jsonl`.

This was **inconclusive**, not an accepted optimization: with VFR true,
feedback was attributed to HEADLESS-1 and there were no comparable DP-4 report
windows. The false phase had four DP-4 samples, with report median commit
latencies 20.266 and 29.993 ms. Do not infer DP-4 latency from the absence of
feedback or from HEADLESS-1 timing, and do not average report percentiles.
The original compositor setting remains restored.

## Parallel producer publication

A persistent sleeping helper copies the second half of large BGRA atlases;
the producer copies the first half. Both execute their own sfence and join
through a mutex/condition variable before the slot becomes ready. There is no
per-frame thread creation or background busy-poll. Only streaming frames at
least 16 MiB use the helper; small menus retain the serial path. Worker creation
occurs before taking a slot and falls back to serial on allocation/thread-start
failure. This avoids stranding a writing slot if a helper cannot be created.

Same 6144 × 3456, 900 frames at 60 fps, serial / parallel / serial / parallel:

| Run | Publish p50 / p95 ms | Readback + publish p50 / p95 ms | Receiver upload p50 / p95 ms |
|---|---:|---:|---:|
| serial | 5.380 / 6.888 | 9.837 / 11.394 | 1.933 / 2.455 |
| parallel | 3.982 / 4.566 | 8.445 / 9.081 | 2.276 / 3.373 |
| serial repeat | 6.473 / 8.230 | 10.978 / 12.981 | 2.133 / 3.478 |
| parallel repeat | 4.394 / 6.965 | 8.912 / 12.160 | 2.178 / 3.915 |

All four received all 840 post-warmup frames at approximately 60 fps. Each had
eight obsolete initialization frames. Median producer time consistently fell;
tail timings and receiver upload varied with system load. Do not claim every
percentile improved, or add these percentiles as end-to-end latency.

Separate 6K correctness run at 10 fps accepted **20/20**, zero obsolete, exact
CPU pixel validation plus GPU RGB/alpha samples. The persistent-worker test
also repeats odd-height, unaligned-row/pitched copies with changing content
and verifies every row after completion. Linux 11/11 and Windows 19/19 passed;
logs saved as `parallel-*-tests.log` / `parallel-windows-build-tests.log`.

Enabled in the Windows production source; both binaries deployed with backups
`.before-parallel-copy`. The user service is active and real windows continue
presenting. This reduces a transport component; the physical-screen one-frame
latency objective remains unproven and observed presentation waits still
exceed the target. No compositor settings, input or focus were changed in
this round.

## Exact raw atlas and actual moving-window fixture

The shared-memory atlas now rounds to actual pixel extents, preserving its
existing delayed shrink policy. Encoded atlas alignment remains unchanged.
A single full-resident 6144×3456 window previously occupied 6144×4096; removing
that padding reduces transferred pixels by 18.5% of the old allocation and
allows the existing direct-source staging path to skip atlas clear/composition.
A direct-source mutex is explicitly released after enqueue, before per-source
first-submission bookkeeping. Windows capacity tests include exact 6K, growth,
delayed shrink and small popup extents. Windows 19/19 tests passed before the
final lock-release/logging adjustment; that final adjustment compiled successfully.

`viewflow_motion_fixture` creates a 6144×3456 DComposition alternating-color
surface for at most 60 seconds, with NOACTIVATE, transparent hit testing and
alpha 1/255. The fixture is diagnostic, not a representative opaque application
acceptance test. The scoped Hyprland runtime rule pins it to DP-4 without focus.
`run-motion.py` coordinates the task, service reconnect, clock calibration and
read-only client/focus inventories in one process; doing these manually lost
most of the first 30-second fixture to tool-call delays. The source PID filter
is temporary and restored by the Windows wrapper's finally block.

Before exact sizing, isolated motion source submitted 54.512 fps; receiver
accepted about 42–45 fps (6144×4096). An initial exact-size run submitted
59.278 fps, but only about eight seconds connected to the receiver, so it is
not a sustained presentation result. The longer `exact-motion-repeat-*` run
accepted 236–244 frames per five seconds, with alpha median 6.33–7.35 ms.
A Linux build overlapped the end of that repeat, so it is a loaded exploratory
baseline rather than a controlled before/after experiment.

## AVX2 alpha extraction

Runtime CPU dispatch uses a 32-pixel AVX2 extraction loop, with explicit lane
reordering after packs. SSE2/scalar fallback remains available; both dispatched
and baseline functions are tested for offsets 0–31, lengths 0–1023, exact alpha
values and destination sentinels. The offscreen retained-surface test continues
to verify partial/transparent/resize snapshot behavior. Linux 11/11 passed.

The `avx2-motion-*` run accepted 249–257 frames per five seconds (~50 fps),
alpha median 5.75–5.83 ms and p95 7.28–8.02 ms. Source submissions were 58.258
fps. This is an encouraging component improvement, not proof of causality for
all throughput differences under varying system load. Local isolated 6K alpha
microbenchmarks also favored AVX2 slightly (median 3.61–3.65 ms vs 3.75–3.96 ms).
The deployed receiver uses runtime dispatch, with `.before-avx2-alpha` backup.

Both coordinated runs retained the same host active-window address before,
during and after, and the Windows fixture reported foreground_unchanged=1.
The fixture client was pinned, at 0,0 and 3072×1728 logical pixels on monitor 1.
However feedback in these runs was attributed to HEADLESS-1, despite DP-4
client placement. Possible preview/compositor involvement remains unresolved;
these timings cannot establish physical DP-4 latency. The one-frame and 60 fps
end-to-end goal remains unmet. Normal source wrapper and host service were
restored after each run; no mouse or keyboard input was injected.

## Overlap CPU alpha extraction with GPU upload

`AlphaUploadOverlap` owns one sleeping worker, with at most one synchronous
job. For raw atlases of at least four million pixels, CPU alpha extraction
runs concurrently with main-thread GPU texture upload. The caller retains
both spans and the IVSHMEM lease until both operations finish, including when
upload throws. GL is never used from the worker. Worker creation failure uses
the existing serial path; smaller menus do not start or wake the worker.
`VIEWFLOW_DISABLE_ALPHA_OVERLAP=1` permits same-binary comparison. Tests verify
changing full alpha planes, repeated reuse, invalid extents, empty jobs, and
joining on upload exceptions. Linux **12/12** passed. Final subsequent change
only corrects the diagnostic overlap flag for small frames and compiled.

The first on/off comparison changed stage accounting: `alpha_*` includes the
concurrent upload wait when enabled, while `draw_*` no longer includes upload.
Do not interpret the alpha-stage increase as a standalone extraction slowdown.
The follow-up logs measure each frame's actual total directly, without adding
stage percentiles:

| Run | Five-second report total medians | Report total p95 range | Accepted frames / 5 s |
|---|---:|---:|---:|
| overlap-total-disabled | 11.78–12.03 ms | 13.87–15.23 ms | 246–255 |
| overlap-total-enabled | 10.69–11.30 ms | 13.03–15.26 ms | 238–253 |

Thus the median receiver component improves by roughly 1 ms, but these runs
show **no throughput gain** and no across-the-board tail improvement. Geometry
synchronization median is about 0.53–0.59 ms, p95 below 1 ms in these intervals.
The receiver optimization is deployed; `.before-alpha-overlap` is the backup.
No temporary disable drop-in remains.

## Physical-output measurement: DPMS was off

Read-only live monitor inspection found **DP-4 dpmsStatus=false**, while
HEADLESS-1 remained on. This explains why the preceding near-transparent
fixture runs yielded no DP-4 feedback despite correct geometry. The earlier
preview/compositor hypothesis was unproven. `run-motion.py` now records monitor
state as well as clients/focus. `run-physical-motion.py` powers only DP-4 on,
checks read-back, runs the fixture, and restores the original power state in
finally. Evidence confirms false → true during measurement → false afterward.
This does not inject input or change focus.

With DP-4 powered and the optimization enabled (`physical-overlap-*`), exact
6144×3456 acceptance was **218–229 per five seconds (~44–46 fps)**. Source
fixture submission was 53.847 fps. Receiver CPU-submit medians were
10.03–10.39 ms. DP-4 commit-to-present report medians were 21–27 ms and p95
about 31–32 ms. Clock-calibrated sampled WGC-provided timestamp to first
observed presentation was **p50 58.46 ms, p95 74.89 ms** (79 samples); atlas
submission to presentation was 58.19 / 76.34 ms. Observed clock endpoint
envelope uncertainty was ±0.091 ms. These are Wayland feedback measurements,
not photon timing or a bound on unseen clock drift.

A reversible `debug:vfr=true` physical-output test (`physical-vfr-*`) produced
WGC-to-presentation p50 55.91 ms / p95 72.72 ms (80 samples). It did not remove
the roughly 28 ms commit wait in its later report windows. This is insufficient
to adopt a global scheduling change; the original **vfr=false** was restored
and read back. Initial script assumed the option JSON used `int`; this version
uses `bool`. That error was immediately corrected with explicit false
restoration before rerunning the experiment. No persistent compositor config
was changed.

Both physical runs retained the same active host window before/during/after;
Windows reported foreground_unchanged=1. The normal Windows task/filter and
Linux service were restored. The real 6K60 / ≤16.7 ms end-to-end goal remains
**unmet**; powered-output measurements are the relevant baseline going forward.
The next optimization candidate is reducing the full BGRA CPU read required
for alpha, rather than treating the offscreen 60 fps transport probe as proof
of the full pipeline.

## GPU alpha extraction with exact unchanged-plane reuse

The NVIDIA profile now enables `VIEWFLOW_GPU_ALPHA=1` for large raw atlases.
`GpuAlpha` samples the already uploaded BGRA texture and packs four alpha bytes
into each RGBA8 output texel. Only the alpha plane is downloaded. Partial final
rows use bounded scratch storage; odd widths/heights are supported. Source
extent changes invalidate reuse even if the packed framebuffer extent is the
same (for example 1×1 → 2×1 with zero alpha).

For steady alpha, the shader compares each packed vector against the previous
GPU alpha texture and discards identical fragments. An exact
GL_ANY_SAMPLES_PASSED result determines whether anything changed. No hash,
opacity assumption, freshness cutoff or sampled-pixel heuristic is used.
Unchanged alpha retains the previous immutable CPU plane. Changed alpha is
fully downloaded and copied to the previous GPU texture. Color uploads and
retained RGBA snapshots continue updating every frame. RetainedAlpha skips its
CPU comparison only for the same immutable source plane **and** identical
atlas/body/resident geometry; atlas crop changes still update it.

GPU resources are per decode lane and allocated at actual dimensions. On an
extraction error, that lane disables the GPU alpha path and recovers through
CPU extraction without ending the session. Small atlases retain the CPU path.
The portable GL uploader is still supported, but GPU alpha is only enabled in
the existing NVIDIA/CUDA profile: its standalone GL-upload benchmark did not
show the same performance advantage.

Validation: Linux **13/13** tests passed. The new offscreen test compares every
alpha byte with varied values, repeated content changes and unchanged frames,
1×1/3×7/17×9/257×513/6144×3456/31×2 extents, destination sentinels, shrinking,
and zero-alpha source length changes sharing the same packed extent. Both
CUDA and portable GL upload paths passed pixel validation. Retained-alpha tests
also verify that identical source data with a changed atlas crop cannot reuse
the previous destination. No desktop input or focus was injected.

Standalone NVIDIA CUDA upload + alpha, medians in ms:
serial CPU 6.205; CPU/upload overlap 4.433; full GPU readback 4.010;
GPU unchanged-plane reuse **2.553**. These are offscreen component results.

Powered DP-4 6144×3456 moving-window diagnostics:

| Run | Receiver total report medians | Accepted frames | WGC-to-feedback sampled p50 / p95 |
|---|---:|---:|---:|
| physical-gpu-alpha-off | about 10.36–10.50 ms | roughly 43–46 fps | 60.83 / 80.58 ms |
| physical-gpu-alpha-on (always download) | 8.48–9.35 ms | roughly 39–43 fps | 56.12 / 74.53 ms |
| physical-gpu-alpha-cached | **3.04–3.53 ms** | **46.51–50.66 fps** | **46.81 / 64.32 ms** |

These sequential system-load-dependent runs are diagnostic, not a tightly
controlled causal estimate. The always-download version did not improve
throughput. Exact unchanged-plane reuse removes the large repeated CPU scan
and readback in this constant-alpha, changing-color workload. The cached run's
receiver total p95 was 3.91–4.86 ms; prepare median was about 0.006 ms.
Source fixture submission was 55.844 fps, so sender/capture scheduling and
presentation wait still require work. CPU report logs now include actual
interval_ms and accepted_fps rather than assuming every report spans exactly
five seconds. Older approximate rates should not be used as a precise FPS gate.

The first off/on script stopped after its off phase because a transient
connector reprobe made DP-4 briefly disappear during DPMS restoration. Normal
stream service and temporary test environment were restored; no on-phase
result was fabricated. The physical runner now awaits stable authoritative
DPMS read-back and records cleanup state even on failure. The resumed and
cached runs completed. Cached-run evidence records DP-4 off → on during test →
off afterward and the same host active-window address throughout; the Windows
fixture also reported foreground_unchanged=1.

The final cached implementation and NVIDIA profile are deployed; the receiver
backup is `.before-gpu-alpha`. Normal Windows source PID filtering is restored,
the fixture task is idle, and the normal service is active. **6K60 and one-frame
end-to-end latency remain unmet**. All latency figures above are sampled
Wayland presentation feedback, not photon measurements.

Final GPU-alpha hardening explicitly disables depth/stencil/cull/rasterizer
and sample-coverage rejection before the exact comparison, so inherited GL
state cannot produce a false unchanged result. Tests inject full face culling,
empty scissoring and disabled color writes before extraction; all 13 tests
passed again (`gpu-alpha-state-tests.log`). The hardened binary is deployed.

## Producer readback timing and rejected single-in-flight experiment

`analyze-source.py` decomposes existing producer QPC records. For the cached
GPU-alpha run, readback enqueue → output packing was p50 17.668 ms / p95
32.572 ms. Serialization was 0.005 / 0.007 ms and pipe write was 0.015 / 0.022
ms. The large component precedes serialization; optimizing transport headers
would not address it.

Readback diagnostics now additionally record observed enqueue-to-ready delay,
Map duration and shared-memory publication duration. This is CPU-observed GPU
readiness, including polling/scheduling delay, **not** a GPU timestamp query.
The original two-slot staging behavior remains the default. An opt-in
`VIEWFLOW_SHM_SINGLE_READBACK=1` allows a one-in-flight experiment and checks
availability again at enqueue; it never abandons a claimed staging frame.
The frame-slot format and four IVSHMEM banks remain unchanged.

| Experiment | Observed ready p50 / p95 | Map p50 / p95 | Publish p50 / p95 |
|---|---:|---:|---:|
| physical-readback-timing | 15.574 / 29.954 ms | 0.004 / 0.009 ms | 6.172 / 11.262 ms |
| physical-single-readback | 10.090 / 17.999 ms | 0.003 / 0.008 ms | 5.654 / 6.967 ms |

These simple readback summaries include the run's final metadata frame; the
`*-source-analysis.json` files additionally restrict analysis to matched 6K
capture records. Sequential load varied: source fixture submission was 54.274
and 58.629 fps respectively, and receiver report rates were 35–47 and 47–50
fps. These are not proof of an isolated causal throughput benefit.

Crucially, limiting the queue shifted delay earlier: WGC-provided capture stamp
→ enqueue median changed from -0.331 ms to +6.010 ms. Slightly negative WGC
stamp offsets already occur in this API and must not be interpreted as physical
negative latency. The same-run DP-4 WGC-to-feedback sampled median changed from
49.510 to **53.034 ms**, despite atlas-to-feedback improving from 49.843 to
44.901 ms. The single-in-flight option is therefore **not enabled** in normal
use. The next work must address capture-to-enqueue scheduling and actual GPU
readiness, rather than optimizing only time after atlas submission.

Windows native source and probe compiled; Windows 19/19 tests passed. Both
experiments kept host focus and Windows foreground unchanged. DP-4 was powered
only for measurement and restored off. The Windows wrapper was verified free
of both source-PID and single-readback temporary overrides; normal host service
is active. The deployed source has diagnostics and the inactive experiment
switch, with `.before-readback-timing` binary backup.

A secondary hypothesis remains unverified: Windows can ignore a window-owning
process's timer-resolution request when it is fully occluded. See Microsoft's
[timeBeginPeriod documentation](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod).
The code already calls timeBeginPeriod(1); no timer-policy change was made on
this hypothesis. Actual loop sleep and inventory timings should be measured
before adopting such a change. The 6K60 / one-frame goal remains unmet.

## Separate producer loop delay from GPU execution

Opt-in loop diagnostics now report bounded samples every five seconds for main
work, requested 1 ms sleep, and window inventory. In `physical-loop-timing-*`,
sleep report medians were **1.58–1.64 ms**, p95 about 2.51 ms. Inventory medians
were **1.53–1.65 ms**, p95 2.04–2.28 ms, with one 35.59 ms startup outlier.
Main work medians were 0.016–0.019 ms and p95 6.75–7.18 ms, including the
occasional synchronous shared-frame publication. This rejects the hypothesis
that every requested 1 ms sleep was becoming a 15.6 ms wait. No process timer
policy or power-throttling setting was changed.

`VIEWFLOW_SHM_GPU_TIMING` additionally samples one out of twenty staging copies
with D3D11 timestamp/disjoint queries, bracketed immediately around CopyResource.
Queries are diagnostic only: allocation failures disable that sample, missing
or disjoint results remain -1, and polling never waits for measurement data.
The normal completion event still controls valid staging ownership. GPU elapsed
time is not a clock mapping to QPC, nor exclusive engine occupancy; other
commands could interleave on the shared context in a multi-window scenario.

In the single-window `physical-gpu-readback-timing-*` fixture, 66 valid GPU
samples measured:

| Same sampled frames | p50 | p95 |
|---|---:|---:|
| CPU-observed enqueue to ready | 12.854 ms | 31.424 ms |
| GPU timestamp copy interval | **2.960 ms** | **4.174 ms** |
| Map | 0.003 ms | 0.006 ms |
| Shared-memory publication | 5.644 ms | 7.707 ms |

The observed wait is much larger than the copy's GPU execution interval.
Remaining candidates include queued GPU work before the staging copy and CPU
polling/publication delay; these measurements do not partition those two.
Code inspection also identifies a WGC → owned-source texture copy before the
existing source → staging copy. Removing that copy requires preserving WGC
frame-pool ownership and resize/multi-window correctness; it is not safe to
simply retain the borrowed texture pointer after the callback.

The timing-enabled source compiled and Windows 19/19 tests passed. GPU-query,
source-PID and single-readback wrapper overrides were verified removed after
measurement. Both runs preserved focus/foreground and restored DP-4 power off;
normal host service is active. No new performance gain or one-frame compliance
is claimed from diagnostic instrumentation. The goal remains active and unmet.

## Direct captured staging: remove the intermediate source copy

`VIEWFLOW_SHM_CAPTURE_STAGING=1` copies the borrowed WGC surface directly into
one of three owned staging buffers during the callback. The callback does not
retain the borrowed WGC texture or frame. A single full-resident raw surface
passes a shared lease of this buffer and its GPU completion query to readback,
avoiding the previous owned-default-texture to staging copy. Multi-window,
partial-residency and encoded paths retain the atlas fallback. An unleased
current slot can be reused in D3D command order; a slot held by readback cannot.
Pool exhaustion keeps the last snapshot. Unmap precedes lease release, including
when the publication callback throws.

Windows 20/20 tests passed. The new staging test passed on WARP and the Intel
hardware adapter, including exact BGRA publication, crop/resize, atlas fallback,
lease exhaustion/recovery and publication exceptions. An additional hardware
run passed these checks at **6144 x 3456**, not only the small test size.

In `physical-capture-staging-*`, the synthetic WGC fixture submitted 1787 frames
in 30.032215 seconds (**59.503 fps**). Receiver report rates were **55.190,
57.064, 57.945, 55.798 and 55.444 fps**. Receiver processing p50 was 2.994–3.515 ms
and p95 3.752–4.842 ms. 1439 capture diagnostic records used captured staging;
no source error was recorded. DP-4 sampled WGC-to-first-observed-presentation
feedback latency was **38.881 ms p50 / 44.116 ms p95** (80 samples). This is a
physical-output software feedback measurement, not photon latency or opaque
application acceptance. The target remains unmet.

The normal Windows launcher now defaults this option to 1, preserving an
explicit value of 0 for fallback. Both services were restarted. Focus remained
on the same Kitty window before, during and after measurement; DP-4 was restored
to its original powered-off state. No keyboard or pointer input was injected.

A preceding `VIEWFLOW_SHM_EARLY_POLL=1` experiment polls readback before window
inventory as well as at its normal point. It showed only 37–50 receiver fps and
45.93 ms sampled presentation median; it remains disabled. The earlier
single-readback and GPU-timing experimental switches also remain disabled.

## Compositor scheduler comparison after captured staging

`physical-new-scheduler-*` temporarily enables the installed
`render:new_render_scheduling` option and restores its original false value in
`finally`, with read-back. It produced 53.913–56.675 accepted fps and DP-4 sampled
WGC-to-feedback **40.107 ms p50 / 46.869 ms p95** (80 samples). Physical-output
commit-to-present report medians remained about 19–29 ms. This does not establish
a benefit over the captured-staging baseline; the option remains off. No
persistent compositor configuration or plugin was changed. Host focus remained
unchanged and the display returned to its original DPMS-off state.

## Capture-paced shared submission experiment

`VIEWFLOW_SHM_CAPTURE_PACED=1` bypasses the independent frame deadline only for
shared transport at a 60 fps budget with change tracking enabled. Lower background
budgets, unchanged-frame suppression and readback capacity checks remain. This
option is experimental and is **not enabled by default**. Windows build and
20/20 tests passed before deployment.

`physical-capture-paced-*` submitted 59.530 fixture fps; receiver intervals were
58.299, 57.355, **34.096**, 56.583 and 58.580 fps. Sampled DP-4 WGC-to-feedback
latency was 34.108 ms p50 / 40.702 ms p95. This single sequential run does not
prove a robust improvement: one interval includes a 2062 ms submission gap.
Main-loop work reached 1378 ms while inventory in that report stayed below 4 ms;
a capture callback's logged copy completion was about 1357 ms after its WGC
stamp. Existing instrumentation cannot distinguish source-lock contention from
D3D submission/driver waits, so this is the next diagnostic boundary.

Normal readback ready/publication medians remained 4.779 / 5.334 ms, essentially
unchanged from captured staging. The temporary pacing override was removed by
the runner, and normal services restarted. Host focus stayed unchanged; DP-4
returned to its original powered-off state. Goal remains unmet.

## Capture callback stage timings narrow the publication gap

Diagnostic-only callback timing separates source mutex acquisition, geometry,
staging preparation, CopySubresourceRegion submission, End and Flush. These CPU
intervals do not measure GPU execution. The optional timing pointer leaves
normal capture ownership and recovery unchanged. Build and Windows 20/20 tests
passed; the source was deployed for `physical-capture-stages-*` with capture-paced
submission temporarily enabled, then that override was restored off.

1543 callback samples: lock maximum 0.018 ms, geometry maximum 0.058 ms,
preparation maximum 12.304 ms (allocation/startup included), copy submission
maximum 0.035 ms, End maximum 0.017 ms, Flush p50 0.118 / maximum 3.726 ms.
WGC capture stamps had a maximum gap of 50 ms. Nevertheless, shared submission
had a 1189 ms gap and output had a 984 ms gap. This run does not reproduce the
previous long callback stall and does not establish its cause. It does show
that publication gaps can occur while capture callbacks continue promptly;
next inspect send scheduling, residency feedback and skipped-frame decisions.

Receiver intervals were 58.245, 55.766, 44.707, 56.186 and 59.234 fps; DP-4
sampled WGC-to-feedback p50 36.237 ms / p95 38.119 ms. This is not sustained
60 fps or one-frame compliance. Focus was unchanged and original DPMS state was
restored. The performance goal remains active.

## Zero-residency feedback explains a repeated publication pause

`physical-send-decisions-*` adds sparse residency transitions, target budget
changes and aggregated skip reasons. The source had activity scheduling disabled
and a constant 60 fps target. At QPC 150378408481 it received zero residency;
full 6144 x 3456 residency returned at 150390007493, **1159.9012 ms** later.
That explains the missing pixel publications while WGC capture continued.
Readback capacity skipped only twice; no independent timer skips occurred with
the experimental capture-paced option. Receiver intervals included 41.097 fps.

Code inspection found a concrete destination-inventory bug: a nonempty list
containing only Viewflow outbound parking monitors passed the residency guard,
but every monitor was excluded from the viewport union. Its empty sentinel
bounds became zero demand. The receiver now preserves the previous demand when
no destination monitor is described. Known workspace invisibility with a valid
destination retains its existing behavior. A regression test covers physical
plus parking, parking-only, empty and null monitor inventories; Linux 13/13
checks passed and the fix was deployed. Transition diagnostics record the
compositor metadata used, rather than assuming why a monitor disappeared.

In `physical-residency-fallback-*`, there was no zero-residency transition.
Receiver intervals were 56.786, 55.186, 56.596, 51.068 and 54.258 fps; DP-4
sampled latency was 35.351 ms p50 / 48.294 ms p95, with a 166.688 ms maximum.
This confirms the run retained full demand but does not prove all stalls are
fixed or sustained 60 fps. The temporary capture-paced option was removed;
normal services and original display power state were restored, focus unchanged.
The goal remains unmet.

## Bounded four-way publication copy experiment

`ParallelCopy` now accepts one to four participants, with a generation counter
and completion count protected by a mutex. Workers sleep between jobs; each
thread fences its own non-temporal stores, and publication waits for all row
ranges. Partial thread-creation failure stops and joins any started workers
before falling back through the existing serial recovery path. The default
remains two participants; `VIEWFLOW_SHM_COPY_THREADS=4` opts into four.

Shared-frame tests cover 1/2/4 participants with heights 1, 3 and 515, padded
source rows and 16 successive contents. Linux shared-frame correctness and
Windows 20/20 tests passed. The Intel hardware capture-staging test additionally
passed at 6144 x 3456 with streaming/parallel writes explicitly enabled and
four participants selected; this exercises exact full-frame publication,
lease ownership, crop/resize, atlas fallback and exception recovery.

The matched new-build sequential runs `physical-copy-four-*` then
`physical-copy-two-*` both used the experimental capture-paced switch and the
residency fallback fix. Four participants measured publication **4.110 / 4.907
ms p50/p95**, versus two **5.454 / 6.901 ms**. GPU-ready medians were essentially
identical (4.766 vs 4.763 ms). Receiver intervals were 55.318–57.420 vs
55.797–57.563 fps, so there is no throughput improvement claim. Sampled DP-4
WGC-to-feedback medians were 38.509 vs 39.614 ms (p95 45.104 vs 46.090 ms).
Sequential measurement remains subject to load and refresh-phase variation;
the repeatable component improvement is the publication copy time.

The Windows session launcher now defaults COPY_THREADS to 4 while preserving an
explicit 2 override. Small frames still use the existing serial path. Normal
services were restarted with the new source; capture-paced and fixture-PID
wrapper overrides were removed. Both experiments preserved focus and original
DPMS-off state. This trims a measured component cost, but does not satisfy
sustained 6K60 or one-frame end-to-end latency.

## Client GPU completion does not remove the presentation wait

An opt-in `VIEWFLOW_FINISH_BEFORE_SWAP=1` calls glFinish after the retained
snapshot is drawn into the EGL surface, before requesting feedback and swapping.
It is a diagnostic A/B path, disabled by default; no timeout or session validity
rule is introduced. The source built and was deployed. Both runs use normal
capture pacing and four-way publication, unlike the earlier capture-paced
experiments, so compare this matched pair rather than unrelated medians.

`physical-async-swap-*` accepted 56.168–57.307 fps in the 6K motion intervals
(the journal also contains a preceding 0.999 fps static interval, excluded).
DP-4 sampled WGC-to-feedback was 30.286 / 45.963 ms p50/p95. With the explicit
finish, `physical-finish-before-swap-*` accepted 56.626–58.003 fps and measured
31.928 / 46.668 ms. Receiver draw medians increased from 0.124–0.134 ms to
0.198–0.220 ms. Physical commit-to-present report medians remained roughly
20–28 ms; waiting for client rendering did not remove the extra output delay.
This points the next investigation toward compositor/output scheduling rather
than the client's final blit, without establishing an exact compositor cause.

The temporary service drop-in was removed, asynchronous submission restored,
and the normal host service restarted. Both tests preserved focus and original
DPMS-off state. The goal remains unmet; these are software presentation-feedback
measurements, not photon latency.

## Inspect the actual compositor scheduling path

Retrieved Hyprland commit `efb50993780079460b0cbed1363e2166a2de1d9f`, exactly
the commit reported by the running compositor, into an isolated build directory.
The unrelated `/home/wilf/data/Hyprland` checkout is not the runtime source.
The process maps `/usr/lib/libaquamarine.so.0.15.1`; the matching upstream tag
v0.15.1 resolves to `f31c47a1b9d300847d8fc3108ad959448103dfc1`.
Version/tag matching does not independently prove absence of distribution
patches. Provenance is recorded in `compositor-source-provenance.json`.

Relevant source paths and behavior:

- Hyprland `src/output/MonitorFrameScheduler.cpp:onFrame` immediately invokes
  renderMonitor on the normal scheduler path. The new-scheduler experiment
  previously tested addresses missed GPU work, not a general late-render deadline.
- Aquamarine `src/backend/drm/DRM.cpp:handlePF` marks the prior frame complete,
  emits presentation, then emits frameReady when no frame is already scheduled.
- `CDRMOutput::scheduleFrame` defers work while a page flip is in flight;
  `CFrameScheduler::canSchedule` requires no pending/running/scheduled frame.
  The normal commit path also rejects a buffer commit during an outstanding flip.
- Thus a new client buffer arriving after composition has begun can wait for the
  following composition and another flip. This is consistent with the measured
  20–28 ms commit-to-feedback medians at 60 Hz; source inspection alone does not
  attribute each individual measurement to that mechanism.

The installed runtime does not expose the old `render:explicit_sync` or
`render:explicit_sync_kms` configuration options. No unsupported setting was
written. `new_render_scheduling` and VFR remain at their original false values.
A viable next prototype must delay composition toward the next refresh deadline,
coalesce intervening damage, preserve output/session lifecycle, and fall back
when timing is unknown. This is compositor scheduling work, not another client
GPU fence. It must be measured before activation in normal use.

Timing caveat confirmed in source: Aquamarine clears HW_CLOCK for NVIDIA flip
sequence zero, while retaining HW_COMPLETION. Our observed DP-4 feedback flags
are 5 (VSYNC + HW_COMPLETION), not hardware-clock-qualified feedback. Hyprland
also has a monotonic-clock fallback for absent/invalid timestamps. The reports
remain software presentation-feedback measurements and cannot prove photon
latency. No compositor binary, plugin or persistent configuration was changed
by this investigation. The full goal remains unmet.

## Render-deadline prototype and isolated integration validation

Added the standalone, disabled-on-load `platform/hyprland-deadline-experiment`
plugin. It hooks the active version's monitor frame scheduler and uses one
coalescing event-loop timer per selected monitor. The planner has immediate
fallbacks for unknown/stale/late timing; output mode/lifecycle handling cancels
pending work. It checks the output's actual adaptive-sync state, rather than
`m_vrrActive`, which can merely reflect a requested unsupported mode.

Build and planner tests passed. The isolated Weston-headless → nested-Hyprland
integration test exercised real rendering callbacks: **179 armed, 178 fired,
177 coalesced** over its enabled interval. Disabling cleared pending work.
A second enable followed by unloading logged `viewflow-deadline-exit pending=1`;
the compositor remained alive and reported no config errors. No input was
injected and no surface was created on the user's compositor. The user's
Hyprland process and normal Viewflow service remain running.

The nested backend needed test-directory-only Aquamarine fixes for advertised
Wayland protocol versions, an absent headless input seat, and initial request
flushing. The exact patch and nested logs are recorded. No system library or
user compositor plugin was changed. This proves prototype lifecycle and timer
execution in that isolated environment, not physical DRM scheduling, a latency
improvement, or the full goal. Physical 6K comparison is the next validation.

## Physical deadline scheduling: first comparison

The standalone plugin was loaded temporarily, disabled for the baseline, then
unloaded. A second run enabled it on DP-4 with 3 ms lead and likewise restored
and unloaded it in `finally`. Existing plugins were not reloaded. The baseline
`physical-deadline-baseline-*` measured 34.901 / 41.616 ms sampled WGC-to-feedback
p50/p95, with 54.535–56.884 accepted fps in the motion intervals (an earlier
static journal interval is not part of that range).

`physical-deadline-3p0-*` measured **24.566 / 31.236 ms** p50/p95 (80 samples),
minimum 10.597 ms and maximum 45.794 ms. Receiver intervals were
57.470, 55.189, 54.238, 58.384 and 54.397 fps. Physical commit-to-present report
medians fell to 6.561–14.283 ms. The plugin recorded 2318 timer firings and 3755
coalesced requests, with zero pending-flip conflicts; its final DPMS fallback
mask 2 followed the runner restoring the powered-off monitor. Both runs kept
focus unchanged, restored original DPMS, and restored the exact plugin listing.
This is a meaningful observed latency improvement, not sustained 60 fps or
one-frame compliance. A shorter lead comparison follows.

A separate source-side idea was checked against Microsoft's documentation:
[existing system-memory heaps](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_feature_data_existing_heaps)
are documented for diagnostics, have cross-adapter restrictions, and do not
establish that an IVSHMEM device mapping can be imported as a normal GPU target.
No direct-to-IVSHMEM GPU write path was implemented on that unsupported premise.

## Deadline lead sweep follow-up

`physical-deadline-1p5-*` regressed to 38.514 / 43.579 ms physical
new-capture-to-feedback p50/p95 (77 samples), with commit-to-feedback report
medians 24.485–30.236 ms. A too-short composition lead may miss refresh, but
these arrival-based measurements alone do not prove the GPU deadline cause.
`physical-deadline-4p5-*` measured 25.954 / 32.896 ms (80 samples), slightly
worse than the 3 ms run. Both restored the exact plugin list, retained Kitty
focus, and restored DP-4 DPMS off. No lead was made a persistent default.

The prototype now exposes observed present intervals above 1.5 refresh
periods, timer lateness, and original render-call CPU duration totals/maxima.
These are diagnostics, not hardware deadlines or GPU completion times; they
never invalidate a session or proxy. They were added after the 1.5 and 4.5 ms
runs and therefore cannot retroactively explain those runs.

## Instrumented 2.5 ms lead

`physical-deadline-2p5-*` sampled 79 physical new captures: p50 18.899 ms,
p95 45.454 ms, range 10.831–47.994 ms. This improves the median but worsens
the tail relative to 3 ms, so it is not a successful one-frame configuration.
The scheduler counted 242 / 2165 observed present intervals above 1.5 periods,
2159 timer firings, zero pending-flip conflicts, mean timer lateness 20.45 us
(max 734.31 us), and mean original render-call CPU duration 1.438 ms
(max 5.278 ms). Counters include setup/teardown and are not limited to the
motion interval; long intervals alone cannot prove a hardware missed vblank.
The exact plugin listing, focus address and DP-4 DPMS-off state were restored.
A fresh 3 ms run with the same counters follows under the `timing` suffix,
which preserves the original comparison instead of overwriting its evidence.

## Instrumented 3 ms repeat

`physical-deadline-3p0-timing-*` measured 18.198 / 35.119 ms sampled
physical new-capture-to-feedback p50/p95 (80 samples), range 12.333–47.707 ms.
Accepted fps across the five motion intervals were 57.501, 55.262, 56.719,
56.082 and 55.215. The median differs substantially from the original 3 ms
run (24.566 ms); phase/load variation means the new best median must not be
reported as a guaranteed improvement or used to erase the earlier result.

Observed long present intervals were 42 / 2363 (1.78%), compared with
242 / 2165 (11.18%) at 2.5 ms. There were 2359 timer firings, zero pending-flip
conflicts, mean timer lateness 22.45 us (max 7.257 ms), and mean original
render-call CPU duration 1.461 ms (max 6.166 ms). These whole-run counters
include setup/teardown. Together with the better tail, they favor retaining
3 ms as the next experimental comparison point rather than shortening it.
The exact plugin list, focus address and DPMS states were restored; the
prototype remains unloaded and has no persistent configuration. The full
6K60 / <=16.7 ms goal is still unmet, even under this synthetic workload.

## Mapped-source copy investigation and opt-in AVX2

The optional `viewflow_capture_staging_test hardware 6k copy-probe` maps an
actual Intel D3D11 staging texture and copies 6144x3456 BGRA into aligned
ordinary RAM, not PCI IVSHMEM. VirtualQuery reported protection 0x4
(PAGE_READWRITE), type 0x20000 (MEM_PRIVATE), row pitch 24576. It did not
report PAGE_WRITECOMBINE or PAGE_NOCACHE, so special non-temporal source-load
instructions were not justified by this observation.

An opt-in `VIEWFLOW_SHM_COPY_AVX2=1` path widens streaming copies to 256 bits,
retaining per-thread store fences and publication ordering. CPUID, OSXSAVE
and XCR0 checks guard Windows dispatch; GCC uses its CPU feature check.
Unsupported CPUs retain SSE2, and the default remains SSE2. Explicit test
selection exercises both paths through reused worker batches and padded rows.
Linux shared-frame integrity passed; Windows shared-frame integrity, Intel
6K exact-pixel staging validation and the 20-test CTest suite passed.

In one sequential ordinary-RAM comparison, four-thread SSE2 p50/p95 was
2.834 / 3.140 ms and AVX2 was 2.529 / 2.944 ms; single-thread results were
4.580 / 7.097 and 4.472 / 5.184 ms respectively. These small, order-sensitive
microbenchmark differences are not proof of transport or end-to-end gain.
`run-copy-avx2.py` enables only this copy option plus four participants for
its physical comparison, keeps normal source pacing and compositor scheduling,
and restores the Windows wrapper and both normal services in finally.

### Physical AVX2 versus SSE2 comparison

Both new runs use four copy participants, normal capture pacing and the
normal compositor scheduler. `physical-copy-avx2-*` publication p50/p95 was
3.423 / 4.619 ms (1458 records), versus `physical-copy-sse2-*` 4.248 / 5.088 ms
(1455 records): a 19.4% lower median. GPU-ready waits were similar at
4.826 / 6.697 and 4.865 / 7.287 ms. The captured/mapped pixel tests passed.
AVX2 motion interval rates were 55.502, 56.374, 49.043, 55.072, 54.181 fps;
SSE2 rates were 57.195, 53.555, 54.423, 56.068, 52.815 fps. No sustained-fps
improvement is claimed. Sampled physical capture-to-feedback p50/p95 was
27.577 / 44.312 versus 35.801 / 46.515 ms, but refresh-phase/run variation
prevents attributing that entire end-to-end difference to the copy change.

Both runs restored focus and DPMS. Based on the consistent local-copy and
actual-publication benefit, the Windows session helper now defaults AVX2
on; explicit 0 and runtime unsupported-CPU fallback retain SSE2. The rebuilt
native binary and updated helper were deployed; the transient test override
was checked absent before restarting the normal guest task and host service.
The compositor experiment remains unloaded. Full 6K60/one-frame completion
is still unproven and contradicted by the measured rates/tails.

## AVX2 plus compositor deadline and pending-readback wait experiment

`physical-deadline-3p0-avx2-*` combined the deployed AVX2 copy with the
still-temporary 3 ms compositor lead. Sampled physical capture-to-feedback
p50/p95 was 17.110 / 30.891 ms (80 samples), range 11.692–37.537 ms.
Motion accepted rates were 55.265, 54.691, 52.965, 55.423 and 54.196 fps.
The exact plugin list was restored; long observed presentation intervals
were 37 / 2356. This is still not one-frame or sustained-60 completion.

The next opt-in `VIEWFLOW_SHM_POLL_US=250` (or 500) experiment uses a reusable
[high-resolution waitable timer](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw)
only while GPU readbacks are pending. Idle/encoded/default paths retain the
existing 1 ms sleep. Unsupported or failed timer operations fall back locally;
there is no spin loop, session cutoff, or held-frame invalidation. The Windows
21-test suite passed, including disabled/invalid configuration fallback and
repeated active/idle waits. The standalone timer probe without the application's
`timeBeginPeriod(1)` measured 250 us requests at 519.7 us p50 / 540.3 us p95;
500 us requests at 1011.5 / 1072.3 us. Its default sleep measured ~15.6 ms,
which is not the live application's ~1.6 ms sleep and must not be used as its
comparison baseline. `run-poll250.py` tests the real application with AVX2 and
3 ms lead and restores both the wrapper and compositor plugin in finally.

### Pending-readback short-wait outcome

`physical-deadline-3p0-poll250-*` recorded ready-wait p50/p95 4.316 / 5.204 ms
versus 4.797 / 6.548 ms for the AVX2 + 3 ms comparison. Publication stayed
similar (3.779 / 4.650 versus 3.765 / 4.627 ms). Accepted motion rates were
57.108, 57.379, 56.224, 55.229 and 56.380 fps, compared with roughly 53–55
in the preceding run. Loop sleep medians were 1.136–1.268 ms (mixing the
short pending path and the unchanged idle sleep); loop counts increased to
2508–2668 per five seconds from 1751–1858.

Physical new-capture-to-feedback p50/p95 was 18.771 / 33.787 ms, versus
17.110 / 30.891 ms previously. Thus the local wait reduction did not prove
end-to-end improvement. Keep this option off by default pending further
work on capture-arrival wakeup and pacing. All plugin lists, focus addresses
and DPMS states were restored. The new binary is deployed with its default
unchanged sleep; no short-poll override remains in the normal wrapper.

## Capture-arrival wake experiment

`VIEWFLOW_SHM_CAPTURE_WAKE=1` adds an auto-reset event after a successfully
owned capture snapshot/version update. It coalesces repeated notifications,
preserves notifications arriving before wait, and wakes only the sender's
otherwise-idle 1 ms wait. Pending GPU reads retain their original polling
path, and lane pacing/background budgets remain unchanged. The App-owned
event outlives stopped source callbacks. Disabled/failed event creation keeps
the prior sleep. Tests cover disabled mode, pre-wait notification, coalescing,
a notification during wait, and automatic reset; all 21 Windows tests passed.

`analyze-capture-wake.py` matches unique window-id + capture-stamp records
and subtracts actual CPU QPC copied/enqueued stamps. Ambiguous or missing
matches are counted and excluded; this avoids interpreting a WGC timestamp
phase offset as CPU wait. `physical-deadline-3p0-avx2-*` baseline had
1463 unambiguous matches, copied-to-enqueue p50/p95 0.526 / 1.881 ms.
`physical-deadline-3p0-capture-wake-*` had 1486 matches, 0.304 / 0.625 ms.
Neither had missing/ambiguous matches. Local notification latency improved.

The physical end-to-end samples nevertheless regressed to 24.907 / 45.684 ms
p50/p95 (80 samples), range 8.126–77.743 ms; accepted motion rates were
57.578, 56.773, 54.600, 55.761 and 54.043 fps. This run does not establish
an end-to-end gain or the full goal. Keep capture wake opt-in while examining
phase/pacing variability. The new binary is deployed with this option off;
plugin listing, focus and DPMS were restored after the experiment.

## Combined event/capture pacing: source cadence attribution

`run-capture-event-paced.py` temporarily combines CAPTURE_WAKE=1,
CAPTURE_PACED=1 and POLL_US=250 with the deployed AVX2 copy and 3 ms deadline.
`physical-deadline-3p0-capture-event-paced-*` measured 23.041 / 25.694 ms
physical capture-to-feedback p50/p95 (79 samples), range 6.567–58.896 ms.
Accepted rates were 57.434, 56.204, 55.654, 55.781, 56.265 fps. Fixture
submission was 59.766 fps over 30.000308 s. Ready-wait p50/p95 was
4.278 / 5.135 ms; publication was 3.378 / 4.637 ms. Exact plugin listing,
focus and DPMS were restored; none of the three experimental switches is
made a normal default.

The guest log contains 1507 successfully copied 6K capture callbacks over
26.7833333 s of WGC timestamps: 56.229 fps. Inter-capture median is
16.6667 ms, p95 33.3333 ms, with 101 intervals over 25 ms and max 33.3334 ms.
Actual CPU copied stamps span 26.765211 s (56.267 fps). All 1507 staging
acquisitions succeeded; source lock p50/p95 was 0/0 ms, max 0.074 ms;
CopySubresourceRegion CPU p50/p95 was 0.008/0.011 ms, Flush 0.124/0.236 ms.
Thus a material part of the rate deficit already exists at capture delivery,
before sender pacing or host composition. This does not yet distinguish DWM,
WGC or the fixture's presentation cadence. Investigate those upstream paths
before further sender sleep tuning.

The virtual-display helper gained a read-only `modes <display>` enumeration
and current refresh output, and built successfully. Running its default
inventory in the SSH session returned no display entries; no desktop mode
capability claim or mode change follows from that empty session inventory.
An interactive-session read-only probe is needed for authoritative modes.

## Fixture cadence and interactive display inventory

The fixture now records CPU Present duration and can select an eight-color
premultiplied-alpha-1/255 cycle (`30 cycle8`) without changing geometry,
input transparency or focus. `run-cycle8.py` temporarily changes only the
fixture argument around the combined event-paced experiment and restores
its launcher script. The original two-color pattern remains the default.

`physical-deadline-3p0-cycle8-*` submitted 1760 frames over 30.004744 s
(58.657 fps), with Present CPU p50/p95 16.678 / 17.099 ms, maximum 33.687 ms,
and 43 calls above 25 ms. WGC copied 1445 6K frames at 54.184 fps over the
observed timestamp span; 134 inter-capture intervals exceeded 25 ms, with
maximum 100 ms. There were no staging acquisition failures. Receiver rates
were 49.579, 55.399, 55.455, 54.781, 56.181 fps. Sampled physical latency
p50/p95 was 19.392 / 31.771 ms (80 samples), maximum 106.881 ms. This run
provides no evidence that replacing the two-color pattern solves the deficit;
fixture Present stalls show that upstream scheduling also needs attention.

Read-only enumeration performed inside the actual interactive fixture process
found DISPLAY5 at 6144x3456@60 and DISPLAY6 at 3078x2310@60. Each enumerated
only 60 Hz for 6144x3456, 32 bpp. No display mode was applied. This replaces
the prior empty SSH-session inventory with real interactive-session evidence,
without implying that the driver could never be configured with other modes.
The plugin list, focus and DPMS were restored. The CPU/window-capture goal
remains unmet; inspect Windows composition load and VM scheduling next.

## Runtime VM CPU-set comparison

The running VM service was confined by AllowedCPUs=4-13 (four P cores plus
six E cores). `run-vm-cpuset.py` records actual KVM-thread affinity and
schedstat counters, runs the same combined event-paced/AVX2/3 ms fixture,
then restores the original runtime property in finally. No VM reboot,
persistent CPU policy edit, existing-plugin reload or input injection occurs.
The pcores experiment verified all ten vCPU threads eligible on CPU 0-7;
its restored snapshot verifies 4-13 again for the same VM PID 2943334.

`physical-deadline-3p0-cpuset-baseline-*` had 86.405 vCPU run seconds and
1.041 aggregate runnable-wait seconds over 50.231 seconds (1.72 CPU equivalents,
including setup/cleanup). Fixture submission was 58.994 fps, with 33 Present
calls over 25 ms. Receiver rates were 56.571,55.839,56.628,56.194,53.389 fps;
sampled physical latency p50/p95 20.899 / 25.125 ms.

`physical-deadline-3p0-cpuset-pcores-*` had 84.767 vCPU run seconds and
1.979 runnable-wait seconds over 47.581 seconds. Fixture submission was
59.351 fps, with 22 Present calls over 25 ms. Receiver rates were
56.922,57.370,55.500,55.562,56.833 fps; sampled physical latency p50/p95
24.221 / 39.447 ms. Moving onto all P cores also shares CPUs with host work,
so this comparison is not a pure core-microarchitecture benchmark. It shows
no overall goal benefit and must not be kept as a default. Restore verification
includes CPU property, exact plugin listings, focus and DPMS. These results
also do not prove CPU scheduling can never matter; the tested allocation did
not solve the cadence/latency problem.

## WGC frame-pool capacity comparison

The WGC backend now accepts opt-in `VIEWFLOW_WGC_BUFFERS=3`; absent or other
values retain two buffers. The count is captured once per session and reused
for resize recreation. The Windows build (including /WX WGC compilation) and
21-test suite passed. `run-wgc3.py` tests three buffers with the same combined
capture/event pacing, AVX2 and 3 ms compositor deadline; it restores all
experimental wrapper values and unloads the deadline plugin afterwards.

`physical-deadline-3p0-wgc3-*` copied 1496 captures at 55.888 fps, with 107
inter-capture gaps above 25 ms and maximum 50 ms. Receiver rates were
55.071,55.707,56.361,56.821,56.042 fps. The fixture submitted 58.921 fps
and had 35 Present calls over 25 ms. Sampled physical latency p50/p95 was
23.384 / 28.143 ms (80 samples), range 8.960–42.188 ms. This does not show
that adding a WGC buffer solves the deficit; retain two as the default.
The exact plugin listing, focus and DPMS were restored.

Read-only `C:\VirtualDisplayDriver\vdd_settings.xml` inspection confirms two
virtual monitors, Intel(R) Graphics as the selected GPU, global 60 Hz and only
6144x3456@60 plus 3078x2310@60 mode entries. No driver/settings change was
made. Upstream configuration supports custom refresh entries, but applying
that to the installed driver requires version/capability verification and a
reversible configuration/mode test; it is not yet evidence of runtime 120 Hz.

Installed driver inventory: Intel 32.0.101.8860 (`oem8.inf`), Virtual Display
Driver 11.30.4.435 (`oem17.inf`, provider MikeTheTech). The upstream
[configuration example](https://github.com/VirtualDrivers/Virtual-Display-Driver/blob/master/Virtual%20Display%20Driver%20%28HDR%29/vdd_settings.xml)
and [control-project documentation](https://github.com/VirtualDrivers/Virtual-Driver-Control/blob/main/VirtualDriverControl/README.md)
are current upstream references, not proof that every control command exists
in this installed driver version.

## High-refresh capability preflight

The display helper gained `test-refresh <virtual-display> <hz>` using only
CDS_TEST, preserving all actual modes. Its build passed. A temporary hidden
interactive scheduled task ran current inventory, a 60 Hz control and a
120 Hz test on both virtual displays, then repeated inventory. Task result 0;
the temporary task was removed. `refresh-capability-probe.log` records
DISPLAY5 6144x3456@60 at (0,0), DISPLAY6 3078x2310@60 at (6144,3180),
60 Hz result 0 and 120 Hz result -2 on each. Before/after modes were identical.
A high-refresh experiment therefore needs a driver mode-list addition, not
just changing the selected refresh rate. No XML, mode or driver was changed.

Upstream driver source was inspected at commit
`d7244969b2aa8bb38e76d79505eda217996cefea` in `build/vdd-upstream`.
Its `SETDISPLAYCOUNT` handler calls `ReloadDriver(hPipe)`, whose implementation
passes that pipe handle to WDF context lookup. This inspection is a reason
not to assume that a current control-app reload recommendation is safe for
the installed 11.30.4.435 driver; it does not prove binary equivalence.
No named-pipe reload command was sent. The next mode-list test needs an
explicit backup, actual PnP-instance identification, and verified restoration.

Read-only PnP preflight identifies the active virtual display instance as
`ROOT\DISPLAY\0000` (status OK), separate from the active Intel PCI device.
Current XML SHA-256 is
`A0F5A3FB82344F3D0F90DF92D213A46EB3BC0690F0FD3E9DB5AD5A9416B978EF`.
The lookup also returned disconnected historical adapters; those are not
restart targets. This turn did not restart any device.

## Actual 6K120 source experiment with restoration

`refresh120-session.ps1` owns a guest-side 150-second restore guard. It snapshots
active virtual layouts and DPI, backs up the XML bytes/hash, temporarily stops
the two authorized Mac tasks, adds only a 6144x3456@120 resolution entry,
restarts only PnP `ROOT\DISPLAY\0000`, tests/applies the refresh without
persisting the mode, and restores XML/layout/DPI/tasks in finally. The host
`run-refresh120.py` runs the physical probe only after guest readback says 120,
then requests restoration and retrieves evidence. The physical destination
remains 6K60. Source CAPTURE_PACED is deliberately off to retain a 60 fps
send target; capture wake, 250-us pending polling, AVX2 and 3-ms deadline are
used. This is a materially different source-rate test, not a claim that the
fixture's submission rate equals received or presented FPS.

The first preparation exposed volatile GDI names: DISPLAY5/6 became 7/8 on
restart, so the old-name 120-Hz test failed before mode application. Cleanup
restored the XML and actual 60-Hz geometry but misclassified renamed displays
as a restoration failure. Evidence is preserved in `refresh120-attempt1/`.
A separate hidden interactive probe verified both restored displays at 200%
DPI and the original XML hash. The guard was corrected to resolve a unique
active virtual display by saved dimensions and primary/non-primary role,
and compare layout properties without treating GDI numbering as stable.

The second attempt successfully applied 6144x3456@120 to DISPLAY11, leaving
DISPLAY12 at 3078x2310@60. The fixture confirmed available/current 120 Hz.
`physical-deadline-3p0-refresh120-*` submitted 2929 frames in 30.006447 s
(97.612 fps), Present CPU p50/p95 8.551/16.754 ms, no calls above 25 ms.
WGC delivered 1333 copied 6K frames at 49.919 fps, median capture gap 16.667 ms,
8 gaps above 25 ms and maximum 516.667 ms. All staging acquisitions succeeded;
lock p50/p95 remained zero, but readback-ready p50/p95 rose to 7.114/16.271 ms.
Publication p50/p95 was 3.622/4.657 ms. Receiver rates were
49.304,47.645,52.437,47.191,52.791 fps. Sampled physical latency p50/p95 was
20.216/33.411 ms (79 samples). Thus merely raising virtual refresh did not
achieve the goal and must not be retained as a performance improvement.
The two-color fixture, WGC cadence and increased render/readback load remain
possible contributors; this run does not isolate their individual causes.

Restoration task result was 0. Before/during/after layout JSON and session log
prove original positions, dimensions, 60-Hz rates and 200% DPI restored under
new names DISPLAY13/14. XML SHA-256 again equals
A0F5A3FB82344F3D0F90DF92D213A46EB3BC0690F0FD3E9DB5AD5A9416B978EF.
Both Mac tasks and the normal Windows-Linux task are running; this is process
restoration, not user-operated Mac UX acceptance. Host plugin listing, focus
and DPMS were restored. The empty-error-list serializer originally omitted
its file on success (guard result says errors missing); the script now writes
an explicit JSON array. No missing error file is used as proof of restoration;
the task result, readbacks and exact hash provide that evidence.

## Verified WGC minimum-update-interval correction

Windows runtime and SDK are both 26100. The WGC backend now capability-checks
MinUpdateInterval, records its getter before/after, and optionally requests
4 ms through VIEWFLOW_WGC_INTERVAL_US=4000. Unsupported API or setter/getter
failure retains capture locally. The official
[API reference](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.minupdateinterval)
provides the property; [Sunshine's implementation](https://github.com/LizardByte/Sunshine/blob/master/src/platform/windows/display_wgc.cpp)
uses a 4 ms setting. Neither source substitutes for the local readback below.
The build and all 21 Windows tests passed.

`physical-deadline-3p0-wgc4ms-*` on the restored 60-Hz virtual display logged:
`wgc_interval supported=1 requested_us=4000 before_100ns=160000 after_100ns=40000`.
Thus the actual default here was 16 ms, not an assumed zero/unlimited interval.
WGC delivered 1568 copied 6K frames at 58.543 fps versus the fixture's
58.736 fps (1763 frames over 30.015508 s). WGC had 39 intervals above 25 ms;
the fixture also reported 39 Present calls above 25 ms. This substantially
narrows the upstream capture deficit: the recent same combined configuration
with default WGC interval delivered 55.525 fps versus fixture 58.994 fps.
These counts support the capture-interval fix, without proving that every
remaining gap is caused by exactly the corresponding Present call.

Receiver intervals were 60.132,59.008,58.742,58.658,57.213 fps. One interval
slightly above 60 is not sustained-60 proof. Physical sampled latency p50/p95
was 18.949 / 31.285 ms (80 samples), range 14.275–39.800 ms. Ready-wait
p50/p95 was 4.400/5.199 ms, publication 3.973/4.681 ms. The whole goal remains
unmet despite the clearer source-rate improvement.

The Windows session helper now defaults VIEWFLOW_WGC_INTERVAL_US to 4000;
explicit 0 retains the OS default, and unsupported Windows versions retain
capture. The tested native binary and helper were deployed, the temporary
wrapper overrides were checked absent, and guest/host normal services were
restarted. The deadline plugin, capture-paced bypass, capture-wake option and
short-poll option remain experimental/off in the normal profile. Plugin list,
focus and DPMS restoration were checked against the experiment artifacts.

### WGC 4 ms with independent send timer: confounded run

`run-wgc4ms-timer.py` retains the 60 Hz CPU send deadline while matching the prior 4 ms WGC / capture wake / 250 us pending-readback polling / 3 ms compositor deadline setup. Initial attempt failed before capture because Lua status lookup returned exit 6 after plugin load; cleanup completed. A subsequent explicit load/list/status/unload succeeded without compositor restart. The retry completed normally.

Artifacts: `physical-deadline-3p0-wgc4ms-timer-retry-*`. Fixture only 54.566 fps, 166 Present calls above 25 ms; source capture 37.692 fps with a 1266.667 ms gap. Readback ready p50/p95/max 4.782/17.314/1186.096 ms. Host load observed immediately afterwards: 33.63/122.98/87.37. These measurements do not isolate send pacing from concurrent system/GPU stalls; do not interpret the latency regression as a causal timer result. DP-4 feedback capture latency n78 p50/p95 39.938/60.668 ms (not photon).

New `analyze-capture-cadence.py` reports per-window unique capture cadence and selection coverage, excluding capture records outside the selected span. Here 993 of 1007 captured timestamps were selected (14 missed), versus 1567/1567 in the prior capture-paced 4 ms run. CPU copied-to-enqueue p50/p95 0.329/1.048 ms, max 17.829. Missing and ambiguous matching records both zero. Thus the >1 s stall occurs beyond ordinary selection wait; investigate resource/GPU completion before changing the default pacing.

Existing plugin list exactly restored; foreground address unchanged within this run; DP-4 and HEADLESS-1 restored to DPMS off. Wrapper restored and both services restarted. No input injected. Default pacing unchanged; goal remains unmet.

### Synchronized host-pressure capture for the timer comparison

Added read-only `record-host-pressure.py` and `analyze-host-pressure.py`. The recorder surrounds an explicit benchmark command, records monotonic timestamps every 250 ms, PSI totals, VM counters and per-vCPU schedstat; refuses evidence overwrite and never kills/restarts a benchmark on observation failure. Run artifact `wgc4ms-timer-pressure-host.json`: child exit 0, 216 samples/53.947 s, maximum sample gap 251.644 ms.

No direct reclaim, allocation stalls or swap-out occurred in this interval; swap-in 8 pages, minimum MemAvailable 18.121 GiB. PSI stall fraction: CPU some 1.774%, memory some 0.00735%, I/O some 0.422%. Ten matched vCPUs accumulated 94.972 run seconds and 1.164 runnable-wait seconds. This does not retrospectively prove the previous second-long stall was memory-related, but rules out sustained host memory reclaim in this measured repeat.

Repeat `physical-deadline-3p0-wgc4ms-timer-pressure-*`: fixture 56.021 fps with 122 Present calls above 25 ms. WGC 55.249 fps, 127 gaps above 25 ms (max 33.333 ms). Selection coverage 1473/1477, copied-to-enqueue p50/p95 0.320/0.758 ms. Readback ready p50/p95/max 4.514/5.457/63.702 ms. Note ready_ms measures elapsed time until CPU observes completion, including polling/scheduling; it is not isolated GPU execution time.

DP-4 feedback latency n78 p50/p95 49.549/56.606 ms, not photon. The receiver alpha stage worsened to approximately 8.0–8.7 ms median and 11.1–11.8 ms p95, versus approximately 2.6–2.8/3.2–3.9 ms in the earlier WGC4 run. Compositor experiment reports 1146/1333 presentation intervals above 1.5 periods. These host-side regressions independently invalidate attribution solely to the producer pacing timer; next investigate receiver GPU synchronization/competing capture workload while retaining source Present attribution.

Plugin list and DPMS state restored, foreground unchanged, normal service active. No default performance configuration changed; goal remains unmet.

### Receiver alpha-stage attribution under concurrent model training

Split receiver alpha timing into CUDA/GL upload and GPU extraction/comparison CPU wall time, reported alongside existing five-second stage summaries. No rendering or transport behavior changed. Build passed with warnings-as-errors; NVIDIA CUDA `gpu_alpha` byte-correctness test passed (3.49 s). Binary deployed atomically with `.before-alpha-stage-timing` backup.

Current GPU contention identified read-only: PID 3780760, cwd `/home/wilf/data/model`, `.venv/bin/python -u outputs/frechet-autoresearch/long-train/train.py`. During the measurement NVIDIA pmon recorded 93%/82% SM and 45%/40% memory utilization, 24746 MiB framebuffer usage (`wgc4ms-alpha-stages-gpu-processes.txt`). This is training, not the previously authorized model service shutdown; it was not stopped. User clarification requested about optional temporary pause.

Run `physical-deadline-3p0-wgc4ms-alpha-stages-*`, same timer-enabled profile: five intervals show upload median 4.541–4.725 ms, p95 6.822–7.394; extract/compare median 3.798–4.092 ms, p95 5.061–6.554. Timings include synchronization and are not GPU execution timestamps. DP-4 capture-to-feedback n78 p50/p95 46.500/61.210 ms, not photon. The new attribution supports comparing the existing CPU-alpha/upload overlap path under contention, rather than treating the aggregate alpha metric as shader execution alone.

Plugin inventory restored exactly, foreground unchanged, DPMS restored off, normal service active. Only diagnostic code persists; default alpha path remains GPU. Goal unmet.

### CPU alpha overlap under training contention: rejected

`run-cpu-alpha-contention.py` temporarily sets GPU_ALPHA=0 and restores the exact override boundary in finally. First run `physical-deadline-3p0-cpu-alpha-contention-*`: overlap=1, accepted 47.16–49.27 fps, alpha medians 7.64–8.25 ms, preparation 3.11–3.18 ms, total 11.35–12.44 ms. DP-4 sampled capture-to-feedback n77 p50/p95 51.496/69.012 ms.

A narrowly scoped follow-up tested exact full-plane CPU equality against the previous immutable alpha (only equal extent) so unchanged planes could reuse retained region state. Build and retained_surface/alpha_upload_overlap tests passed. `physical-deadline-3p0-cpu-alpha-reuse-*`: preparation fell to 0.009 ms, but alpha stage rose to 11.49–11.97 ms, total remained 11.68–12.21 ms, accepted 47.72–49.53 fps. DP-4 n79 p50/p95 48.049/64.212 ms, not photon. Training still active (pmon 78%/67% SM in reuse run); sampled load varies, so no causal claim for small latency differences.

CPU equality experiment removed after measurement: no meaningful total-stage benefit, extra full-plane read cost. GPU_ALPHA=1 remains normal default and diagnostic stage split remains. Both runs restored plugin list and foreground unchanged; no input injected. Next target is CUDA/GL upload synchronization, not switching alpha to CPU. Goal unmet.

### CUDA upload call attribution after training process exit

Added opt-in `VIEWFLOW_CUDA_UPLOAD_TRACE` to separate GraphicsMapResources, array lookup/setup, Memcpy2D and GraphicsUnmapResources CPU wall durations. Disabled by default; no extra synchronization or behavior change. Trace-enabled NVIDIA GPU-alpha byte-correctness test passed (1.68 s), native build passed. `run-cuda-upload-stages.py` enables the trace with a temporary service override and removes it in finally; `analyze-cuda-upload.py` groups records by actual extent.

During this run the previously observed training PID 3780760 no longer existed. No agent action paused/killed it; exit reason is unverified. Accordingly this is not a same-load comparison against the preceding contention runs. GPU alpha extraction median fell to 0.16–0.19 ms in observed intervals, supporting workload contention attribution without claiming a controlled causal experiment.

`physical-deadline-3p0-cuda-upload-stages-*`: 1453 exact 6144×3456 uploads. Map p50/p95 0.019/0.031 ms, array/setup 0.001/0.002, copy 2.580/3.512, unmap 0.019/0.039. These are CPU-observed call durations, not GPU execution timestamps; host registration occurs before the measured map interval. Main cost is the synchronous host-to-texture copy, not resource mapping, so texture-buffer proliferation is not currently supported by evidence.

DP-4 sampled capture-to-feedback n80 p50/p95 17.707/44.423 ms, not photon. One-frame target remains unmet, especially tail latency. Exact plugin inventory, foreground address and DPMS off state restored. Normal service active with trace override removed; GPU_ALPHA=1 retained.

### Exact frame join: receiver queue versus presentation wait

Added opt-in HOST_FRAME_TRACE with CLOCK_MONOTONIC stamps at shared-frame acquisition, accept entry, and accept completion (after window draw calls). No synchronization, input or rendering policy changes. Native warnings-as-errors build passed and diagnostics deployed. `analyze-tail-stages.py` joins exact PTS plus window ID to calibrated source and presentation records; upload duration is explicitly a subset, not a separately summed stage. Startup samples retained with capture_elapsed_s. `submit_to_present_ms` means accept completion to feedback, not an exact GPU submission timestamp.

Retrospective `cuda-upload-tail-stages.json`: n80, seven samples over 33.3 ms. Their mean capture-to-publication 10.739 ms, publication-to-feedback 35.752 ms, upload subset 3.122 ms. Worst samples occurred both near startup and after 20 s, so startup alone does not explain tails.

New `physical-deadline-3p0-host-frame-stages-*` / `host-frame-tail-stages.json`: n79, calibration envelope ±0.100567 ms, no unmatched samples. Median/P95: publication-to-ready 0.703/1.009 ms; queue 0.026/0.170; accept 3.262/4.944; accept-complete-to-feedback 13.206/25.885. Total 24.211/37.352 ms, max169.156. Post-accept waiting dominates ordinary tails; host reader queue is usually small.

Worst PTS236405199304 (24.383 s, not startup): Windows capture-to-publication160.108 ms, host queue0.028, accept3.639, remaining presentation4.385. Source callback reports lock0, geometry0.002, prepare0, Copy0.010, End0.002, Flush0.124 ms, yet copied QPC is about152.865 ms after capture and readback ready reports155.537 ms since staging enqueue. The unmeasured gap between staging timing and copied notification includes synchronous diagnostic fprintf and subsequent callback bookkeeping/scheduling. Do not label this isolated GPU execution: investigate logging/CPU scheduling perturbation next.

Test restored plugin list, foreground unchanged; normal service active with HOST_FRAME_TRACE/CUDA_UPLOAD_TRACE overrides removed. Goal remains unmet.

### Publish captured ownership before per-frame diagnostic I/O

Windows callback previously emitted profile_capture_stages and profile_capture while holding the source mutex. Changed to unique_lock, update complete texture/geometry/version state, record copied QPC, unlock and notify sender before those per-frame diagnostic writes. Failed staging acquisition also unlocks before diagnostics. Reported capture stamp now comes directly from this callback frame; source pts is not read after unlock. Infrequent lifecycle logs are unchanged. This removes the source-mutex/logging coupling, not all synchronous logger or scheduling stalls.

Windows warnings-as-errors build passed, 21/21 CTest passed (2.29 s). Native deployed via existing guarded runner. `physical-deadline-3p0-capture-log-unlocked-*`: 1486 unambiguous copied/enqueued matches, zero missing; median0.0271 ms, p950.8839, max23.7359. Earlier same-family runs were around0.32 ms median, but copied-QPC placement changed and run conditions vary; do not claim a controlled end-to-end gain from this comparison alone.

DP-4 n80 capture-to-feedback median22.112/p9538.160/max53.264 ms (not photon). Sampled capture-to-publication maximum11.764 ms; no160 ms outlier in this sampled set. Across all source records, ready max67.377 ms and enqueue-to-pack max94.706 ms remain: fix does not eliminate all stalls. Worst displayed sample occurred14.733 s into capture: publication8.622, receiver ready0.620, queue0.025, accept2.445, accept-complete-to-feedback41.552 ms. Compositor scheduling remains the primary next target.

Plugin list restored, foreground unchanged, normal services restored; diagnostic overrides removed. Code fix retained, goal unmet.

### 120 Hz source retest with verified WGC 4 ms: rejected; hot-restart limitation

New isolated guard/work directory `refresh120-wgc4` preserves prior experiments. Windows readback confirmed primary6144×3456@120 and secondary3078×2310@60; physical host remained6K60. Eight-color cycle fixture avoids simple alternating-two aliasing; native sender retains independent60fps budget. WGC getter confirmed40000 ticks (4ms), eliminating the earlier16ms limiter as an explanation.

`physical-deadline-3p0-refresh120-wgc4-*`: fixture69.864fps; WGC57.699fps, selected56.947fps; readback ready median20.579/p9522.505/max165.590ms, publication4.427/5.343ms. DP-4 n79 capture-to-feedback median34.372/p9556.060/max146.652ms, not photon. Thus raising virtual refresh with this capture/display stack still adds readback backlog rather than yielding low latency; do not enable120Hz by default.

Restoration: original XML SHA256 A0F5A3FB82344F3D0F90DF92D213A46EB3BC0690F0FD3E9DB5AD5A9416B978EF restored. Both actual modes60Hz, original geometry and DPI200 verified. Current display names15/16 (PnP names changed as expected). However final VDD PnP restart returned3010 (restart required). Guard records this as error, not success. A restoration-only retry stopped all three capture tasks, retried restart once, and returned50; it restored the previously running tasks in finally. Driver remains Present=true,Status=OK,Problem=0. No VM reboot performed; reloading the restored driver configuration remains pending a later appropriate Windows restart. Current60Hz modes and on-disk config are restored, but do not claim a successful driver hot reload.

All three scheduled tasks Running, Linux service restarted, guard/retry tasks removed after terminal states. Fixture arguments restored. Existing plugin list and foreground unchanged within measured run. Avoid further virtual-refresh switching while this driver restart condition persists; continue other optimization paths. Goal unmet.

### Completed readback coalescing experiment: no live trigger

Added opt-in VIEWFLOW_SHM_LATEST_READY=1. When both pending GPU completion queries are ready, only a newer frame with identical complete window/activity metadata can replace the older pixel payload before IVSHMEM publication. No timing threshold; older in-flight resources are not reclaimed. Metadata changes (including transient flags/grab offsets, geometry ack, icon bytes, residency and activity state) retain timestamp order. Superseded counter is reported with ready diagnostics. Normal default remains disabled.

Extended capture_staging_test uses different GPU pixel patterns and waits for the newer completion: only newest exact pixels publish in coalescing mode; an activity transition still publishes both, and geometry/icon/drag/residency changes fail metadata replacement checks. Existing FIFO path remains covered. Windows build and21/21tests passed (2.35s); actual Intel hardware6144×3456 pixel test passed.

`physical-deadline-3p0-latest-ready-*`:1486 publications, superseded counter0. Therefore current steady-state bottleneck is not two completed queued readbacks. Sampled DP-4 n80 median25.258/p9540.267/max78.846ms (not photon); do not attribute run differences to a path that never fired. Existing plugin inventory and foreground unchanged. Runner restored normal Windows wrapper and Linux service; no default coalescing setting enabled. Goal remains unmet; prioritize frame production/presentation cadence over completed-readback backlog.

### Waitable one-frame DXGI fixture: source cadence still below60

Added optional `waitable` fixture argument using DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT, IDXGISwapChain2 Set/GetMaximumFrameLatency(1), and message-aware waiting before every frame including the first. Handle is closed with scoped cleanup;100ms wait timeouts are counted and retried within the bounded fixture duration, not interpreted as stream failures. Existing fixture behavior remains default. Windows build passed; no user application swap chain changed. Official reference: https://learn.microsoft.com/en-us/windows/uwp/gaming/reduce-latency-with-dxgi-1-3-swap-chains and https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_3/nn-dxgi1_3-idxgiswapchain2 .

`physical-deadline-3p0-waitable-fixture-*`: readback max_latency1, zero wait timeouts, fixture56.315fps. Present CPU median0.065/p950.105/max1.827ms, noPresent above25ms; waitable wait median16.600/p9533.034ms. This shifts the blocking to the expected wait point but does not fix the missed source refresh cadence. Do not treat fastPresent calls as60fps proof. DP-4 n80 capture-to-feedback median24.398/p9540.921/max44.986ms, not photon.

Existing plugins and foreground unchanged, runner restored original fixture arguments and normal transport services. Waitable remains an optional probe, not new benchmark default. Source/display cadence requires further attribution; goal unmet.

### Source-only versus IVSHMEM-only attribution

Inspected the checked-out upstream VDD buffer loop: successful frames are acquired/released and marked finished without a CPU pixel copy or fixed sleep. This is upstream source, not proof of the installed binary behavior. Added low-frequency DwmGetCompositionTimingInfo(NULL) records to the synthetic fixture, linked dwmapi. Official field reference: https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ns-dwmapi-dwm_timing_info .

DWM HRESULT succeeds but cRefresh/cFrame increment only approximately once per query while fixture produces60fps; other per-window counters remain zero. These counters are inapplicable for reliable cadence attribution here. `analyze-dwm.py` preserves raw values and labels counter rates, not actual refresh rates. Do not infer no dropped frames from zeros.

`source-only-probe.ps1` pauses the three previously running Windows transport tasks, runs the same nonactivating6K fixture for30s, then restores task states in finally. First attempt with native PowerShell stderr redirection ended task result1 and empty log; no valid measurement, services restored. Corrected to Start-Process direct native stderr redirection; second task exit0. `source-only-fixture.log`:1803frames/30.007493s=60.085fps, Present median16.611/p9517.106/max33.431ms, only1over25ms, foreground unchanged. This proves the synthetic source can sustain approximately60 without Viewflow capture load; it is not transmission proof.

`run-without-windows-mac.py` then paused only WindowsMacSource/Receiver while retaining the IVSHMEM fixture run. Authoritative task state snapshots show3during,4before/after. `physical-deadline-3p0-windows-no-mac-*`:fixture56.703fps,102Present calls above25ms; receiver approximately55fps. DP-4 n79 latency median23.650/p9535.641/max37.498ms, not photon. Thus removing the optional Windows/Mac tasks does not restore source cadence: next isolate WGC capture/readback load within the primary path.

Source-only scheduled task removed after terminal exit0, all three normal tasks restored, Linux service active. No virtual display mode/driver changes this turn. Plugin inventory and foreground unchanged in transport run. Goal unmet.

### Self-capture attribution: WGC and staging sustain approximately60

Extended the nonactivating6K fixture with optional capture-only/capture-staging modes. Both use the production WindowCapture implementation on a separate D3D11 device, exact6144×3456 extents, and WGC4ms. Staging mode uses production CaptureStaging::copy; it does not Map, publish IVSHMEM, run production metadata bookkeeping, or log each frame. Capture callbacks are stopped before reading counters; no borrowed WGC surface is retained. Native fixture build passed.

`run-source-capture-probes.py` executes guest-owned bounded30s tests sequentially, with three Windows transport tasks temporarily stopped/restored by finally. Both scheduled tasks exited0 and were removed only after terminal states. `self-capture-only-fixture.log`:1800captures, stamp60.000fps, zero gaps above25ms, maximum16.667ms; fixture60.093fps. `self-capture-staging-fixture.log`:1798captures, stamp59.933fps,2gaps above25ms, max33.333; fixture60.012fps. Both report zero wrong extents, staging misses, or terminal capture errors, and unchanged foreground.

This narrows the approximately55fps production regression beyond basic WGC acquisition and staging enqueue/flush. It does not independently isolate Map versus IVSHMEM publication versus production-loop metadata/logging, since those are all omitted in this probe. Continue testing those stages; do not infer end-to-end60fps from these source-only measurements.

All three normal Windows tasks Running after completion; Linux service restarted and active. No display-mode/driver changes or injected input. Goal remains unmet.

### High-frequency diagnostic suppression: not the60fps bottleneck

Added VIEWFLOW_REVERSE_DIAGNOSTICS_QUIET=1 via vf_diag::metrics(), distinct from enabled() used for explicitly selected fixture PID. Quiet mode disables production-loop timing collection/per-frame profile I/O without expanding the selected window set; normal behavior unchanged when unset. Native build passed and guarded runner used the new binary.

`physical-deadline-3p0-diagnostic-quiet-*`:guest profile_* lines0, received atlas remains6144×3456. Five receiver intervals57.115,56.200,54.981,55.463,55.945fps; fixture56.479fps with108Present calls above25ms. Thus high-frequency Windows diagnostic output is not the main cause of the approximately55–57fps regression. No end-to-end capture latency computed because this run intentionally lacks capture timestamp records.

Exact plugin list and foreground preserved; wrapper/normal services restored. Quiet remains an optional attribution knob, not new default. Continue isolated Map/publication tests rather than investing in a logging rewrite as the primary throughput fix. Goal unmet.

### Map versus whole-plane ordinary-RAM copy

Extended isolated fixture with capture-map and capture-copy. Bounded two-snapshot leases retain GPU resources; previous-frame GetData and Map(DO_NOT_WAIT) never wait for GPU completion. Map-only touches first/last bytes and unmaps. Copy mode additionally invokes production ParallelCopy(4,true),84934656bytes/frame, to ordinary RAM, not IVSHMEM. Map cleanup is scoped for exceptions. Native fixture builds passed.

`self-capture-map-fixture.log`:1799captures/59.967stampfps,1gap>25ms;1798maps,1not-ready observation,1pending at stop, Map/Unmap p50/p950.004/0.005ms. Fixture60.086fps. `self-capture-copy-fixture.log`:1718captures/57.265stampfps,82gaps>25ms;1716copies,543not-ready observations,2pending at stop, copy p50/p953.366/4.674ms. Fixture58.222fps. Both zero extent errors, staging misses, terminal capture errors; foreground unchanged; guest task exit0.

Bulk copy reproduces source slowdown even with ordinary RAM, so do not attribute the regression solely to IVSHMEM BAR writes or Map API overhead. Limitation: this isolated probe performs the previous-frame copy inside the WGC callback, unlike the production main-thread publisher; results combine memory traffic with extended callback/borrowed-frame lifetime. Next separate those by moving probe copy off the capture callback.

Guest finally restored original tasks; runners removed terminal probe tasks and restarted normal Linux service, active. A concurrent read-only status query observed the already-cleaned task absent; no restart triggered. No mode/driver changes. Goal unmet.

### Off-callback ordinary-RAM copy attribution

Added optional capture-worker fixture mode: same production four-thread AVX2 copy and84934656bytes/frame to ordinary RAM, but mapping/copy runs on a separate worker. Callback queues only owned staging leases; the three-slot pool bounds outstanding surfaces. Queue mutex is released before GPU queries and CPU copying. Worker polls nonblocking completion at1ms, capture stops before worker joins, scoped Map cleanup and resource lifetimes cover exceptions. Native fixture build passed. This changes polling cadence as well as callback occupancy; it is not a perfectly isolated scheduling comparison.

`self-capture-worker-fixture.log`:1745captures,58.166stampfps,55gaps>25ms;1744copies,251not-ready observations,1pending at stop; copy p50/p954.726/6.115ms. Fixture58.293fps,54Present calls>25ms, maximum54.120ms. Zero wrong extents, staging misses, terminal capture errors; foreground unchanged. Scheduled task exit0 and removed after completion. Compared with callback-copy57.265fps, moving copy out improves capture cadence slightly but does not restore60. Bulk mapped-memory traffic/CPU scheduling remains a candidate; this does not prove memory bandwidth saturation, nor attribute the cost specifically to IVSHMEM.

Guest finally restored all three normal tasks (Running), Linux receiver restarted and active. No input injection, display mode or driver changes. Production defaults unchanged; end-to-end goal remains unmet.

### Copy worker thread-count attribution

Added capture-worker1/capture-worker2 fixture options, retaining the same84934656-byte ordinary-RAM destination, AVX2 algorithm, WGC4ms and off-callback1ms polling. Logs now record actual copy thread count. Windows native build and runner Python syntax check passed. No production copy defaults changed.

Two sequential30s tests completed with scheduled-task exit0. `self-capture-worker1-fixture.log`:57.532capturefps,57.710fixturefps,copy p50/p959.881/12.435ms,74capture gaps>25ms. `self-capture-worker2-fixture.log`:57.665capturefps,57.781fixturefps,copy p50/p956.426/8.528ms,70capture gaps>25ms. Both zero wrong extents/staging misses/terminal errors, one pending snapshot at stop, foreground unchanged. Prior four-thread off-callback test58.166capturefps and4.726/6.115ms copy remains faster, though these sequential runs are not controlled enough to interpret small fps differences as causal improvement.

Reducing helper count does not restore60fps and substantially increases copy time, so retain four-thread production default. Next investigate mapped-memory read behavior/copy implementation rather than deploying fewer threads. VM CPU allocation still4-13, normal Windows tasks Running after finally restoration, Linux receiver active after restart. No input or mode/driver changes. Actual end-to-end6K60 <=16.7ms remains unproven/unmet.

### Four-thread system memcpy versus streaming AVX2

Added an explicit, default-off constructor argument to ParallelCopy for system memcpy rows; contiguous pitches use one memcpy per worker span, padded pitches retain per-row copying. No runtime environment/default changes. Fixture capture-memcpy selects this mode with four persistent workers. Extended hardware copy validation across1/2/4threads and all existing algorithms. Windows fixture/test builds passed, realIntel6144x3456 validation exited0 with exact byte equality for every mode. `copy-memcpy-validation.txt` preserves transcribed results: repeated static mapped source, four-thread memcpy2.559/3.060ms p50/p95 versus AVX2 2.756/3.006ms. VirtualQuery source Protect0x4,Type0x20000; this alone does not establish actual physical cache policy.

`self-capture-memcpy-fixture.log`:30s continuous dynamic self-capture57.765fps,67capture gaps>25ms;fixture57.927fps,65Present calls>25ms.1732full copies of84934656bytes,copy p50/p954.650/6.023ms. Zero wrong extents, staging misses or terminal errors; one pending snapshot at stop; unchanged foreground. Guest task exit0. Compared with prior streaming worker58.166fps and4.726/6.115ms, there is no demonstrated cadence benefit from system memcpy; tiny timing differences are not a controlled causal claim. Keep normal production AVX2 streaming implementation.

All three Windows tasks Running after guest finally restoration, normal Linux receiver active after restart. No input, mode/driver or production binary changes. Next distinguish total memory traffic from fresh GPU-readback contention with a bounded copy-frequency attribution test; reducing production update rate would not satisfy60fps. End-to-end goal remains unmet.

### Half-frequency CPU copy attribution, full-rate GPU staging retained

Added fixture-only capture-halfcopy: same four-thread AVX2/off-callback pipeline, GPU staging and Map for every captured frame, CPU full-plane copy only on alternating completed maps. Logs explicitly report every=2 and actual copied frame count. No production rate/default change. Native build and runner syntax check passed.

`self-capture-halfcopy-fixture.log`:1792WGCcaptures,59.733stampfps,8gaps>25ms;1791maps,896full CPU copies,340not-ready observations,1pending snapshot at stop. Copy p50/p954.936/6.136ms;fixture1796frames/30.003435s=59.860fps,8Present calls>25ms. Zero wrong extents, staging misses or terminal errors;foreground unchanged;task exit0. Relative to full-copy worker58.166fps/55gaps, reducing CPU copy frequency nearly restores source cadence while individual copies remain similarly costly. This supports a load-dependent CPU-copy interaction, but does not distinguish total memory traffic, fresh readback cache behavior, or scheduling contention. It is deliberately NOT60fps publication evidence (only896frames copied), and must not become a production frame-dropping workaround.

Guest finally restored all three normal Windows tasks Running; normal Linux service restarted and active. No input, focus, mode/driver changes. Continue optimizing full-rate copy/traffic with exact pixel preservation; actual6K60 <=16.7ms end-to-end goal remains unmet.

### Ordinary-RAM source control retains the slowdown

Added optional capture-ramcopy fixture mode. Every captured frame still performs GPU staging/query/Map and touches mapped endpoints, but the four-thread AVX2 full-plane copy reads a preallocated84934656-byte ordinary-RAM source filled0x5a. Source and destination are distinct; full bytes copied every completed map. Logs label static-ordinary-RAM explicitly. This is a synthetic traffic control, not transported image content or an implementation candidate. Native build and runner syntax check passed.

`self-capture-ramcopy-fixture.log`:1734captures/57.799stampfps,66gaps>25ms;1733copies,copy p50/p954.720/6.164ms;fixture57.945fps,66Present calls>25ms. One staging pool miss, zero wrong extents/terminal errors, zero pending at stop, unchanged foreground. Task exit0. Compared with original mapped-source worker58.166fps and4.726/6.115ms, switching source away from freshly GPU-written staging did not recover cadence. This weakens a staging-specific CPU-read explanation; combined with half-frequency59.733fps, prioritize shared traffic/CPU scheduling interaction rather than special mapped-read instructions. Sequential measurements do not prove bandwidth saturation.

Read-only host snapshot during probe: CPU PSI avg10=.89%,memory PSI avg10=0;cpu4 governor powersave with EPP performance;VM AllowedCPUs4-13. These global readings do not rule out localized contention. Guest finally restored all three normal tasks Running, Linux receiver active after restart. No user input/focus, driver/mode or production defaults changed. Goal remains unmet.

### Power-plan control encountered persistent approximately4fps source state

Readback initially balanced381b4222-f694-41f0-9685-ff5bb260df2e,processor min5/max100,10virtualcores. Added guarded guest-owned30s full-copy test switching to HighPerformance8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c, checking active GUID, restoring original GUID in finally and recording restore exit/readback. Task exit0; power log confirms restore_exit0 and original balanced GUID. `self-capture-powerperf-fixture.log`:capture3.823fps,fixture3.936fps,Present median253.828ms,copy2.840/3.429ms p50/p95. This is a regression, not optimization.

Restoration verification `self-capture-powerbalanced-fixture.log` still3.834capturefps,fixture3.947fps,Present253.406ms. Therefore restoration of the GUID does NOT prove runtime cadence recovery; do not attribute low cadence solely to the performance plan. Balanced AC display timeout readback0, no DISPLAY power requests before next control.

Added scoped SetThreadExecutionState CONTINUOUS|DISPLAY_REQUIRED|SYSTEM_REQUIRED to fixture (restore previous execution state on exit), native build passed. Live powercfg /requests confirmed fixture as sole display requester during run. `self-capture-powerawake-fixture.log`:3.922capturefps,4.040fixturefps,Present253.858ms,copy2.842/3.181ms. This request did not restore cadence. All three runs zero extent errors/staging misses/terminal errors and foreground unchanged; no input injection or focus change. Source-level display/compositor state remains unresolved, and approximately58fps pre-experiment baseline has NOT been recovered. Investigate actual display power/desktop state before interpreting further copy tests.

Final readback balanced scheme, normal three Windows tasks Running, Linux receiver active. Fixture request released. These prove settings/task restoration only, not frame-rate restoration. End-to-end goal unmet; next work must address this newly observed source regression.

### Display wake control does not recover the source baseline

Read-only checks: console user session1, DWM present, no LogonUI process returned; Intel and VDD present/OK; fixture desktop modes remain6144x3456@60 and3078x2310@60. RecentSystem log exposed a SessionUnlock event, so state changes outside the test remain a potential confounder; no evidence of display-driver error from the narrow query. Do not infer a power-plan-only cause.

Added optional fixture wake-monitor using SendMessageTimeout to the fixture's own HWND, WM_SYSCOMMAND/SC_MONITORPOWER/-1 (1000ms bound), keeping nonactivation and existing execution request. Reference https://learn.microsoft.com/en-us/windows/win32/menurc/wm-syscommand . Native build passed; no mouse/keyboard injection or focus request. `self-capture-monitorwake-fixture.log`:capture5.412fps,fixture5.496fps,Present median252.747ms/max683.332ms;copy3.020/5.029ms p50/p95,zero extent/miss/terminal errors,foreground unchanged. Task exit0. Wake dispatch is not proof of physical display power state; baseline remains unrecovered. Further diagnostics should check actual display-state notifications and fixture occlusion/presentation throttling, including potential external desktop changes, before more throughput optimization.

Guestfinally restored three normal tasks Running and balanced power scheme, Linux receiver active. Goal still unmet; source regression unresolved.

### Topmost probe control failed its state readback

Added optional probe-topmost fixture flag with SetWindowPos(HWND_TOPMOST,SWP_NOACTIVATE|NOMOVE|NOSIZE), plus before/after IsWindowVisible,IsIconic,DWMWA_CLOAKED,extendedstyle,rectangle,foreground diagnostics. Native build and Python runner syntax passed. `self-capture-topmost-fixture.log`:both start/end visible1,iconic0,cloaked0,rect0,0,6144,3456,foreground unchanged; however topmost0 at both points. Although task exit0 and no SetWindowPos failure exception, the desired topmost state was NOT verified. Do not treat this as valid evidence excluding occlusion. Need inspect actual argv, desktop/session and native state before another comparison.

Capture3.893fps,fixture4.007fps,Present median253.861ms;copy2.881/3.368ms. Zero extent/miss/terminal errors. Services restored:three Windows tasks Running,Linux receiver active. Original approximately58fps baseline remains unrecovered; target unmet. No injected input/focus tests.

### Verified topmost creation does not resolve approximately4fps

Added fixture argv,desktop/window-station/session/activeconsole,foreground and SetWindowPos result/error/style diagnostics. `self-capture-desktopdiag-fixture.log` confirms argv30 capture-worker probe-topmost,WinSta0/Default,session1=activeconsole1,requested_topmost1. SetWindowPos returns1/error0 but immediate style0x82000a0 lacks TOPMOST. Thus prior test was not missing args or a wrong session; reason for this successful-but-ineffective positioning remains unknown.

Changed optional probe-topmost to include WS_EX_TOPMOST at CreateWindowEx. Native builds passed. `self-capture-createtop-fixture.log` verifies style0x82000a8,topmost1 at both start/end,visible1,iconic0,cloaked0,exact6144x3456,unchanged foreground. Despite valid topmost state,capture3.782fps,fixture3.897fps,Present median254.057ms;copy2.882/3.216ms. Zero extent/miss/terminal errors,task exit0. Raising the nonactivating fixture did not restore cadence; prioritize desktop composition/power-state or swapchain presentation throttling rather than ordinary window stacking. This remains source-only,not end-to-end proof.

Both guarded tests restored three normal Windows tasks Running,Linux receiver active. No injected input/focus or driver/mode changes. Original baseline remains unrecovered;goal unmet.

### Direct display-power evidence: off, transient wake, then off again

Added scoped RegisterPowerSettingNotification(GUID_CONSOLE_DISPLAY_STATE) and WM_POWERBROADCAST state logging; unregister before window destruction. Also count Present HRESULT DXGI_STATUS_OCCLUDED/other successful statuses separately. Native fixture builds passed. `self-capture-presentdiag-fixture.log` reports display state0(off),Present occluded0/other0:normal S_OK calls themselves block,not an explicit occlusion status. State0 directly supports display-off throttling as an active condition, unlike earlier power-plan or keepawake inference.

Changed optional wake-monitor from own HWND to HWND_BROADCAST with100ms per-window SendMessageTimeout bound. `self-capture-broadcastwake-fixture.log`:state0->state1->state0,wake_sent1/error0,foreground unchanged. Capture5.494fps,fixture5.643fps,Present median252.379ms,copy2.979/4.763ms;zero extent/miss/terminal errors,topmost1. The transient wake did not persist; need identify why display returns off despite fixture execution request. No basis to claim baseline restored. Present remained S_OK throughout.

Narrow recursive scan of Viewflow PowerShell files excluding probes found no matching SC_MONITORPOWER/0xF170/powercfg/SetThreadExecutionState lines. This does not exclude other services, executables or policies. Both guest tasks exit0 and cleaned;normal three Windows tasks Running,Linux receiver active. No input injection/focus/driver-mode changes. Goal unmet; next investigate display-off source and power request overrides/state.

### Display timeout/override and background-service checks

Read-only powercfg requestsoverride is empty;ALLODISPLAY AC/DC1,VIDEOIDLE AC0/DC180,VIDEOCONLOCK AC/DC60. DdcDisplaySwitch server contains an explicit30s off/on endpoint, but its log has no recent switch-start/completed entries (latest startup at00:22). Sunshine log timestamp also predates regression. These narrow observations do not prove every external display controller absent. No unrelated services stopped.

Guarded no-timeout test validates original settings, temporarily sets VIDEOCONLOCK AC/DC0 and VIDEOIDLE DC0, activates balanced, runs full-copy/topmost/broadcastwake fixture, then restores60/60/180 in finally. First attempt failed preflight because /query omits hidden setting; no fixture log/result data,task result retained. Corrected to /qh and distinct capture-notimeout2 tag;task exit0. Live readback during test confirms lock timeouts0/0. `self-capture-notimeout2-fixture.log` still power0->1->0,capture5.418fps,fixture5.536fps,Present median252.483ms,zero occluded/other statuses. Foreground unchanged,zero extent/miss/terminal errors. Disabling these timeouts does not prevent display returning off.

Final authoritative /qh readback VIDEOCONLOCK AC/DC0x3c,VIDEOIDLE AC0/DC0xb4,normal three Windows tasks Running,Linux receiver active. Settings restored;source baseline NOT restored. Next investigate active display controllers/session power events rather than assuming an idle timeout. Goal unmet.

### Initial kernel-power ETW trace: circular history incomplete

Read-only host ~/.local/bin,Hyprland config and user-systemd search found no relevant Windows DPMS synchronization script. Windows policy registry checks found no configured inactivity/display policy overrides. System Kernel-Power566 events show SessionUnlock11:49:43Z and reason3/MonitorReason3 at11:54:43Z (about301s later,PowerStateAc=true); does not identify the caller causing subsequent off transitions.

Added guarded powertrace runner:logman Microsoft-Windows-Kernel-Power all keywords level5,16MiB circular,max30s fixture plus setup/finally;finally stops trace and restores tasks/scheme;tracerpt XML conversion. Authoritative midrun logman confirmed running,0bufferslost. Task exit0,final logmanquery reports collector absent (stopped). XML preserved compressed as power-probe.xml.gz;power-event-examples.json stores one decoded example perEventID.

Trace contains121497ID557 and6483ID63 timer-resolution events,dominating buffers. Header has zero EventsLost/BuffersLost,but earliest remaining kernel events begin about12s after trace start:16MiB circular history overwrote startup. Therefore it cannot establish the causal wake/off sequence and must not be treated as complete just because lost counters arezero. One ID63 sample attributes a timer-resolution request to Feishu with RequestIgnored=true;this alone does not establish performance impact or justify stopping it. Need increase bounded trace retention/filter events to preserve the actual transition before attribution.

Normal three Windows tasks Running,Linux receiver active;no unrelated applications stopped,no input/focus tests. Baseline and goal remain unmet.

### Complete retained power sequence identifies console-session off transition

64MiB circular kernel-power trace completed task0,collector stopped afterward. Added streaming analyze-power-trace.py to retain coverage/header/counts and non-timer/runtime-PM events. power-probe64.xml.gz and power-probe64-summary.json retained. HeaderStartTime matches earliest event08:11:27.3447592-04:00;last08:12:03.1999061,0EventsLost/0BuffersLost,2944*8192bytes<64MiB. Unlike previous trace, startup is retained.

FixturePID5844 creates a request with DisplayAllowed=true at08:11:31.934962,DisplayCount becomes1 and remains1 until08:12:02.745207 teardown. DisplaySessionStatus/ConsoleDisplayState turnon at08:11:32.00404,then off08:11:33.07349 (~1.069s later). SessionDisplayOff149 recordsReason6,executionPID972/TID1020;live process readback identifies972 as csrss/session1. AdaptiveSessionState576 reportsDisplayTimeout0 throughout;InputTimeout240 aton,0atoff. Reason6 semantics are not established: installed provider metadata has no description/map for149/150. Do not label this idle-timeout,an external application,or a malicious/specific caller without more evidence. csrss is event execution context,not proven initiating culprit.

This establishes that accepted display request persists while the console-session path forces off. Next investigate relevant Win32k/session event context or supported session display control;do not repeat basic timeout tests. Tracking was diagnostic overhead,not performance baseline. Normal3Windows tasks Running,Linux receiver active;no input/focus changes. Original source cadence and fullgoal remain unmet.

### Win32k power trace attributes the off request to Word's process context

Inspected installed Microsoft-Windows-Win32k provider metadata and selected win32Power0x8000,level5. Guarded30s trace has23buffers*8192,0EventsLost/BuffersLost,full interval retained;task exit0,collector stopped. win32power-probe.xml and win32power-summary.json retained. DisplayReqChange12 shows fixturePID4288 requestcount1 beforewake,0onlyaftertest. No IdleActionExpiration11 recorded;IdleStatusTracing20 reports display/screensaver/dimtimeoutsall0 immediately beforeoff.

At08:14:24.5490637-04:00,Win32k PowerRequest437 is submitted inPID8456/TID14800 withEventNumber5,Code6. It is then processed bycsrssPID972 at08:14:24.549132 and display transitions1->0 at08:14:24.580152. Live Win32_Process maps8456 toWINWORD.EXE,createdbeforetrace,parentfusionagent15456. This identifies request execution/submission context more specifically than previouscsrss-onlytrace;does not establish why Word or a component submitted it. Do not claim malware or an Office defect without further isolation. Narrow module inventory outsideWindows/Office/sharedOffice returns only DefenderMpOav.dll;not proof of absence of all add-ins.

Normal3Windows tasks Running,Linuxreceiveractive. Word left running with its documents;no input/focus injection or termination. Next perform carefully bounded process/component attribution that preserves user documents. Frame-rate baseline and goal remain unmet.

### Word suspension control restores approximately58fps only during isolation

Rechecked fusion-agent/reverse sources: no production SC_MONITORPOWER path found. Added guarded Word process isolation:verifyPID8456nameWINWORD,openPROCESS_SUSPEND_RESUME handle,NtSuspendProcess once,run30s normal full-copy/topmost/broadcastwake fixture,finally NtResumeProcess once/closehandle before restoring transport tasks. Existing documents/process preserved,no keyboard/mouse/focus change. `self-capture-wordpause-fixture.log` reports display0->1 with no lateroff duringrun,capture57.532fps,fixture57.730fps,Presentmedian16.624ms,copy4.870/6.374ms,zero extent/miss/terminal errors. Taskexit0. Guestreadback resume_status0,WordPID8456alive,SuspendedThreads0. This causally supports Word process activity's role in repeateddisplayoff,but is NOT a deployablefix and does not establish full normal-service baseline recovery.

Followup screensaver API control aborted beforefixture:interactiveSPI_GETSCREENSAVEACTIVE returned0 andtimeout0;SPI_SETSCREENSAVEACTIVE(false)failed,finally restorealsofalse butreadbackremainedoriginal0. No capturelog exists,taskfailure retained;do not count this as a valid disable-screen-saver comparison. SinceAPI alreadyreportsinactive,do not assume ordinary screen saver causedWordrequest. Need further message/call attribution withWordrunning.

FinalWordalive/zeroSuspendedThreads,normal3Windows tasksRunning,Linuxreceiveractive. No document closed or modified. Goal remains unmet;restored57.5fps is isolation-only,not normal end-to-end proof.

### Message tracing corrects Word attribution: csrss posts off command to foreground Word

Installed Win32k event templates59/60/61/62 expose message/parameters,queue pointer,and sender/receiver context. Added bounded8s fixture/64MiB trace with win32Power|MessagePump0x408000. No injected input. Taskexit0,60buffers*8192,0lost,fullstartup retained. Filtered powermessage-summary.json retains onlyWM_SYSCOMMAND274 andPowerRequest437 pluscoverage/counts/header;unrelated message payloads were not presented or added to repository evidence.

At08:22:10.450339-04:00,QueuePostMessage59 in csrssPID972/TID704 enqueues hwnd0x4062C,message0x112,WParam0xF170(SC_MONITORPOWER),LParam2(off),queuepointer0xFFFFA70EBD62A800. WordPID8456/TID14800 retrieves SAMEqueuepointer starting08:22:10.4506315,thenPowerRequest437 Event5/Code6 at08:22:10.4509428. Thus Word is the foreground recipient executing the system's posted off command,not established as initiating cause. Previous suspension control merely prevents recipient processing;it must NOT become a workaround or justification to alterWord/add-ins. Root investigation returns to csrss idle/power message generation despite accepted display-required request.

Trace stopped;Wordalive and0SuspendedThreads;normal3Windows tasksRunning,Linuxreceiveractive. No document modification orfocuschange. Baseline andgoal remain unmet.

### Long nonzero display timeout does not prevent repeated off

Guarded source-longtimeout probe saves actualACVIDEOIDLE,sets86400seconds,activatesexistingbalancedplan,runs30s full-copy/topmost/broadcastwake,and restoresoriginaltimeout in finally. Duringtest authoritativepowercfg readback0x15180 confirms86400. Displaystill0->1->0;taskexit0. Thus the simple hypothesis of currentzero-timeout handling is not supported by this control. FinalreadbackACVIDEOIDLE0x0 restored,normal3Windows tasksRunning,Linuxreceiveractive.

Added native input-desktop SystemParametersInfoW read-only diagnostics with per-call success/error. Nativefixturebuildpassed;8s capture-spidiag taskexit0. SPI_GETSCREENSAVEACTIVE16,GETSCREENSAVETIMEOUT14,GETPOWEROFFACTIVE84,GETPOWEROFFTIMEOUT80 allreturnedok1,value0,error0. These are API results,not proofofallcurrentWindows power policy semantics (especially legacy poweroff APIs);do not infer that no other system mechanism can initiateoff. No foreground/input/document changes. Need move beyond basictimeoutcontrols toward system idle-handler context;baseline/fullgoal stillunmet.


### Stack trace establishes system timer display-off path

Added bounded8s WPR profiles/runners using ProcessThread+Loader metadata and Win32k0x408000,stack filters59/437. Initial powerstack profile omitted NonPagedMemory and yielded only system metadata despite task0; NOT valid message/stack evidence. Corrected distinct powerstack2 profile adds NonPagedMemory=true,Strict=true. Live WPR status confirmed provider/keywords/stackIDs and0lost. Taskexit0; trace ended,normal3Windows tasksRunning/Linuxreceiveractive,originalpowerplanrestored. No input or focus injection.

powerstack-coverage.json records full08:38:46.0993406--08:39:01.1873758 interval and header counters. At08:38:52.2020569,csrss972/TID704 postsWM_SYSCOMMAND0x112,SC_MONITORPOWER0xF170,LParam2 toforegroundWord0x4062C. powerstack-off-event.xml retains only this target event and attached stack; unrelated input message payloads excluded from repository. powerstack-addresses.json maps addresses to image metadata. Installed Windows Kits Debuggers/x64/dbh.exe (not onPATH) resolves matching Windows binary symbols through Microsoft public symbol server; resolve-powerstack.ps1 and powerstack-symbols.txt retain reproducible offline symbol lookup. No debugger attached to live processes.

Resolved caller chain (outer to inner): RawInputThread+0xb50 -> xxxTimersProc+0x2cc -> xxxReadyTimer+0x14f -> lambda -> DoPowerStateAndMonitor+0x7a3 -> PostTransformableMessage -> _PostTransformableMessageExtended -> StoreQMessage. Establishes a system timer path,not Word-originated request. Offline binary inspection additionally identifies PowerIsDisplayIdleExpired/PowerIsDisplayRequired and input-sequence comparisons; exact live branch/state is NOT established. Hypothesis that prior display-off state requires real input to clear remains unverified. Asked user for manual input; no synthetic input/focus used. Do not turn Word suspension into a workaround.

Fixture stilloff->on->off undertracing; tracing cadence is not normal performance evidence. Baseline and6K60/16.7msgoal remain unmet. WPR not recording atfinalreadback. Official schema references: https://learn.microsoft.com/en-us/windows-hardware/test/wpt/eventprovider and https://learn.microsoft.com/en-us/windows-hardware/test/wpt/stackfilters .


### Read-only last-input timestamps corroborate no input during repeated off

Added report_input_clock to native motion fixture atstart/end and console display-state notifications. GetLastInputInfo/GetTickCount only; no input simulation or focuschange. Logs APIstatus/error and unsigned32-bit tickdelta (subject to Windows session API semantics/tickwrap). Windows Release fixture build passed. Distinct8s inputclock probe taskexit0; retained runner/script/result/log.

Atstart tick30176796,lastinput5918859,idle24257937ms (~6.74h). Onnotificationtick30176828 and subsequentofftick30177937 have SAME lastinput5918859. Endtick30185062 stillsame. Thus wake-monitor broadcast did not constitute new session input and no user-input recovery occurred duringthisrun. Offreturns~1109ms afteron. This supports testing real input next but does not itself prove the private kernel branch/causalstate. WGC77frames/9.744fps includesinitialawakeburst;not recovered sustainedcadence or end-to-end benchmark. Foregroundunchanged,zeroextent/miss/terminalerrors. Normal3Windows tasksRunning/Linuxreceiveractive verified afterrunner. No production hotpathchange. User manualinput request still unanswered;goalunmet.


### Manual-input recovery control pending: blocked audit1

This continuation made no performance progress. Readback confirms normal3Windows tasksRunning andLinuxreceiveractive. Latest System/Kernel-Power566 remains07:54:43.9830968-04:00 reason3; no newer566. This log is NOT direct current-display-state proof and cannot substitute for the requested user-input control. No probe running,so this is NOT a verified process wait. Previous successful inputclock probe showed unchangedlastinput and repeatedoff;user has not confirmed manualinput. Further identical benchmarks would repeat known throttled state. No supported persistent recovery has been demonstrated; simulation/focuschange forbidden. Pending manual Windows input followed by freshboundedsource test. First consecutive impasse audit;goalleftactive,not achieved.


### Manual-input recovery control pending: blocked audit2

Second consecutive continuation at same impasse;no new performance progress. Live readback: no Viewflow-Self scheduled tasks,no motion fixture process,WPR not recording,mainWindows transport taskRunning,Linuxreceiveractive. No process is being waited on. User manualinput control still absent;unchanged blocker prevents valid sustaineddisplay-on baseline. Do not infer current displaystate from servicehealth,or repeat throttled benchmark as progress. Goal remainsactive until blocked auditthreshold or actualexternalstatechange.


### Manual-input recovery control pending: blocked audit3

Third consecutive continuation at same genuine impasse. Authoritative live readback: all3normalWindowstasksRunning,Linuxreceiveractive,0probeTasks,0fixtureProcesses. No activejob qualifies as verifiedwait. Usermanualinput remainsunconfirmed;normaldisplay-on cadence has not been recovered. Priorcontrols include accepteddisplayrequiredrequests,timeoutchanges,wakebroadcast,andtimerstackattribution;none demonstratedpersistentnormalrecovery. Further meaningfulperformancevalidation requires externaldisplay/inputstatechange. No input/focus injection or unrelatedapptermination attempted. Mark goalblocked,NOTcomplete;retainfull6K60/16.7msobjective. ResumeafterusermanualWindowsinput,first checklastinput/displaystate and boundedsourcecadence,thenrepeatfullphysicalend-to-endmeasurement.


### User-resumed investigation: display-on baseline recovered; eight helpers regress cadence

User authorized continuation. Fresh8s resumeclock1 probe exit0: lastinput47597640 (previous5918859),displaystate1 throughout,no repeatedoff. WGC51.339fps/copy5.146ms median. Input happened between sessions; recovery is observed,not proof of its solecause. New30s resumemap1/resumecopy1 probes omit wake-monitor broadcast and retain identical topmost/full6K dimensions. Both exit0,foregroundunchanged,display1,zeroextent/stagingmiss/terminalerrors. Map-only59.500fps,15gaps>25ms,Map.004/.006ms median/P95. Fourthreadfullcopy54.227fps,173gaps,copy4.941/6.389ms. These are source-only ordinaryRAM destinations,NOT transport/presentation acceptance.

Added explicit capture-worker8 fixture mode and expanded ParallelCopy explicitconstructorclamp to8; configured productionthreadselector/defaults unchanged(4 deployed). Windows fixture buildpassed. copy8-check.cpp hosttest passes SSE2/AVX2/cached modes,unaligneddestination,paddedpitch,heights1/3/9/3456,repeatedwrites andguardbytes. This hostpixeltest is not Windows hardwarepixelproof.

30s resumecopy8 exit0,display1,foregroundunchanged,zeroextent/miss/terminalerrors:51.524fps,254gaps,copy4.214/5.739ms. Eightthreads reduce individualcopyduration but worsen overall cadence inthissequentialcomparison;doNOTdeploy8threads as optimization. Fourthread productiondefault retained. Normal3WindowstasksRunning/Linuxreceiveractive readback aftertests. Previousmanualinputblocker cleared;full6K60/<=16.7msgoal stillunmet. Next target CPUcopy scheduling/interference or reducing memorypasses,not further blindhelpercountincrease. Goal tool stillreportsblocked and exposesnoactive setter;no falsecomplete/reset attempted.


### Four-thread scheduling control: below-normal priority does not improve throughput

Added optional ParallelCopy::configure_workers callback over helpernativehandles; production has no caller and scheduling staysunchanged. Fixture-only copy-low-priority sets/readbacks THREAD_PRIORITY_BELOW_NORMAL for3helpers andthecopycaller,leavingrender/capture threadsunchanged. WindowsfixtureReleasebuildpassed. source-copypriority1/run-source-copypriority1 retained.30s taskexit0,all4priorityreadbacksverified,display1,zeroextent/miss/terminalerrors:48.247fps,274gaps>25ms,maxgap1316.667ms,copy5.283/6.881ms median/P95. Longgapmayincludeexternaltransient;do not attribute everygapsolelytopriority.

Samebinary/default-priority followup copyprioritycontrol1 taskexit0:55.231fps,143gaps,max33.333ms,copy4.721/6.276ms. Foregroundunchanged/display1. These sequentialresultsprovide no evidence fordeployinglowerpriority; retainnormalpriority4threadproductiondefault. All3WindowstasksRunning/Linuxreceiveractiveverifiedafterrestoration. Noinput/focustest. Full6K60/16.7msgoalstillunmet;source-only ordinaryRAM destination isnotend-to-endproof. Further tuning should target copiedbytevolume/memorypasses or measuredhardwarecontention,not assume lesspriorityimprovesrendering.


### WGC dirty-region capability probe: available but full-area for full-motion fixture

Reviewed FrameChangeTracker (wholecaptureversion/metadata skip only) andSHM1 reference(slot/epoch/sequence/fullwidth/height;no baseframe/patchrects). Blindpartialslotwrites would reuseunrelatedbankcontents andbreak snapshots; delta transportneedsexplicitbase/recoverysemantics.

Added offdefault VIEWFLOW_WGC_DIRTY_PROBE read-only WGC diagnostic,capabilitychecked once,one sampledframeper120,reportingframeDirtyRegionMode,rectcount,sumarea andcontentarea. Sum explicitlymayoverlap;not aunion/coverageproof. APIexceptionsdisableprobeandretainfullcapture. Callbacksserializedbyexistingdeliverymutex. No frame/capturemode/ABI changes. Firstbuildrequired Windows.Foundation.Collections projectedheader; correctedbuildpasses. Sourceinclude duplicatecleanedafterbuildwithoutsemanticchange.

8s dirtyprobe1 taskexit0,display1,foregroundunchanged,zeroextent/stagingmiss/terminalerrors. supported1,mode0(ReportOnly),samplesframes1/121/241/361 eachone rectanglewith21233664pixels=6144*3456fullcontent. Map-only59.749fps. Thus dirtyrectapiisavailable but cannotreduce bytes inthisfull-changingfixture;not evidenceoflocalupdateprofitabilityforrealapps. Needreduce representation/copycostforfullchangesaswell,not redefinegoalasstatic/partialscene60fps. Productionbinary/defaultsunchanged;all3Windows tasksRunning/Linuxreceiveractive verified.

API reference: https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.direct3d11captureframe.dirtyregions?view=winrt-26100 . Goal6K60/16.7msstillunmet.


### Resume within raw-BGRA scope: release staging before transport notification

User rejected encoding/compression direction; no codec/compression implementation was written. Scope remains existingrawBGRA IVSHMEM copy/readback/synchronization/presentation. Inspection found Readback::poll held mappedtexture andexternalcapturelease through publish(frame),whoseproductioncallback performswrite_frame andsourcebookkeepinglocks. SHMpublicationalreadyowns independentpixelsbeforethiscallback.

Changed scopedUnmap to idempotentrelease and callrelease before notificationcallback,retaining destructorcleanup forcopyfailure. Querytiming remainsbeforeexplicitrelease. Addedregression assertion that externalcapturerefcount isalreadybacktopreadoptionvalue inside throwingnotificationcallback. Existingpixel/crop/resize/reuse/adoption/atlasfallback suite WindowsReleasebuildpassed; WARP17x13 and hardware6144x3456 executionsbothexit0,exactpixelchecks passed. No keyboard/mouse/focusinjection. Files mirroredto guestsource, onlytestexecutablebuilt/run;productionbinarynot rebuilt/deployed thisturn. Actualfps/latencygainunmeasured,goalstillunmet. Nextbuild/deployrawtransportchange andmeasurefullpipeline withcurrentdisplaystatepreflight.


### Early staging release deployed; current full-pipeline measurement remains over budget

Built Windows reverseRelease target inbuild-16k. Backedup previousproductionbinary atbuild-banks/Release/viewflow_windows_reverse.before-release-staging.exe(SHA256 F79F2CCA4E912C6A329115F58874CC72AFE48624CEFBF42F784A532CBB4A6430),stopped onlymaintransport task,copiednewbinary,verifiedsource/destinationSHA2567FCDB747CD188AFE12E2CA9CE73C4D51CBA62E21664108B72DE2E299F85D3000,andfinallyrestartedtask/Linuxreceiver. NativeprocessreadbackPID8216usesbuild-banks deployedpath. No compression/encodingadded;diagnosticexperiments remainoffdefault.

Ran existing physicalmotionrunner withuniquetagphysical-release-staging1;30snonactivatingfull6Kfixture,clockcalibrationbefore/after,DP4powerrestored. Fixture1755submissions/30.006732s=58.487fps,48Present>25ms,display1,foregroundunchanged. Fullsource1516matchingpublications. SourceMapmedian.003ms,ready-observation4.909/7.022ms median/P95,SHMpublication4.040/4.888ms,pipewrite.0104/.0156ms. Therefore avoidingholdthroughnotificationis correctness/resource-lifetime improvement,butthisrun'snormalpipewriteswerealreadyshort;do notclaimlargefpsgain.

PhysicalDP4matched80samplednewcaptures: capture-to-Waylandfeedback39.778/45.939ms median/P95(max95.647),actualatlas6144x3456. HEADLESSresultnotphysicalproof. Clockendpointenvelopehalfwidth.119ms;unobserveddriftnotbounded. ProducerWGCcapture-to-enqueue medianisnegative(-1.377ms),so donotinterpretthatstageasphysicalelapsedwork; rawtimestampsemantics needcaution. Presentationfeedbacknotphoton. No controlledold/newABhere;cannotattributecurrentlatencydifferencevsolderexperimental3msdeadlineprofiletothischange. Normalprofileused,existingpluginsnotreloaded. TaskReadyaftercompletion,mainRunning,Linuxactive. Full6K60/<=16.7msgoalunmet. EvidenceJSON/logsretained.


### Exact host-stage correlation locates dominant delay after window submission

Analyzedphysical-release-staging1 matching80DP4captures: medianpostpublication31.716ms,butnohostframetrace existed tosplitqueue/accept/compositor. Addedrun-release-hosttrace.py temporaryruntimeunitdropin enablingonlyVIEWFLOW_HOST_FRAME_TRACE,uniquepathassert,finallyremove/daemonreload/restart. 30s physical-release-hosttrace1 runcompleted;alllogs/clock/state/power retained. Existingpluginsunchanged,nomousekeyboard/focusinjection.

Exact80sampledDP4framejoins showmedian/P95total35.469/39.692ms;sourcecapture->publication7.205/11.273ms;publication->hostready.674/.892ms;hostqueue.025/.119ms;accept3.139/5.016ms;acceptend->presentation24.507/28.199ms. DoNOTsum independentlycomputedpercentiles. Postsubmitdominates;not justified tocontinueoptimizinghostqueue basedonthese samples. Notphoton;timestampandcalibrationcaveats retained. Differentrun/traceenabled,notcontrolledperformancegainvs39.8msrun.

Runtimehosttraceoverride removed;systemctlreadbackactiveandnormalenvironmentonlySHM_LEASE,RAW_CUDApersistent,GPU_ALPHA,PRESENTATION_TRACE. Goalunmet. Next investigate compositor/driverpresentdeadline/buffering withcontrolledsamepipelinecomparison,withoutreloadinguserexistingplugins. Noencoding/compression.


### Current raw pipeline with standalone3msdeadline: median18.604ms,tailstill32.773ms

Readhyprland-lua skill andhyprctlreference;directshellhyprctl initiallyusedstalessocket,thenresolvedactivesession throughfusion.hyprland_env. Live0.56.2/efb5099LuaDRM matchesexperimentbinaryhash;pluginperformsruntimeABIcheck. Existingplugininventorycontainsnoexperiment. Ranrun-physical-deadline.py enabled3 withuniquesuffixrelease-staging1,unchangedcurrentBGRAtransportparameters. Noexistingpluginreload,inputorfocusoperation.

DP4actual6144x3456,80unique matchedsampledcaptures:18.604/32.773msmedian/P95,max54.982ms;comparedrecentnormalprofile39.778/45.939ms,stronglysupportsrender-schedulingasdominantlever,notcontrolledsimultaneouscausalprooforclaimedearlyreleasegain. Waylandfeedbacknotphoton. Experimentstatusenabledtrue,lead3000000ns,fallbackmask0,armed2236,fired2231,late-timermax19.223ms,115presentintervalsover1.5period:tailmissesremain. Captureclockcaveatsandproducerfuturetimestampsremain.

Runnerdisable/unloadcompleted;before/afterpluginlistsexactequal,Linuxreceiveractive. ExperimentalpolicyNOTpersistentlyenabled. Full6K60/<=16.7msgoalunmet;nextfocusontaildeadline/timerschedulingandremainingrawcopylatency. Noencodingorcompression.


### Deadline clock and CPU budget diagnostics rule out broad event-arrival lag

Inspectedexperiment:refreshphaseusesmonotonicobservedpresentarrival. Addedoffproductionexperimentalstatuscounters foreventtimestampage (acceptedonlyfinitevalidtimespecwithinprevious1s;no claimHWclock),timerlateness>1ms,andlate+originalcallbackCPUduration>configuredlead. Nochange to schedulingalgorithm ortimebase. Build/CTest1/1passed. Unique3msclockdiag1physicalruncompleted;pluginlistbefore/afterexactequal,experimentunloaded.

2231eventswithcomparabletimestamp,0invalid;arrivalage mean.073017ms,max2.624988ms. Timer2226fired,6late>1ms,max10.667238ms;30CPUbudgetmisses vs111presentintervals>1.5periodoutof2230. These areaggregatecounts,NOTone-to-onecorrelationandCPUdurationdoesnotincludeallGPUexecution. Evidence doesnot supportgeneral eventarrivalclockbiasasthemaincause,or attributingalltailmissestosleep/timerlateness. NeedGPU/commitcompletionattribution andsource/refreshphaseanalysis. RawBGRApipelineunchanged;nocodec/compression,noinput/focus. Goalunmet.


### Five-ms lead reduces output cadence misses but not end-to-end latency

InspectedinstalledAQ SCommitResult/SPresentEvent APIs andlocalDRM/scheduler source. CommitID mapsqueuedcommits;currentHyprlandnormalrenderpathcalls synchronouscommit. CannotassumequeuedcommitResultIDsprovidecurrentGPUcompletionproof. NoGPUcompletioninstrumentationclaim.

Ranunchangedrawpipelinewithstandalonelead5ms,uniquetagphysical-deadline-5p0-lead5-control1. DP4exact80newcapture samples:19.579/34.905msmedian/P95,max40.237ms. Plugin2352presentintervals,only5over1.5period(vs111/2230at3msclockdiag1),2347timerfires,4CPUbudgetmisses(vs30),8timerlate>1ms. Source/hostclockandfeedbackcaveatsremain. Thuslargerleadprovidesmarkedlysteadieroutputcadencebutdoesnotimprovenewcapturelatencyinthesesequentialruns;not sufficientforgoal. Do notconflatecompositorrefreshcadencewith60uniqueWindowsframes.

Pluginbefore/afterlistsexactequal;experimentdisabled/unloaded,productionpolicyunchanged. Nextcorrelatereceiveraccept/commit withactualrenderstartandpresentation toidentify missedclient-frame samplingwindows/phasealignment. Full6K60/16.7msgoalunmet;nocoding/compressionintroduced.


### Same-clock render-span correlation: phase waiting, no extra observed render cycle

Added bounded4096-entryarray ofexperimentrenderbegin/end/due/lastpresentarrival,serializedonlyinstatusaftermeasurement. NoadditionalhotpathI/O,algorithmunchanged. Build/CTestpassed. run-phase-hosttrace.py temporarilyenableshostframetrace andruns5msdeadlinewithsuffixphase1,finallyremovesunitoverride/restartsnormalreceiver. Pluginbefore/afterexactequal,normalenvironmentrestored,receiveractive.

analyze-render-phase.py correlateshostacceptend/physicalDP4feedback withactualexperimentrenderstart/end,restricts6144x3456sourceframesandtracecoverage. 2388spans(<4096cap),79matchedsampleswithpostaccept-renderbeforefeedback:accept->firstrender5.361/11.088msmedian/P95;firstrender->feedback4.932/4.984ms;accept->feedback10.184/15.973ms. Eachsamplehasexactlyonecompletedrenderbeforefeedback,including>1msmargin. This doesnotprovebuffer/fenceidentity,butprovidesnoevidenceofadditionalqueuedrendercycleinthese79samples. Coverageexcludesrenderalreadyinprogressataccept;donotgeneralizetoallframes.

Exacttail80DP4samples:total19.273/23.363msmedian/P95(max40.241),capture->publish4.243/8.029ms,hostready.678/.884ms,queue.026/.181ms,accept2.933/3.709ms. Do notsumindependentpercentiles;notphotonandWGCtimestampcaveatsremain. Dominantsteadywaitingisrefreshphaseplus5mslead;remainingbasepipelinealsoexceedstargetbudgetwhenphaseunfavorable. Nextaddressrawcopy/uploadcostandcapture/refreshphasealignment,nocodecs. Goalunmet.

### Isolated raw CUDA upload baseline

Added `raw-upload-baseline.cpp`, a bounded offscreen CUDA driver probe. Build with `c++ -O2 -I/opt/cuda/include raw-upload-baseline.cpp -lcuda -o probe`. Uses anonymous CPU memory registered with flags 0, the same registration flags as the receiver; 6144x3456 BGRA (84,934,656 bytes), 20 warmups plus 120 samples per destination. Each sample includes synchronous cuMemcpy2D and cuCtxSynchronize. Full destination readback byte comparison passes for both linear memory and RGBA8 CUDA array. No input injection, focus changes, production settings changes, or codec work.

Recorded `raw-upload-baseline.txt`: linear median/P95 1.5872/1.6997 ms (53.511 GB/s); array 1.6412/1.8026 ms (51.750 GB/s). Initial run array 1.6663/1.8063 ms. This differs from earlier live GL-interoperable upload copy 2.580/3.512 ms. The isolated probe omits actual IVSHMEM banks, concurrent guest writes and GL interop; sequential measurements cannot attribute the difference or promise a ~1 ms gain. Next isolate those factors before changing upload synchronization or ownership. Baseline is not end-to-end evidence; 6K60 within one frame remains unmet.

### Offscreen GL interop and isolated tmpfs upload controls

`raw-upload-interop.cpp` extends the baseline with EGL device/pbuffer GLES3, matching CUDA device selection, immutable GL_RGBA8 storage and WRITE_DISCARD registration. The GL case measures map + get-array + synchronous copy + unmap + context synchronization, not copy alone. Build using the baseline command plus `-lEGL -lGLESv2`. Optional `--tmpfs` creates and immediately unlinks a private /dev/shm file, maps it MAP_SHARED, and never accesses live Viewflow slots. All cases check the entire uniform test buffer after readback. This is byte preservation for the test pattern, not a varied-pixel routing test.

Anonymous run (`raw-upload-interop.txt`): linear 1.5722/1.7714 ms, CUDA array 1.6328/1.8230 ms, GL texture 1.8470/3.7601 ms median/P95. Isolated tmpfs run (`raw-upload-interop-tmpfs.txt`): linear 1.5949/1.7553 ms, CUDA array 1.6817/1.7923 ms, GL texture 1.8737/3.0964 ms. 120 samples after 20 warmups per case; renderer confirmed NVIDIA RTX PRO 6000. GL interop adds some median cost in this control but does not by itself reproduce prior live copy median 2.580 ms. Plain MAP_SHARED tmpfs also does not reproduce that median. High GL tails exist even offscreen. These short sequential controls do not establish causal attribution for concurrent live workloads, GPU texture use by alpha/render stages, or frame pacing. Next compare live GPU/host concurrency and texture reuse, not codecs. No production changes or desktop input/focus manipulation. Goal remains unmet.

### Completed-transfer synchronization and 60 Hz controls

`raw-upload-sync-control.cpp` compares synchronous cuMemcpy2D, cuMemcpy2DAsync on the default stream, and cuMemcpy2DAsync on a nonblocking private stream. All timed samples wait for stream completion after resource unmap. Host mapping stays registered/alive until all work completes. Uses a varied deterministic per-byte/row pattern and full readback comparison (all nine cases pass). Build with CUDA/EGL/GLES libraries as above. `--tmpfs --paced` adds absolute 16,666,667 ns spacing before each transfer; sleeps are excluded from transfer timing. This requested pacing is not evidence of actual desktop presentation cadence.

Unpaced (`raw-upload-sync-control.txt`) GL median/P95: sync 1.8110/3.1137 ms, async-default 1.8282/3.0554, async-private 1.8214/3.0067. Paced (`raw-upload-sync-control-paced.txt`): sync 1.7992/2.0441, async-default 1.8872/3.7344, async-private 1.7927/1.9715. 120 samples plus 20 warmups per case. No meaningful median benefit from simply changing API or stream; tails vary and sequential short runs do not prove a tail improvement. The ~2.58 ms earlier live median is not reproduced by 60 Hz spacing alone. Do not deploy an async conversion on this evidence. Remaining live-only differences include producer/consumer memory concurrency and actual GL workload/texture use. Production service remains active and unchanged; no user input/focus manipulation, no codecs. Goal remains unmet.


### Fresh live upload trace after offscreen controls

`run-live-upload.py` temporarily enables host-frame and CUDA call tracing, uses the existing nonactivating 30-second 6K fixture and standalone 5 ms render-deadline experiment, and restores the runtime unit override in finally. Tag `physical-deadline-5p0-live-upload1`; exact plugin inventories before/after equal, receiver active, final environment contains only normal lease/persistent-CUDA/GPU-alpha/presentation trace. No Windows binary replacement or capture scheduling override in this runner.

1570 exact 6144x3456 uploads: map median/P95 .023/.031 ms, copy 2.657/4.387 ms, unmap .023/.041 ms. Hence the live upload difference remains reproducible; resource mapping is still small. Concurrent GPU telemetry is in live-upload-gpu.csv and includes run/cleanup intervals, not per-frame attribution. Full PCIe generation 5 x16 observed. Fixture1756 submissions/30.010051s=58.514 fps, foreground unchanged; fixture submissions are not received/presented unique FPS.

80 matched physical DP4 samples: capture-to-feedback median/P95 25.893/30.094 ms, max38.174. Capture-to-publish7.512/10.439, publish-to-ready.622/.782, queue.024/.146, accept3.464/6.170, submit-to-feedback13.892/19.258 ms. Independent percentiles cannot be summed. Clock endpoint envelope half-width .120 ms; these remain WGC/Wayland software timestamps, not photon latency. Sequential prior runs differ in phase/load; do not infer a regression caused by tracing. Goal still unmet. Next prioritize live concurrency and producer copy/readback scheduling; neither raw API replacement nor offscreen bandwidth alone explains the pipeline.

### Estimated source-publication overlap with host upload

`analyze-copy-overlap.py` reconstructs source copy intervals backwards from pack_begin using publish_ms, converts clock domains using calibration, and approximates host copy start from accept_begin plus map/array durations. Both boundaries omit unmeasured setup/unmap/log time, so this is exploratory correlation, not an exact DMA trace. Source-end shifts -1, -.5, 0 ms test sensitivity but do not establish an error bound.

For live-upload1, only19–32/1570 uploads have estimated overlap exceeding .5 ms. The remaining1538–1551 still show median2.6485–2.650 ms (P95 about4.38 ms); overlapping samples median3.04–3.28 ms. This does not prove lack of other producer/GPU readback contention, but direct SHM publication overlap is not a supported explanation for the broad median gap. Do not serialize the pipeline based on this correlation.

### CPU-cache-flushed offscreen control

`raw-upload-cold-control.cpp`, invoked `--tmpfs --unpaced --cold`, issues clflush for each64-byte cache line plus mfence before starting each timed transfer. This isolates CPU cache residency; it does not reproduce a concurrent guest writer, actual guest mapping attributes, or GPU texture consumption. Flush cost is excluded and adds substantial spacing between samples, so this is not throughput evidence. 120 samples per case after20warmups, all varied-pattern full readbacks pass. Synchronous GL median/P95 1.8874/2.9266ms; async-default1.8382/3.1627, async-private1.8388/2.7490. Linear and standalone array remain about1.6ms. CPU cache flushing alone does not reproduce live2.657ms median. No production settings changed. Remaining next control should model actual prior GL texture use or inspect mapping/device-memory attributes, rather than assume raw synchronous API or CPU-cache warmth explains the gap. Goal unmet.

### Mapping inspection, prior GL use, and equivalent FFmpeg context

Read-only receiver smaps snapshot in `live-shm-mapping.txt`: four aligned1GiB bank mappings, offset0, rw-s,4KiB pages; idle snapshot bankRSS0 (not proof of residency during motion or CUDA pinning). Source Mapping uses ordinary MAP_SHARED file mappings. No suspicious offset/alignment found; smaps does not prove guest cache attributes.

`raw-upload-gl-use-control.cpp` adds a full-size framebuffer blit reading the uploaded texture after every GL transfer, glFlush without glFinish, so the next map must account for prior GL use. Sync GL median/P951.9898/3.1407ms, async-default1.9758/3.1560, async-private1.9335/3.1289. Full readback checks pass. This bounded workload is not the actual alpha/compositor workload.

`raw-upload-ffmpeg-control.cpp` repeats it using av_hwdevice_ctx_create CUDA as production does, instead of direct cuCtxCreate flags0. Runtime cuCtxGetFlags confirms flags4 (blocking synchronization). Sync GL1.9421/3.9094ms, async-default1.8969/4.1535, async-private1.9338/4.1161; all varied-pattern readbacks pass. Linking additionally requires -lavutil. Context mismatch existed in earlier probes but correcting it does not reproduce live2.657ms median. Do not change production context scheduling based on this. No production changes, no input/focus manipulation. Goal unmet; next live-only factors include actual alpha/render workload, guest GPU/readback traffic, and physical shared backing rather than these isolated API defaults.

### Four-buffer rotation and production alpha comparison control

`raw-upload-four-bank-control.cpp` rotates four 84,934,656-byte source spans within one registered tmpfs mapping, retaining FFmpeg CUDA context and prior full-frame GL blit. This models source working-set rotation but not four separate1GiB mappings or guest writes. Sync GL median/P952.0078/4.0145ms; full readbacks pass. Rotation alone does not reproduce live2.657ms median.

`raw-upload-alpha-control.cpp` additionally invokes the actual platform/linux-reverse/gpu_alpha.hpp implementation after each GL upload, followed by the GL blit. All pixels have alpha1 (matching the nonactivating motion fixture); varied RGB and four source spans remain. Upload timing excludes alpha extraction and blit, but includes synchronization with any previous GL use. Build needs C++20. Sync GL upload2.0317/3.1696ms, async-default1.9414/2.7853, async-private1.9513/2.7429; full BGRA readbacks pass. This is not an alpha correctness test or total accept-time measurement. Actual production alpha comparison plus simple GL use does not reproduce the broad live median gap in this isolated control. Keep transparency/input behavior intact; no basis here to remove alpha comparison. No production modifications. Goal unmet; further isolated variants now offer diminishing evidence, so prioritize a bounded live concurrency control or source readback/copy scheduling with actual end-to-end verification.

### Bounded live capture-wake plus 250 us polling control

`run-wake-poll-control.py` saves the guest wrapper to a unique backup, prepends only CAPTURE_WAKE=1 and POLL_US=250, runs the existing5ms deadline fixture, restores the original wrapper and verifies its hash in finally. No binary replacement, no capture-paced bypass, no input injection/focus manipulation. Exact plugin inventory restored. Tag physical-deadline-5p0-wake-poll-control1.

1150 producer records: ready median/P954.668/8.875ms, Map.003/.005, publication4.102/5.301. Physical DP4 unique sampled captures n51:25.343/31.683ms, max44.279. Fixture1753/30.012018=58.410fps. **Foreground_unchanged=0**, unlike the preceding live run: foreground changed during measurement, origin not established. Treat this run as confounded, not an optimization win or a causal regression. Prior live-upload1 additionally enabled host/CUDA tracing, so it is not an otherwise identical baseline either. No basis to persist these options. Goal unmet; settings restored. Further comparison must inspect foreground/state and matching instrumentation before attributing performance.

### Opt-in per-worker copy timing prepared

Revalidated VM AllowedCPUs4-13 and earlier all-P-core comparison; no CPU affinity change repeated. Added default-off VIEWFLOW_SHM_COPY_TRACE instrumentation to shared_copy.hpp. Records each worker's start offset from dispatch and row-copy wall time, once per120copies. Worker timings are read only after completion under the existing mutex/condition-variable publication. Disabled path performs no clock reads/logging; copying, streaming-store fences, worker count and ownership remain unchanged. CPU-wall durations include descheduling and are not pure memory-bandwidth measurements.

Host C++20 copy8-check passes both enabled and disabled: SSE2/AVX2/cached variants, padded pitches, unaligned destination, small and6K extents, byte equality and guards. Enabled output saved copy-timing-check.txt. This verifies host source behavior only; Windows build/deploy and actual4-worker runtime measurement remain pending. Do not treat host8-worker timings as Windows performance. Goal unmet. Next build the diagnostic in Windows and collect a bounded real6K run to distinguish wake/start imbalance from copy duration before changing thread scheduling.

### Windows per-copy-worker trace built and measured

Windows Release viewflow_windows_reverse and viewflow_shared_frames_test built successfully; shared_frames test passed ownership, overwrite, pitch, wire and concurrent integrity (received4474). `run-copy-worker-control.py` temporarily installs the diagnostic binary and COPY_TRACE=1 only, uses the existing5ms standalone deadline fixture, and restores both original executable and wrapper with SHA256 equality checks in finally. Exact plugin inventory restored; no input/focus injection. Diagnostic remains source-only/off by default after restoration.

Tag physical-deadline-5p0-copy-worker-control1:13 sparse6K four-worker samples. Maximum worker start delay per copy median .024ms, max .415ms. Worker0..3 copy medians3.495,3.222,3.867,3.739ms; per-copy worker-duration spread median .892ms/max1.169ms. These CPU-wall intervals include descheduling, not isolated memory bandwidth. Typical dispatch wakeup is small versus copying; no support for replacing condition variables with busy waits. Worker imbalance and bulk copy/read scheduling remain candidates.

Fixture1778/30.012586=59.242fps, foreground unchanged.75 unique sampled physical captures:24.414/29.167msmedian/P95,max45.871. Software feedback, not photon; no optimization success claim. Analyzer/output copy-worker-control1-analysis.json retained. Goal unmet. Next investigate copy execution/partition imbalance while preserving fences/slot ownership rather than optimizing the measured-small wakeup.

### Opt-in dynamic row assignment: improved balance, no proven end-to-end gain

shared_copy.hpp adds VIEWFLOW_SHM_COPY_DYNAMIC=1 (default off): workers claim exclusive64-row chunks via relaxed atomic fetch_add. Frame parameters and counter reset remain under the existing dispatch mutex; each chunk retains its streaming-store sfence and publication still follows all-worker completion. No encoding or pixel reduction. Static partition remains the default.

Host copy-dynamic-check covers1/2/4/8threads, SSE2/AVX2/cached, unaligned destinations, padded pitches, heights around64-row boundaries and6K, guards and exact byte comparisons; passes enabled/disabled. Windows Release builds and shared-frame ownership/overwrite/pitch/wire/concurrent integrity test pass with dynamic enabled (received662; count is not throughput proof).

run-copy-dynamic.py temporarily deploys new binary and enables tracing/dynamic, runs5ms deadline fixture, restores original binary/wrapper with hash checks; plugin inventory exact restored. physical-deadline-5p0-copy-dynamic1:10 sparse samples, per-copy worker duration spread median .1625ms/max .5ms versus static .892/1.169.1131 publications median/P953.790/5.430ms versus preceding static3.974/4.786. Ready observation4.999/26.031ms; fixture57.944fps, **foreground_unchanged=0**, so sequential comparison is confounded.62 physical sampled captures28.410/30.725msmedian/P95, not photon. No demonstrated end-to-end gain; do not enable by default. Local balance improvement is only a candidate, not achievement of6K60/16.7ms. Goal remains unmet.

### Foreground-confound instrumentation

Inspection of copy-dynamic1 fixture logs shows last_input_ms advanced62810500->63133578 during its30-second run, alongside foreground change. This proves session input state changed, not who generated it; do not attribute it to the user or fixture without evidence. Added read-only per-frame foreground sampling to motion_fixture.cpp: logs changed HWND, PID/TID, QPC/frequency and last-input timestamp, plus change count (detects changes returning to the initial HWND). Does not enumerate titles, set focus or inject input. It may miss transitions between samples. Windows fixture Release build passed. User agreed to a one-minute quiet window for a fresh dynamic-copy measurement.

### Quiet dynamic-copy run exposed transport extent transition

physical-deadline-5p0-copy-dynamic-quiet1 completed and original binary/wrapper hashes plus plugin inventory restored. Fixture1791/30.006698=59.687fps, foreground summary changes0 and unchanged1. Session last-input timestamp nevertheless advanced63133578->63236968 (origin unknown; do not attribute to user).2686K producer records; publication3.867/4.748msmedian/P95;3 sparse worker samples are too few for a robust comparison.

**Invalid as sustained6K benchmark:** host accepted2526K frames in its first reported5.33seconds, then switched to1x1 frames at about1Hz. Guest WGC capture logs continued at6K to fixture end while source scheduling logged unchanged skips. This is a transport selection/residency/visibility transition candidate, not proof of stalled WGC or dynamic-copy regression. Need inspect actual feedback before assigning cause.16 matched physical6K samples23.676/74.344ms are not a full-run performance result. Do not promote the59.687fixture submission rate to receivedfps. Next diagnose why the test window left full-frame transmission without manipulating user focus. Goal unmet.

### Quiet-run root cause: Linux workspace visibility changed

Exact residency logs resolve the prior hypothesis.17:55:45.226 DP4 active workspace4, fixture workspace4, demand6144x3456.17:55:49.466 DP4 active workspace3 while fixture remains workspace4, demand0x0. Both logged client.visible=true, illustrating why that flag alone is insufficient. Display remains on. Source honors zero demand and host later accepts1x1 periodic frames. This is consistent with intended nonresident transport savings, not evidence of dynamic-copy corruption or a WGC stall. Windows foreground staying unchanged does not guarantee host visibility. Do not disable production residency savings as a performance workaround.

Added analyze-run-validity.py, reporting residency transitions, accept extents and sampled foreground changes. Quiet run classified invalid_or_confounded with observed_zero_residency_demand and observed_non_6k_accept_interval, foreground changes0. Analyzer explicitly does not certify validity when no violation is logged, nor turn aggregate accept reports into sustained unique frame/photon proof. Future benchmark must keep its own proxy visible without changing user focus, or reject visibility-disrupted intervals. Goal remains unmet.

### Host reboot interrupted pinned experiment; recovered original runtime

User reported machine freeze/reboot. Previous run-pinned-copy-control process/session no longer exists; artifacts stop before cleanup. Runtime _viewflow_perf_rule is nil after restart and deadline experiment absent. Do not claim normal finally cleanup or a valid pinned run: live readback before reboot showed pinned=false. Current plugin set differs after reboot; no attempt made to reload unrelated plugins.

Windows retained temporary diagnostic binary CA09BB... and modified wrapper. Explicitly stopped only main IVSHMEM task, restored its unique before-copy-dynamic-pinned1 backups, restarted task. Verified executable SHA2567FCDB747CD188AFE12E2CA9CE73C4D51CBA62E21664108B72DE2E299F85D3000 and wrapper D0335263114FEA980CC4F4F879DA3A06DF7B8D110EE739F869760B0133EB283E. Linux receiver active. No repeated experiment/plugin load.

Previous-boot kernel journal shows repeated global OOMs around18:03–18:09, killing several desktop processes. Snapshot top RSS extraction reboot-oom-top-rss.json: VM about24.86GiB, java about14.70GiB, another java3.29GiB, Hyprland2.05GiB. This is not proof of the initiating allocation or sole cause of freeze; selected process RSS omits other system/pinned/kernel memory. Current host available57GiB/swap0 at inspection. Model services are running after reboot. Goal remains unmet; validate resource state and interrupted-test recovery before additional live comparisons.

### Post-reboot resource recovery

Read-only cgroup attribution identified four restarted model services: everos-embedding-vllm, everos-llm-vllm, jev-choice, jev-sglang. Under the user's existing explicit instruction to stop model services, stopped these four user units only; all read back inactive. Did not disable units or change models/configuration. Available host memory increased about57->77GiB, swap remains0. Current four Viewflow bank files consume about69MiB each physically (about276MiB total), not their full4GiB virtual capacity; receiver MemoryCurrent about231MiB before stopping models. This is current resource accounting, not exoneration or attribution of the prior OOM. Detailed readback in post-reboot-resource-recovery.json. Receiver active. GPU memory after stop8643MiB; remaining GPU activity not yet attributed. Goal remains unmet; next establish a visible, nonfocusing fixture with verified pinned readback and resource sampling before drawing optimization conclusions.

### Post-reboot visible baseline with explicit addressed pin

run-visible-baseline.py runs normal raw transport/normal compositor scheduling (no deadline plugin) and polls only the exact fixture title/class. It sets pin on that window address, reads pinned state, and unsets only surviving fixture instances it changed. No focus/workspace/input dispatch. Runtime113/115 fixture observations pinned=true, two pre-pin observations at creation/restart, zero observer errors. Existing normal service restart/fixture cleanup completed.

physical-visible-baseline1 shows five successive6K accept reports59.054,59.754,58.562,58.832,57.416fps; no sustained60fps claim. Fixture58.947fps, foreground unchanged.80 unique sampled physicalDP4 captures28.107/42.065msmedian/P95,max137.939; software feedback not photon. Pin now works and avoids previous zero-demand workspace transition. Validity analyzer flags a non6K interval somewhere in the full journal including startup/cleanup; must scope it to fixture-active timestamps before certification. Original production binary/config unchanged. Goal unmet; this is the new normal-scheduling/resource-recovered baseline, not comparable directly to pre-reboot experimental-deadline results.

### Dynamic copy on post-reboot visible normal-scheduling baseline

run-copy-dynamic-visible.py uses the same addressed pin observer and normal compositor scheduling as physical-visible-baseline1, temporarily enabling dynamic copy and worker trace. Original binary/wrapper restored with hash checks;103/104 observations pinned, initial unpinned only, observer errors0. Full6K accept intervals59.815,58.147,58.465,59.966,58.594fps.1583source publications median/P952.830/3.524ms versus baseline2.978/3.721 (~.15/.20ms lower in sequential runs).14worker samples duration spread median .1145ms. GPU-ready observation5.134/6.417ms essentially similar to baseline5.170/6.468.

80physical captures29.520/33.687msmedian/P95 versus baseline28.107/42.065; cannot claim general latency improvement. Fixture59.827fps but foreground_unchanged=0, so foreground transition logs must be considered and this is not a fully controlled A/B. No persistent deployment: static mode remains normal. Local copy balance/cost candidate improves slightly, far short of explaining the one-frame goal. Goal unmet; dominant remaining scheduling/presentation wait and source readiness require attention instead of over-tuning the small copy gain.

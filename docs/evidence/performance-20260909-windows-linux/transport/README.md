# 6K Windows → Linux full transport measurements

2026-09-09. Full 6144×3456 synthetic marker/grid fixture → Windows Graphics Capture → hardware HEVC plus exact alpha → paired QUIC → Linux NVDEC/CUDA/GLES → Wayland proxy → nested Hyprland desktop observed using a screencopy ROI. The final observer sees the composed desktop, not merely decoded bytes or submitted buffers. This is not physical screen scanout.

The source is Intel Graphics (8086:7d67), Intel Hardware H265 Encoder MFT. All runs use the same asynchronous alpha/readiness/CPU-buffer-reuse candidate. `50` is the original encoder quality/speed setting; `0` requests higher speed. Existing pairing credentials remain unchanged; a diagnostic QUIC unidirectional channel samples clocks alongside the normal reverse video bridge. Bench-only lifetime limits stop owned processes normally; they are not production frame deadlines.

| Trial | Distinct frames/s | Median latency estimate, ms | P95 upper, ms | Maximum upper, ms |
|---|---:|---:|---:|---:|
| baseline | 24.898 | 143.502–144.514 | 161.781 | 178.809 |
| dd-a1 | 22.240 | 183.486–184.416 | 217.783 | 234.598 |
| waitable-50-a1 | 25.512 | 95.302–96.244 | 113.646 | 131.604 |
| waitable-0-b1 | 29.527 | 84.298–85.138 | 101.977 | 618.842 |
| waitable-0-b2 | 30.382 | 86.063–86.929 | 103.805 | 105.696 |
| waitable-50-a2 | 27.493 | 80.168–81.116 | 104.737 | 114.880 |
| stats-0-a1 | 31.000 | 89.065–89.941 | 106.673 | 115.901 |

Every latency here begins before the source fixture Draw call. The observer runs for 20 seconds, discards the first three seconds for steady-state statistics, and counts the first observation of each distinct monotonically increasing marker. No long-latency observation is discarded: speed-0 B1 includes the 618.842 ms outlier. Packet rate and observer capture rate are not presented as distinct FPS.

The original fixture used an ordinary two-buffer flip queue. The waitable fixture caps its own frame latency to one and waits before drawing, using exactly the same shader and dimensions. The large change from baseline to waitable-50 is an application-fixture queue effect, not a Viewflow product optimization. The four waitable trials form A/B/B/A order. Speed 0 consistently improves distinct throughput in those runs (29.5–30.4 versus 25.5–27.5 FPS), but original-setting latency medians vary from 81 to 96 ms, so a stable latency reduction is not established. Grid image quality is checked [separately](../quality/README.md).

Clock offset is estimated from four timestamps over the paired connection. Each observation covers the full envelope of measured offset intervals within ±0.5 seconds; no symmetric network-delay assumption is used. These are sampling-based estimates, not a certified bound on clock drift between samples. Read `clock_envelope_width_ms` per run: A2 includes intervals nearly 7.83 ms wide. WGC timestamps frequently lie ahead of the callback's local clock in this environment and are not used as the end-to-end source marker timestamp.

The `dd-a1` source desktop observer reads two rows using Desktop Duplication. It measured source-desktop-to-Linux median near 98 ms, but also reduced throughput and increased pre-draw delay materially compared with baseline. It is a diagnostic run, unsuitable as an undisturbed performance comparison. The later `stats-0-a1` fixture adds [DXGI frame statistics](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/ns-dxgi-dxgi_frame_statistics), without Desktop Duplication. GetLastPresentCount increments, but the first 1,638 statistics have zero display counters and SyncQPCTime. Then one nonzero sample for frame 1,636 repeats unchanged in the last 757 queries, with no overlap with the Linux observer marker interval. The source presentation timestamp is therefore unavailable; no offset is subtracted from reported latency.

Each run archives native source/receiver configuration paths, endpoint binary hashes, marker logs, clock samples, normal exits, and cleanup state. The native source executable resides outside the runner directory. Earlier source-run hashes are checked again after transport trials in `method/native-bracketing-audit.json`; this is a bracketing file-identity check, not an in-memory executable attestation or a per-trial native hash. The statistics trial additionally hashes its native executable immediately before and after the run. `nested/` records the nested compositor configuration, geometry, and final cleanup; all preexisting root monitor rectangles and plugin lists are verified unchanged. No physical mouse, keyboard, or focus input is injected.

`comparison.json` and individual `runs/*/summary.json` are the current measurements. `summary.json` at the transport root is the retained original baseline summary and is not a current aggregate. Operational `run_qualified` means marker/clock/exit checks passed; it does not mean the performance target passed. For explicit evaluation the analyzer requires distinct FPS ≥30 and latency-estimate upper P95 ≤60 ms. No measured full-chain run meets that condition. The installed reverse executable remains unchanged; these candidates still require product integration and deployment.

Rebuild/run methods are retained in `method/`; `source/` contains the clock peer, passive fixture variants, runners, and desktop observers. Run `python method/archive.py` from the repository root to regenerate analyses, check build-input hashes and cleanup/topology evidence, and refresh the four phase-2 manifests after intentional changes.

## Additional copy, alpha, and scheduling comparisons

Each four-row group is A/B/B/A on the same native executable. Encoder quality/speed is 0, the source fixture uses its one-frame waitable queue, and the normal paired transport plus Linux receiver/observer is unchanged. Every additional trial hashes its native executable before and after. All retain full 6K dimensions and exact alpha.

| Trial | Distinct frames/s | Median upper, ms | P95 upper, ms | Maximum upper, ms |
|---|---:|---:|---:|---:|
| direct-off-a1 | 30.678 | 77.513 | 110.533 | 111.348 |
| direct-on-b1 | 30.323 | 79.948 | 96.538 | 97.625 |
| direct-on-b2 | 30.414 | 76.178 | 93.557 | 110.132 |
| direct-off-a2 | 30.676 | 77.894 | 111.019 | 111.952 |
| alpha-off-a1 | 29.764 | 78.642 | 111.859 | 161.742 |
| alpha-on-b1 | 29.410 | 91.959 | 122.269 | 173.048 |
| alpha-on-b2 | 28.848 | 84.819 | 101.712 | 167.955 |
| alpha-off-a2 | 29.263 | 91.918 | 108.927 | 142.264 |
| mmcss-off-a1 | 30.235 | 87.786 | 104.587 | 170.547 |
| mmcss-on-b1 | 30.117 | 88.085 | 104.855 | 111.663 |
| mmcss-on-b2 | 30.853 | 92.876 | 110.033 | 114.060 |
| mmcss-off-a2 | 30.501 | 87.505 | 104.531 | 125.218 |
| alpha-render-off-a1 | 30.265 | 78.960 | 108.305 | 124.969 |
| alpha-render-on-b1 | 30.502 | 89.659 | 116.118 | 132.873 |
| alpha-render-on-b2 | 30.501 | 87.986 | 104.775 | 138.318 |
| alpha-render-off-a2 | 29.233 | 80.396 | 110.828 | 147.046 |
| alpha-direct-off-a1 | 30.061 | 87.025 | 103.825 | 153.898 |
| alpha-direct-on-b1 | 31.533 | 77.932 | 95.452 | 161.651 |
| alpha-direct-on-b2 | 31.238 | 83.286 | 100.310 | 167.203 |
| alpha-direct-off-a2 | 29.822 | 89.409 | 105.944 | 173.006 |
| integrated-off-a1 | 30.974 | 76.577 | 93.916 | 142.298 |
| integrated-on-b1 | 32.795 | 90.314 | 106.948 | 108.334 |
| integrated-on-b2 | 33.211 | 80.719 | 97.607 | 164.009 |
| integrated-off-a2 | 31.266 | 89.573 | 106.256 | 173.336 |

The [owned-source direct path](../direct-source-stop/README.md) avoids atlas clear/copy only when one tile exactly covers the atlas. Enabled trials have lower P95 (93.6–96.5 ms versus 110.5–111.0 ms), while distinct throughput is slightly lower (30.3–30.4 versus 30.7 FPS). Medians overlap. This is a measured tradeoff, not a 60 ms result. The texture remains owned by the application; no borrowed WGC frame survives the callback. The later matched synthetic RGB checks and owned-window lifecycle test are described below.

The [compute alpha summary](../alpha-summary-fixed/README.md) passes exact GPU tests, but the four full-chain trials show no repeatable overall benefit. B1 worsens median and P95; B2 has a lower P95 than A2 with lower throughput. Saving CPU alpha copy/comparison cost did not establish an end-to-end gain. It is held out of production. The [render-first alternative](../alpha-summary-render/README.md) passes exact alpha tests; its standalone source run delivers 32.610 distinct frames/s, with alpha enqueue-to-collect median 12.138 ms and pre-draw-to-local-output median 115.348 ms. These standalone measurements exclude live transport/presentation. Its completed full-chain tests without the direct path show a small repeatable throughput increase but overlapping latency results.

[Source-thread MMCSS](../source-mmcss/README.md) actually registers and raises the source main thread's base priority from 6 to 19; all processes remain BelowNormal and scheduled-task priority remains 7. Its measured full-chain results do not establish a repeatable overall gain, so no reverse scheduling default is changed. The standalone source records successful explicit AvRevert on normal exit. Full transport termination is separately recorded; no scope-unwinding claim is inferred from child termination.

The [bounded WGC drain](../wgc-latest/README.md) discarded zero extra frames in all 1,513 source callbacks, giving no evidence for backlog in that fixture workload. It was not adopted. A separate [canonical capture teardown fix](../root-capture-stop/README.md) stops callbacks while source owners remain alive and passes the four existing Windows contract/wire/geometry tests. The isolated earlier 0xC0000409 was not reproduced under two debuggers; the code fix is not claimed as proof of that crash's cause.


Combining the owned-source direct path with render-first alpha summary improves both repeated B trials: 31.238–31.533 distinct FPS, median upper 77.932–83.286 ms and P95 upper 95.452–100.310 ms, versus A's 29.822–30.061 FPS, 87.025–89.409 ms and 103.825–105.944 ms. Maximum delays remain in the table; neither configuration meets 60 ms.

The [integrated candidate](../integrated-candidate/README.md) adds lifecycle fixes to that shared combination. Its A/B/B/A varies only whether unchanged capture versions are skipped. B achieves 32.795–33.211 FPS versus A's 30.974–31.266 FPS. Median and P95 overlap across repeats, so skipping duplicates has a repeatable throughput gain but no established latency improvement or penalty. An early comparison against A1 alone suggested a latency penalty; A2 does not support that general conclusion. The final canonical integration and installed controls are described below.

[Matched synthetic quality](../candidate-quality/README.md) compares every RGB pixel at 90 common markers across four source streams. Aggregate PSNR stays near 41.871 dB. This supports fidelity on this generated grid only, not arbitrary text or natural images. [Owned-window lifecycle validation](../lifecycle-v2/README.md) passes all 21 frames through Linux NVDEC/CUDA/GLES with exact alpha, title/move/second-window/resize/hide/close coverage, and single-tile direct versus multi-tile atlas paths. It is an offline decoder test, not live Wayland lifecycle acceptance. It exposed and then verified fixes for a resize with no follow-up capture and a closed handle yielding invalid metadata. Those fixes are in the [canonical 31-file build](../root-lifecycle/README.md), which passed all four Windows CTests at that stage. The later installed 39-file build is described below.

## Queue bounds, process priority and installed canonical build

The queue group runs B/A/A/B, followed by two A/B/B/A groups. All measurements use full 6K and the same paired receiver/observer.

| Trial | Distinct FPS | Median upper ms | P95 upper ms | Maximum upper ms |
|---|---:|---:|---:|---:|
| queue-1-b1 | 32.212 | 75.987 | 95.449 | 110.032 |
| queue-4-a1r | 33.621 | 82.553 | 99.276 | 100.395 |
| queue-4-a2 | 31.972 | 76.993 | 94.789 | 176.600 |
| queue-1-b2 | 32.417 | 81.919 | 98.563 | 164.950 |
| priority-off-a1 | 32.503 | 81.307 | 98.581 | 148.805 |
| priority-on-b1 | 32.829 | 79.314 | 96.158 | 146.071 |
| priority-on-b2 | 32.713 | 83.419 | 100.090 | 101.230 |
| priority-off-a2 | 32.743 | 76.419 | 93.699 | 159.582 |
| root-frame-a1 | 32.947 | 80.156 | 96.916 | 98.424 |
| root-latency-b1 | 31.765 | 91.336 | 94.770 | 111.993 |
| root-latency-b2 | 33.477 | 75.650 | 107.936 | 112.062 |
| root-frame-a2 | 33.509 | 78.406 | 95.391 | 112.417 |


Queue-depth tests have pending=0 before every submission, including the four-frame arms. The MFT input-ready event already limits this workload, so the changed admission bound does not establish an improvement. The initial depth-four launcher rejected its argument before starting Windows capture; its separate failed-run directory preserves the cleanup and is excluded from the 43 measured trials.

Normal process priority changes the observed thread bases (15 threads from 6 to 8 and ten from 4 to 6), while scheduled-task priority remains 7. Repeated performance distributions overlap; no process-priority change is installed.

The final canonical E1543F07 build includes the verified shared optimizations, metadata/resize recovery, and watched frame-rate/latency mode settings. Six CTests and both canonical lifecycle/GPU runs pass. Its frame-rate arms deliver 32.947 and 33.509 distinct FPS, with median upper 80.156 and 78.406 ms and P95 upper 96.916 and 95.391 ms. The latency arms overlap and do not prove lower latency. Limits are admission policies, not guaranteed measured benefits on this encoder.

This exact Windows binary and the controls are now [installed](../production-deployment/README.md), while the existing source/pair configurations and services retain their previous states. The measured Linux native is byte-identical to its installed counterpart. The full four-arm comparison uses the actual mode-file controller and includes native file polling. Startup mode, direct/alpha routes, frame occupancy, hashes, clock envelopes and cleanup are verified. Physical scanout and interactive gesture acceptance remain outside this fixture measurement.

## Direct VPL and canonical automatic selection

| Trial | Distinct FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|
| vpl-mft-a1 | 32.652 | 88.811 | 90.920 | 107.574 |
| vpl-direct-b1 | 42.100 | 68.809 | 85.655 | 87.678 |
| vpl-direct-b2 | 40.608 | 69.885 | 86.637 | 104.084 |
| vpl-mft-a2 | 32.062 | 83.392 | 100.144 | 102.327 |
| root-vpl-frame-a1 | 39.546 | 79.143 | 80.118 | 146.179 |
| root-vpl-latency-b1 | 40.923 | 68.746 | 85.528 | 102.051 |
| root-vpl-latency-b2 | 41.157 | 77.791 | 78.495 | 144.443 |
| root-vpl-frame-a2 | 41.003 | 68.151 | 84.992 | 151.567 |

There are now 51 qualified full-route trials. The first four rows form a same-binary MFT/VPL A/B/B/A comparison; the last four validate the canonical installed build with its real mode-file controller. VPL improves the candidate comparison, but all latency estimates remain above the 60 ms target at P95. Every logged submission has pending=0, and the one/four-frame bounds are nonbinding. Raw maximum observations, clock envelopes, native identities, nested compositor snapshots and cleanup are retained. [Candidate](../vpl-candidate/README.md), [canonical](../root-vpl/README.md), [installed](../vpl-deployment/README.md).

## WGC capture interval comparisons

Eight further qualified full-route trials compare explicit zero/32 ms, then installed-default 16 ms/zero. Getter values, raw latency maxima and cleanup are retained in [the interval experiment](../wgc-interval-v2/README.md). Neither setting establishes a repeatable benefit; the production default remains. Total: 59 qualified runs.

## Linux stage profiling

The separate-native-log repeat adds one qualified full-route trial (total 60). One preceding mixed-log trial is explicitly unqualified because a clock record interleaved with diagnostics. [Linux CPU stage timings and limits](../linux-profile-v2/README.md). No production behavior was changed.

## VPL asynchronous depth and buffered output

Two four-run comparisons bring the qualified full-route total to 68. The first candidate is rejected for deployment because its buffered-input handling is incomplete. The second adds explicit output requests and passes the 21-frame lifecycle and live-mode test. Both same-binary comparisons, actual depths, original PTS mapping, queue occupancy and all raw maxima are preserved in [the corrected candidate](../vpl-depth-v2/README.md).

## Idle output requests and capture command submission

Eight more same-binary trials bring the qualified count to 76. The idle delay experiment fails to remove long tails; the following A/B/B/A toggles D3D command submission after the owned capture copy. All maxima, WGC event gaps and CPU subintervals remain in [the experiment](../vpl-depth-v4/README.md).

## Root and nested compositor comparison

One initial nested control and four repeated topology trials bring the qualified count to 81. The initial root top-marker attempt is explicitly rejected, then both arms use an interior marker ROI with saved images. Root and nested P95 ranges overlap. [Detailed topology and cleanup record](../root-headless/README.md).

## Qualified ordered drain and canonical two-task mode comparison

Eight additional qualified trials bring the total to 89. The same-binary depth comparison and canonical four-arm mode comparison preserve original PTS, all raw maxima, actual depths and surface counts. Null-input output requests follow completed tasks and exclude fresh inputs until drain ends. Bounded transport stops may leave one or two accepted tail frames; all lifecycle streams instead finish every accepted frame and drain cycle. [Candidate and canonical records](../root-depth/README.md), [installed identity and rollback](../depth-deployment/README.md).

## Two-task capture interval interaction

Four new qualified trials bring the total to 93. Zero interval improves throughput but increases P95 in both repeats. Actual API readback, two-task pool counts and drain accounting are retained. [Interaction results](../depth-interval/README.md).

## Two-frame outer admission limit

Four additional qualified trials bring the total to 97. The limit-two candidate is slower than both four-frame controls and is rejected. [Source, actual mode readback, occupancy and latency](../depth-limit/README.md).

## Deferred drain admission experiment

Four qualified trials bring the total to 101. Deferring drain start reduces premature drains and improves the two-frame P95 relative to the previous limit-two candidate; FPS remains variable. [Candidate and lifecycle evidence](../depth-limit-v2/README.md).

## Marker-to-PTS stage diagnosis

Five qualified diagnostic trials bring the total to 106. Each steady observed marker maps uniquely to the decoded PTS, allowing actual source/encode/network/decode/desktop stage pairing. Instrumentation overhead and clock-envelope limits remain explicit. [Details](../marker-profile/README.md).

## Combined drain and capture cadence

Six qualified trials bring the total to 112. Both zero-interval/four-frame trials meet the operational P95 criterion, while the two-frame runs remain variable. Long-duration and lifecycle validation are still required before deployment. [All six trials](../depth-combined/README.md).

## Long observations expose queue growth

Two qualified 100-second observations bring the total to 114. They do not meet the 60 ms P95 criterion despite the two earlier short successes. Source queue growth and per-stage timing are preserved; C914 remains installed. [Explicit cadence candidate](../mode-combined/README.md).

## Quota stop and final diagnostic

The final 100-second source-wait diagnostic brings the total to 115 qualified trials. Requested 1 ms sleeps stayed below 3.45 ms, while inventory and alpha polling had isolated long CPU durations. No new optimization followed the observed 7% remaining quota. The installed C914 version and two existing modes are retained; the 60 ms target remains unfulfilled under sustained P95 measurement. [Final diagnostic](../source-wait-profile/README.md).

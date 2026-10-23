# Linux host DMA latency and asynchronous alpha candidate

Read-only motion4 analysis, followed by an isolated headless GPU correctness test. No service deployment, focus change, or input injection.

## Motion4 observations

Using the approximate motion boundary already recorded in motion4/analysis.json (PTS 10904246682–11104246682):

| Stage | Samples | Median ms | p95 ms |
|---|---:|---:|---:|
| Source write_end to host ready | 633 | 0.636 | 0.865 |
| Host ready to accept_begin | 633 | 0.038 | 0.171 |
| Host accept_begin to accept_end | 633 | 5.820 | 6.881 |
| Host accept_end to Wayland presented | 48 | 24.627 | 32.962 |
| Host ready to Wayland presented | 48 | 30.691 | 38.267 |

Source/host alignment uses clock-start offset_mid_ns, uncertainty ±0.078 ms. End calibration differs by about 0.007 ms. No queued host frame was superseded. The source already delivers approximately 32 fps; the host does not explain the lost half of generator submissions.

Steady host reports attribute ~5.53 ms to alpha extraction and ~0.11 ms to DMA upload submission. This does **not** isolate alpha GPU time: synchronous GL_QUERY_RESULT waits behind the earlier external-memory-to-local-texture draw. Commit-to-presentation medians remain ~24–26 ms, despite existing swap interval 0 and immediate Wayland flush. CPU draw-submission ~0.16 ms is not GPU completion time. A timer-query breakdown is still needed before assigning all delay to alpha or the compositor.

## Candidate

`GpuAlphaAsync` in `platform/linux-reverse/gpu_alpha.hpp` provides one bounded in-flight extraction with monotonically tagged versions. Submission rejects busy/older versions rather than waiting. Poll uses a zero-timeout fence. Only after the comparison fence completes does it read the query result; changed alpha then starts asynchronous PBO readback and a second fence. CPU maps the PBO only after that fence completes. Unchanged results share the last completed alpha plane.

Caller must retain the last completed alpha metadata for unchanged window layouts, keep real frame alpha on GPU, and ensure newly sized/rearranged windows have matching alpha before using their input/shadow metadata. Poll must continue without new media frames. Explicit reset requires a current owning GL context. The candidate does not change window presentation or services until integrated by the main owner.

## Validation

Built `viewflow_gpu_alpha_test` in `/tmp/viewflow-udmabuf-probe-build` and ran on NVIDIA RTX PRO 6000 Blackwell Workstation Edition. PASS for existing synchronous cases and new async cases:

- 1×1, 3×1, 17×9, 257×513, 6144×3456, 31×2 dimensions and partial packed rows;
- changed → unchanged → changed → unchanged;
- busy submission and old/duplicate version rejection;
- resize with equal packed allocation dimensions;
- immediate ordered source-texture overwrite after submit preserves the submitted version's alpha;
- pending reset and fresh version sequence after reset.

This is correctness evidence, not a live 6K60 or sub-frame latency pass. No asynchronous GPU timer instrumentation was added.

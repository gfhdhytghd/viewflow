# Optimization parity review — 2026-09-13

Read-only source/runtime audit, performed while the other audit workstreams were
implementing viewport-residency feedback and redeploying the routes. This is not
final deployment or physical-input acceptance. No input or focus was injected.

## Six-direction implementation inventory

| Direction | Existing implementation | Evidence / qualification |
| --- | --- | --- |
| Linux → Windows | DMA-BUF → EGL/CUDA → hardware NVENC; sparse 128-pixel cells; transparent-cell rejection; conservative opaque overlap pruning; 256 DIP adjoining-edge cache; dynamic atlas growth; shared double-buffered receiver surfaces instead of full per-window textures | `atlas_source.rs`, `gpu_compatible_encoder.rs`, `gpu_sparse_atlas.cu`, Windows sparse presenter. Current desktop-source configuration explicitly uses `occlusion: opaque`; seam cache omitted means default 256. Duplex restoration is a separate workstream. |
| Windows → Linux | HEVC hardware encode, direct single-owned-surface fast path, skip unchanged captures with periodic refresh, async alpha readback/GPU opacity summary, Intel VPL pooled NV12 inputs and depth 2, selectable frame-rate/latency scheduling; CUDA hardware decode and GPU copies to GL | `platform/windows-reverse/main.cpp`, encoder implementation, `platform/linux-reverse/gpu_decoder.cpp`. Same source implementation as Windows → Mac, but deployment/runtime must be checked independently. |
| Windows → Mac | Same Windows source optimizations; Mac hardware decode to NV12 IOSurfaces, L8 alpha plane and unchanged-alpha/mask cache, worker reconstruction, Metal composition and pooled resources | Initial `windows-runtime.txt` explicitly reports direct surface=1, capture changes=1, alpha summary=1, VPL selection and allocated pool=3. Initial Mac presenter was an older session copy; this is a deployment gap, not proof the current file lacks these optimizations. |
| Mac → Linux | ScreenCaptureKit latest-sample capture, unchanged-pixel skipping, encode/completion/inventory workers, direct single-buffer path, HEVC VideoToolbox pipeline, alpha extraction; Linux CUDA hardware decode/GL presentation | `window_source.mm`, `window_codec.mm`; initial active source logs show HEVC, scale 2, 60 FPS requested and worker pipeline. Static completion rate does not establish animation throughput. |
| Mac → Windows | Same Mac source implementation, Windows hardware decode/native composition | Shared implementation does not establish active use on this route. Initial listener had no source enrolled. |
| Linux → Mac | Viewflow DMA-BUF capture plugin and GPU NVENC through `vf-hyprland-windows`; Mac optimized decoder/presenter above | Separate per-window wire/source, not `vf-media-peer` sparse atlas. Initial route was idle and installed helper differed from packaged helper. Feature/build and active executable provenance must both be checked. |

## Pixel-saving policy is not identical across routes

The older documented sparse grid, transparent-cell removal and opaque overlap
pruning were specific to Linux → Windows. Reverse/per-window wire formats did
not inherit those capabilities merely by sharing an encoder. The concurrent
residency work adds cropped visible bounds and feedback to those paths. That
should be described as viewport pixel savings, not as proof all routes now have
identical opaque-overlap/transparent-cell sparse pruning. Source capture may
still retain full source buffers. Separate foreground windows and glass halos
must remain available for composition.

The old `docs/occlusion-and-transparency.md` still describes the pre-change scope
and should be updated by the residency owner once the final wire behavior is
settled. No evidence here proves the six routes have equal bandwidth or FPS.

## Concrete build provenance issue found

`crates/viewflowd/build.rs::build_gpu_encoder` lists explicit Cargo
`rerun-if-changed` dependencies, but omits `gpu_sparse_atlas.cu`,
`gpu_sparse_atlas.cuh`, and `sparse_atlas_plan.hpp`. CMake includes
`gpu_sparse_atlas.cu` in the static library. A change limited to these sparse
sources can therefore leave Cargo reusing the previous linked native library
without invoking CMake. Reported to the parent for a narrow dependency-list fix.
A clean native build or a change to a listed dependency avoids the stale build,
but is not a durable replacement for the missing declarations.

## Linux forward prerequisites checked

- `tools/build-desktop-app.py:72` includes `native-gpu-nvenc` for Linux builds.
  This feature also includes `native-nvenc`.
- `vf-media-peer send` compiled without that feature explicitly errors; there
  is no silent CPU fallback. `--help` or config validation alone cannot prove
  the installed binary has the native send implementation.
- Build requirements are native Linux CUDA/nvcc, EGL/GLES, CUDA driver/runtime,
  and libavcodec/libavutil headers/libraries. Successful Cargo metadata or Rust
  checks alone do not verify the linked native implementation.
- A live `hyprctl plugin list` showed both `viewflow-capture` and
  `viewflow-hyprland` loaded. Capture provides pixels; the second plugin provides
  metadata/input. Plugin presence alone does not establish current capture frames.
- Source runtime uses a two-worker Tokio runtime so clock/QUIC work can progress
  while the native GPU owner remains on its calling thread. A regression test
  explicitly covers that behavior.
- Current desktop source chooses AV1 and latency mode; the Windows reverse
  source initially used HEVC and frame-rate mode. These are intentional route
  settings, not evidence an optimization is disabled. Fewer in-flight frames
  do not guarantee lower measured end-to-end latency.

## Acceptance boundary

The initial audit already found inactive routes and stale running copies. The
final result needs newly deployed executable hashes plus sustained paired frame
counters for each exercised route. Input, physical display, audibility and
cross-machine clipboard behavior remain distinct boundaries. Neither a listener,
a feature flag, nor this shared-code inventory proves all six paths fully usable.

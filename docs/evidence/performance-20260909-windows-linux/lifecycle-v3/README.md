# Canonical lifecycle and live settings changes

2026-09-09. The same nonactivating owned-window fixture now runs the canonical native with opt-in diagnostics. Both runs change modes frame-rate → latency → frame-rate → latency through the real SSH controller while capture continues. Every emitted record passes Linux NVDEC/CUDA/GLES upload and exact alpha, and all seven title/move/add/resize/hide/close phases are observed. This is recorded-stream lifecycle validation, not live Wayland or physical-input acceptance.

- root: 20 decoded frames; 0 resize recoveries.
- root-v2: 20 decoded frames; 0 resize recoveries.

The resize recovery count is observed, not forced: a resize can deliver a new frame without needing the 500 ms retry. The earlier lifecycle-v2 trace exercises that retry. Phase timestamps follow Win32 actions, so signed differences are not action-to-output latency. Per-run summaries are authoritative; root-level summary.json is the preserved initial root run. The Linux probe sources match the previously compiled probe.

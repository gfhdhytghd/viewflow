# VPL window lifecycle and exact alpha

2026-09-09. 21 recorded frames pass Linux NVDEC/CUDA/GLES decoding, all alpha bytes and metadata checks. The owned fixture changes title and location, adds another window, resizes, hides and closes windows. All seven phases appear. Both single-window direct submission and multi-window atlas composition are exercised; no input events are injected, and sampled foreground identity stays unchanged.

The native source observes frame-rate → latency → frame-rate → latency while running, with limits 4 → 1 → 4 → 1. Processes exit normally; scheduled tasks and handles are cleaned up, and the previously installed E154 binary/configuration remain unchanged during this historical trial. The canonical trial uses automatic VPL selection; the earlier candidate forces VPL. Startup and resize reinitialization are separate from steady 6K timing. This is recorded-stream lifecycle qualification, not live Wayland lifecycle or physical input acceptance.

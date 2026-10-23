# Bounded extra WGC frame drain

2026-09-09. The callback tries at most one additional frame from its two-buffer pool. In the 30-second fixture run, all 1,513 callbacks report discarded=0. This workload provides no evidence for queued obsolete WGC frames or a benefit from the extra drain. No production WGC change was adopted.

The 35 build-input files are archived under `source/`; local and remote SHA-256 maps agree. Build logs and actual probe status are retained in `method/`.

Standalone source run: 999 decoded frames with exact opaque alpha, 30.598834 distinct frames/s after warmup; pre-draw to local output median 115.4677 ms, P95 131.3512 ms. This excludes QUIC and Linux live presentation and is not an end-to-end acceptance result. All emitted frames decoded, normal bounded exit, no remaining candidate processes, and installed native hash unchanged.

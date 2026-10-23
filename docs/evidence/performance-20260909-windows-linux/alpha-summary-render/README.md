# Render-first alpha summary

2026-09-09. This variant extracts R8_UNORM alpha using the existing render shader, then computes a compact tile summary from that plane. It avoids scattered R8_UINT UAV writes. The same 33-frame exact-alpha GPU probe passes. Full-chain A/B/B/A with the owned-source direct path improves repeated throughput, median and P95 versus that group's controls. Without direct submission, alpha summary alone does not establish a consistent latency gain. See transport/README.md via the parent folder for all measured values.

The 37 build-input files are archived under `source/`; local and remote SHA-256 maps agree. Build logs and actual probe status are retained in `method/`.

Standalone source run: 1023 decoded frames with exact opaque alpha, 32.610094 distinct frames/s after warmup; pre-draw to local output median 115.3479 ms, P95 129.6539 ms. This excludes QUIC and Linux live presentation and is not an end-to-end acceptance result. All emitted frames decoded, normal bounded exit, no remaining candidate processes, and installed native hash unchanged.

# Corrected compute alpha summary

2026-09-09. The corrected HRESULT macro has a unique local name; MSVC C4700/C4701 are build errors. A 33-frame GPU probe checks every alpha byte at 64×32, 67×35 and 6144×3456, four-slot queue capacity, all 256 byte values, one bottom-right 254 pixel, and opaque summary classification. Exact output passes. Opaque frames read only a 20,736-byte tile summary at 6K, while mixed frames preserve exact full alpha. Full-chain A/B/B/A uses direct-source disabled: performance did not show a repeatable overall gain, so this implementation remains experimental.

The 37 build-input files are archived under `source/`; local and remote SHA-256 maps agree. Build logs and actual probe status are retained in `method/`.

Standalone source run: 999 decoded frames with exact opaque alpha, 29.889786 distinct frames/s after warmup; pre-draw to local output median 128.8966 ms, P95 149.9643 ms. This excludes QUIC and Linux live presentation and is not an end-to-end acceptance result. All emitted frames decoded, normal bounded exit, no remaining candidate processes, and installed native hash unchanged.

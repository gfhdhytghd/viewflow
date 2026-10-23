# VPL encoder candidate and paired A/B/B/A comparison

2026-09-09. A single 68-file native build contains the previous Media Foundation encoder and an explicitly selected VPL backend. Six Windows CTests pass. VPL uses the existing System32 runtime, an owned external NV12 input, nominal 60 Hz/24 Mbps CBR/HEVC Main, target usage 7, one in-flight color task and two HEVC tile columns. Capture, alpha, native transport, decoder and observer binaries are kept fixed.

| Trial | Distinct FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|
| vpl-mft-a1 | 32.652 | 88.811 | 90.920 | 107.574 |
| vpl-direct-b1 | 42.100 | 68.809 | 85.655 | 87.678 |
| vpl-direct-b2 | 40.608 | 69.885 | 86.637 | 104.084 |
| vpl-mft-a2 | 32.062 | 83.392 | 100.144 | 102.327 |

Both VPL trials improve distinct FPS, median and P95 versus both MFT trials in this group. This is the complete pre-draw → WGC → HEVC/exact alpha → paired QUIC → NVDEC/CUDA/GLES → nested Wayland desktop observation route. It is not physical scanout latency. VPL submit-to-color-ready medians are about 22.5–22.8 ms versus 30.1–30.2 ms with MFT; this interval is not a pure encoder hardware timer.

The 21-frame candidate lifecycle test and 90-marker full RGB comparison pass. The [canonical build](../root-vpl/README.md) then adds automatic selection and fallback and is tested separately.

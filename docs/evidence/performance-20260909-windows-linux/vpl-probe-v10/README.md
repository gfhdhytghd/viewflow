# AV1 versus HEVC encoder capability and timing

A same-binary A/B/B/A compares HEVC and AV1 on the existing Intel hardware runtime. Both accept full 6144×3456, target usage 7, 24 Mbps CBR, AsyncDepth 1, one reference and GopRefDist 1. HEVC keeps two columns × one row. AV1 Query returns warning 5 and changes the requested two columns × one row to two columns × two rows. An extra requested one-column AV1 probe is also changed to two × two and produces the same bitstream; it is not a distinct tile configuration.

| Trial | Codec | Requested columns | Actual columns × rows | Median ms | P95 ms | Max ms |
|---|---|---:|---|---:|---:|---:|
| hevc-a1 | HEVC | 2 | 2 × 1 | 17.770 | 26.755 | 27.413 |
| av1-b1 | AV1 | 2 | 2 × 2 | 22.695 | 23.058 | 33.432 |
| av1-b2 | AV1 | 2 | 2 × 2 | 22.714 | 23.152 | 33.730 |
| hevc-a2 | HEVC | 2 | 2 × 1 | 18.118 | 26.078 | 26.236 |
| av1tiles1-c1 | AV1 | 1 | 2 × 2 | 22.725 | 23.176 | 29.494 |

Each run outputs 120 timestamp-ordered access units; timings discard 20 warmup frames and include GPU preparation, encoder submit and sync, excluding file/log writes. HEVC streams are byte-identical to each other, and all three AV1 streams are byte-identical to each other. The AV1 settings tested here have higher median encoding-path duration and do not justify replacing HEVC for this performance task. Other AV1 configurations and image-quality tradeoffs are not evaluated.

Both HEVC files pass all 120 frames through the existing NVDEC/CUDA/GLES probe. All three AV1 files decode 120 frames without errors through FFmpeg av1_cuvid, explicitly retaining CUDA/NV12 frames at 6144×3456. That file decoder flushes at EOF; this does not qualify live static-frame behavior or the Viewflow AV1 protocol, which was not implemented. Its guessed elementary-stream frame rate is not used for timing. Installed C914CC47 and main-task Ready state remain unchanged; every isolated encoder process exits.

API and hardware references are retained in method/codec-reference.md. Hardware support is established by actual Query/Init/encode/decode results.

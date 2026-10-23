# Explicit video-encoder input binding

This same-binary A/B/B/A probe compares application-owned NV12 textures with render-target binding only (32) and render-target plus VIDEO_ENCODER binding (1056). VideoProcessor writes the input directly. Both resource variants succeed; all four output streams are byte-identical and all 120 frames in each pass Linux NVDEC/CUDA/GLES decoding at 6144×3456.

| Trial | Encoder bind | Median ms | P95 ms | Max ms |
|---|---:|---:|---:|---:|
| bind0-a1 | 0 | 18.087 | 23.854 | 24.061 |
| bind1-b1 | 1 | 18.071 | 26.503 | 27.621 |
| bind1-b2 | 1 | 18.062 | 26.045 | 26.224 |
| bind0-a2 | 0 | 18.129 | 25.963 | 27.206 |

Both paths have approximately 18 ms median preparation-to-completion duration, and the added bind has no consistent P95 advantage. This change is rejected for production. A near-zero application copy does not prove the driver makes no internal copy. Measurements use 120 changing solid-color frames, discard 20 warmup frames, and do not include WGC, transport or presentation. The probes create no windows or input events; normal exits and absent processes are recorded. The installed source remains C914CC47.

[Microsoft bind-flag documentation](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/ne-d3d11-d3d11_bind_flag) permits flag combinations but does not promise zero-copy encoding. This isolates the encoder flag from the earlier rejected allocation using decoder, shader-resource and shared flags together.

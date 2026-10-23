# Intel VPL isolated encoder experiment

2026-09-09. External allocator supplies an application-owned render-target NV12 input. VideoProcessor writes that texture and the encoder consumes it, with no application CopyResource into another input. One- and two-column HEVC cases each encode 120 frames. Each complete output file is byte-identical to the corresponding explicit-copy case. This does not prove the driver performs no internal copy.

| Trial | Exit | Median path ms | P95 path ms |
|---|---:|---:|---:|
| external1-a1 | 0 | 22.690 | 23.023 |
| external2-b1 | 0 | 18.043 | 26.128 |

The successful probes use 120 changing solid-color GPU frames at full 6144×3456, HEVC Main, 24 Mbps CBR, nominal 60 Hz, target usage 7, asynchronous depth 1 and no B-frame reordering. Timings discard the first 20 frames and include frame preparation, encoder submission and completion; synchronous file writes and stderr logging occur outside each reported per-frame total. They are neither WGC/QUIC/Wayland measurements nor physical scanout latency. GPU timestamp intervals can include driver scheduling and cross-engine dependencies; do not add or subtract them as independent engine costs. A near-zero copy interval in the external-input probe means no application copy was issued, not zero driver work.

All successful output streams pass Linux NVDEC/CUDA/GLES decoding and expected dimensions for all 120 access units. The probe is bounded and creates no windows or input events. Its process is gone after each run, Windows main remains Ready, and installed reverse SHA256 remains E1543F07… . API headers and MIT license are archived with their upstream revision; local/remote source hashes match. The native probe DLL dispatch loads the existing System32 libvpl.dll.

References: [Intel encoding procedures](https://intel.github.io/libvpl/latest/programming_guide/VPL_prg_encoding.html), [HEVC tile structures](https://intel.github.io/libvpl/latest/API_ref/VPL_structs_encode.html), [official D3D11 allocator sample](https://github.com/intel/libvpl-tools/blob/main/tools/legacy/sample_common/src/d3d11_allocator.cpp).

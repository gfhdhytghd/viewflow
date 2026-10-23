# Intel VPL isolated encoder experiment

2026-09-09. Same explicit-copy path with HEVC tile columns 1, 2 and 4 and GPU timestamp queries. Each requested tile count is reported back by the runtime. These are individual exploratory samples, not a repeated proof that two tiles are best.

| Trial | Exit | Median path ms | P95 path ms |
|---|---:|---:|---:|
| tiles1-a1 | 0 | 25.643 | 25.948 |
| tiles2-b1 | 0 | 24.354 | 24.639 |
| tiles4-c1 | 0 | 25.387 | 26.096 |

The successful probes use 120 changing solid-color GPU frames at full 6144×3456, HEVC Main, 24 Mbps CBR, nominal 60 Hz, target usage 7, asynchronous depth 1 and no B-frame reordering. Timings discard the first 20 frames and include frame preparation, encoder submission and completion; synchronous file writes and stderr logging occur outside each reported per-frame total. They are neither WGC/QUIC/Wayland measurements nor physical scanout latency. GPU timestamp intervals can include driver scheduling and cross-engine dependencies; do not add or subtract them as independent engine costs. A near-zero copy interval in the external-input probe means no application copy was issued, not zero driver work.

All successful output streams pass Linux NVDEC/CUDA/GLES decoding and expected dimensions for all 120 access units. The probe is bounded and creates no windows or input events. Its process is gone after each run, Windows main remains Ready, and installed reverse SHA256 remains E1543F07… . API headers and MIT license are archived with their upstream revision; local/remote source hashes match. The native probe DLL dispatch loads the existing System32 libvpl.dll.

References: [Intel encoding procedures](https://intel.github.io/libvpl/latest/programming_guide/VPL_prg_encoding.html), [HEVC tile structures](https://intel.github.io/libvpl/latest/API_ref/VPL_structs_encode.html), [official D3D11 allocator sample](https://github.com/intel/libvpl-tools/blob/main/tools/legacy/sample_common/src/d3d11_allocator.cpp).

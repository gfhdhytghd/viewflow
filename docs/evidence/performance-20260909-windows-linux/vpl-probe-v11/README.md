# Compute shader versus video processor NV12 conversion

After NV12 UAV capability succeeds, the same binary compares a BT.709 compute shader with the existing video processor. Both arms use the same BGRA RTV/SRV input and NV12 RTV/UAV output resources, same external allocator, HEVC settings and two tiles. The compute shader loads 2×2 RGB blocks, writes four luma pixels and averages chroma. NV12 views are unbound before encoder submission.

| Trial | Conversion | Total median ms | Total P95 ms | GPU conversion interval median ms |
|---|---|---:|---:|---:|
| processor-a1 | video processor | 18.104 | 26.278 | 3.882 |
| compute-b1 | compute | 24.605 | 26.093 | 12.646 |
| compute-b2 | compute | 27.689 | 29.422 | 12.713 |
| processor-a2 | video processor | 18.023 | 18.457 | 3.869 |

All four runs encode 120 complete timestamp-ordered frames and pass all 120 through NVDEC/CUDA/GLES at full 6144×3456. Each pair of repeated bitstreams is byte-identical, but compute and video-processor bitstreams differ. Pixel-level conversion equivalence was not established; this slower shader is rejected without production integration. The GPU timestamp intervals include scheduling/dependencies and are not independent engine costs. Timings discard 20 warmup frames; file/log writes are outside per-frame totals. This solid-color probe does not substitute for full transport performance or grid/text quality qualification.

The compute path is approximately 12.7 ms in its measured GPU conversion interval versus 3.9 ms for the video processor. API support alone was insufficient to predict benefit. Installed C914CC47, main task Ready state and unrelated services remain unchanged, with every probe process gone. No windows or input events are generated.

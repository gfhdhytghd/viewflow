# VPL depth comparison with buffered output recovery

This isolated candidate adds nonblocking request_output to the encoder wrapper. On a full public admission limit, unchanged source frame or atlas reconfiguration, it queues null-input EncodeFrameAsync output for accepted timestamps that do not yet have sync tasks. Polling completes them in order without resetting the session. The Media Foundation path treats this request as a no-op. Input textures, bitstream buffers and original timestamps remain independently owned. The two-depth comparison uses the same binary and still validates actual GetVideoParam depth and QueryIOSurf counts.

| Trial | Depth | Distinct FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|---:|
| depthv2-1-a1 | 1 | 41.336 | 73.690 | 90.739 | 108.069 |
| depthv2-2-b1 | 2 | 53.288 | 63.275 | 64.017 | 80.599 |
| depthv2-2-b2 | 2 | 46.987 | 59.445 | 76.227 | 576.637 |
| depthv2-1-a2 | 1 | 40.983 | 70.510 | 88.973 | 106.498 |

The [21-frame lifecycle test](../lifecycle-depth-v2/README.md) also exercises three live performance-mode changes. All accepted timestamps produce output once and in order, including every static buffered input. These are CPU-observed pre-draw to nested desktop latency envelopes, not physical scanout times; the 60 ms P95 target remains unmet. The installed executable was kept unchanged throughout these trials.

API basis: [Intel VPL encoding functions](https://intel.github.io/libvpl/latest/API_ref/VPL_func_vid_encode.html) documents MORE_DATA input consumption, null-input draining and surface ownership.

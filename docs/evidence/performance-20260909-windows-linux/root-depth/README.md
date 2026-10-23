# Canonical two-task VPL encoder

Before null-input drain, existing encode tasks must complete; fresh input is blocked until the drain has returned MORE_DATA and all accepted PTS have output. A 20 ms idle coalescing interval avoids asking to drain during ordinary capture catch-up. Public admission limits and resize request output immediately. These changes were tested together; their separate causal contributions are not established. No new session age cutoff is introduced. Input textures remain owned until the driver releases them.

The canonical implementation defaults to two VPL tasks and allocates max(depth+1, QueryIOSurf minimum, QueryIOSurf suggested) surfaces. Actual readback is AsyncDepth=2 with three surfaces in both public modes; their outer admission limits are 4 and 1. All 69 local/remote build inputs match and six Windows CTests pass.

| Trial | FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|
| root-depth-frame-a1 | 54.872 | 62.938 | 63.633 | 130.126 |
| root-depth-latency-b1 | 41.922 | 77.260 | 77.902 | 144.390 |
| root-depth-latency-b2 | 40.505 | 76.410 | 77.603 | 94.688 |
| root-depth-frame-a2 | 54.169 | 56.998 | 73.623 | 140.351 |

Measurements cover full 6144×3456 through paired QUIC, Linux GPU decode/upload/draw and nested desktop observation. Values are upper clock-envelope estimates of fixture pre-draw to observation; physical scanout is unmeasured. All raw maxima are preserved. The 60 ms P95 target is not met by this series.

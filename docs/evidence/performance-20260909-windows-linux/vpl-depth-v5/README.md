# Ordered VPL drain and capture-idle coalescing

Before null-input drain, existing encode tasks must complete; fresh input is blocked until the drain has returned MORE_DATA and all accepted PTS have output. A 20 ms idle coalescing interval avoids asking to drain during ordinary capture catch-up. Public admission limits and resize request output immediately. These changes were tested together; their separate causal contributions are not established. No new session age cutoff is introduced. Input textures remain owned until the driver releases them.

Same-binary A/B/B/A compares explicit VPL depths one and two with a public frame-rate admission limit of four. The canonical integration changes the default to two. All 69 local/remote build inputs match and six Windows CTests pass.

| Trial | FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|
| depthv5-1-a1 | 39.880 | 77.373 | 94.183 | 127.127 |
| depthv5-2-b1 | 52.937 | 67.901 | 83.405 | 151.657 |
| depthv5-2-b2 | 51.282 | 66.278 | 81.713 | 149.986 |
| depthv5-1-a2 | 37.758 | 73.249 | 90.286 | 173.302 |

Measurements cover full 6144×3456 through paired QUIC, Linux GPU decode/upload/draw and nested desktop observation. Values are upper clock-envelope estimates of fixture pre-draw to observation; physical scanout is unmeasured. All raw maxima are preserved. The 60 ms P95 target is not met by this series.

# Two VPL tasks and capture interval interaction

Same-binary A/B/B/A rechecks the optional WGC update interval after the canonical encoder moved from one task to two. Local/remote 69-file source maps match and six Windows CTests pass. The only source change from C914CC47 is the optional interval API and its diagnostic log. Runtime readback confirms initial 16 ms and actual requested 16 ms/zero in every arm. The VPL depth remains two with three input surfaces and public frame-rate limit four.

| Trial | Interval us | FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|---:|
| depthinterval-default-a1 | 16000 | 53.464 | 63.278 | 63.945 | 146.769 |
| depthinterval-zero-b1 | 0 | 58.468 | 73.552 | 74.088 | 140.763 |
| depthinterval-zero-b2 | 0 | 59.765 | 67.832 | 68.140 | 84.681 |
| depthinterval-default-a2 | 16000 | 54.465 | 64.946 | 66.772 | 131.842 |

Zero interval improves distinct throughput to 58.47–59.76 FPS versus 53.46–54.46, but raises observed P95 to 68.14–74.09 ms versus 63.95–66.77. It therefore offers a measured throughput/latency tradeoff, without meeting the 60 ms P95 target. It has not been deployed; the public-mode combination requires qualification before adoption. The earlier one-task interval result cannot substitute for this interaction test.

All measurements cover the complete 6144×3456 route through QUIC, GPU decode/upload/draw and nested desktop observation, excluding physical scanout. Ordered output and drain barriers pass diagnostic accounting; private tasks, windows and compositors are removed. Installed source/configuration remains unchanged. [Microsoft API reference](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.minupdateinterval?view=winrt-28000).

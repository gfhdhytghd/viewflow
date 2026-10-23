# Defer drain start until active encoder tasks complete

This isolated candidate retains VPL async depth two and three surfaces, sets the latency admission limit to two, and defers request_output until pending GPU tasks have completed. Once draining begins, new input remains paused until the null-input completion barrier. This removes premature drains triggered while an ordinary output could shortly free an admission slot. The 20 ms idle coalescing behavior is retained.

69 local and remote source hashes match and six Windows CTests pass. All four transport runs use the same native binary with actual four/two/two/four mode readback.

| Trial | Outer limit | FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|---:|
| depthlimitv2-four-a1 | 4 | 54.977 | 62.021 | 64.758 | 79.240 |
| depthlimitv2-two-b1 | 2 | 53.464 | 56.151 | 72.782 | 77.382 |
| depthlimitv2-two-b2 | 2 | 48.625 | 69.911 | 70.465 | 73.513 |
| depthlimitv2-four-a2 | 4 | 54.225 | 58.284 | 74.841 | 75.580 |

The two-frame runs have P95 70.47 and 72.78 ms, improving the earlier standalone two-frame candidate (81.85 and 85.09 ms). FPS remains variable at 48.62 and 53.46, and neither run meets the P95 60 ms criterion. Four-frame controls reach 54.23–54.98 FPS. This candidate is not installed.

The separate lifecycle fixture passes all seven phases, 21 GPU-decoded frames with exact alpha, three runtime mode changes, and complete ordered drain accounting. Full transport tests have explicit bounded stop tails. No physical input was injected and physical scanout remains unmeasured. [Lifecycle evidence](../lifecycle-depth-limit-v2/README.md).

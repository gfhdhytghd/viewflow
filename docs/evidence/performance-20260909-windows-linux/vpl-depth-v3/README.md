# Idle buffered-output request cadence and capture instrumentation

Adds CPU timestamps for WGC event arrival, delivery lock, frame retrieval, callback dispatch, source mutex acquisition, copy submission and null-input encoder calls. Compare immediate output requests with a 5 ms wait after the source first appears unchanged; full admission limits and resize still request output immediately.

| Trial | Idle request delay ms | Capture Flush | Distinct FPS | Median upper ms | P95 upper ms | P99 upper ms | Maximum upper ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| flush0-a1 | 0 | 0 | 43.125 | 67.050 | 99.754 | 583.149 | 982.885 |
| flush5-b1 | 5 | 0 | 51.579 | 68.699 | 69.481 | 168.491 | 885.447 |
| flush5-b2 | 5 | 0 | 33.753 | 69.548 | 152.319 | 586.116 | 969.450 |
| flush0-a2 | 0 | 0 | 48.506 | 71.149 | 71.901 | 137.491 | 138.035 |

The 5 ms delay does not remove the long tails and is rejected. All raw maxima are preserved. During the long gaps, the Windows fixture continues drawing. The instrumented locks, copy submission and null-input API calls do not themselves account for the half-second gaps; WGC event arrival and encode completion both pause. These observations narrow the investigation but do not prove a driver-level cause. Extra diagnostic logging may also perturb timing. [D3D command submission experiment](../vpl-depth-v4/README.md). No version in this comparison was deployed.

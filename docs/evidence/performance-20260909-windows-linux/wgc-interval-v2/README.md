# WGC minimum update interval experiment

Isolated snapshot of the installed VPL source, changing only the optional capture-session interval API. All 69 local/remote inputs match; six Windows CTests pass. Before StartCapture, QueryInterface for IGraphicsCaptureSession5 succeeds on this Windows/SDK. The actual default getter is **160000 100ns units = 16 ms**, so explicit zero is not the installed default. Every run logs requested, before and actual getter values. Unsupported/error branches retain the normal capture path; no production code was changed or installed.

| Trial | Requested us | Distinct FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|---:|
| interval0-a1 | 0 | 41.981 | 69.383 | 86.288 | 135.688 |
| interval32-b1 | 32000 | 29.793 | 66.765 | 67.089 | 150.147 |
| interval32-b2 | 32000 | 29.614 | 70.598 | 104.101 | 154.530 |
| interval0-a2 | 0 | 41.432 | 77.952 | 81.105 | 94.197 |
| interval16-c1 | 16000 | 39.588 | 76.805 | 93.537 | 95.615 |
| interval0-d1 | 0 | 39.390 | 84.105 | 85.684 | 101.110 |
| interval0-d2 | 0 | 39.726 | 70.829 | 87.265 | 103.553 |
| interval16-c2 | 16000 | 40.512 | 65.980 | 82.652 | 100.926 |

The first A/B/B/A series compares explicit 0/32 ms. 32 ms yields only 29.61–29.79 FPS; its second P95 rises to 104.10 ms, so the first good latency observation is not repeatable. The second A/B/B/A compares the installed 16 ms default with zero. Median/P95 distributions cross and do not establish a stable benefit. Both changes are rejected for deployment. Latency is fixture pre-draw to nested desktop observation with a clock envelope, not physical scanout. These eight runs bring the completed full-route total from 51 to 59. Every trial exits normally and removes its private proxy, task and nested compositor.

Source documentation: [Microsoft MinUpdateInterval](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.minupdateinterval?view=winrt-28000). Longer update intervals can reduce capture rate; the API is optional and not an authorization or session-liveness limit.

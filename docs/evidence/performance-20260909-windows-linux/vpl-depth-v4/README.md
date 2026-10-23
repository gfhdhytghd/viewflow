# Explicit submission of owned capture copies

Same-binary A/B/B/A comparison, holding AsyncDepth 2 and immediate buffered-output requests fixed. The enabled arm calls ID3D11DeviceContext::Flush after copying the borrowed WGC surface into the application-owned texture, before returning the callback. It requests GPU command submission without waiting for completion. Input ownership, alpha and original timestamps are unchanged. Both arms retain identical stage instrumentation.

| Trial | Idle request delay ms | Capture Flush | Distinct FPS | Median upper ms | P95 upper ms | P99 upper ms | Maximum upper ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| copyflush-off-a1 | 0 | 0 | 49.165 | 68.319 | 71.761 | 218.041 | 735.234 |
| copyflush-on-b1 | 0 | 1 | 45.371 | 65.913 | 82.329 | 566.046 | 982.609 |
| copyflush-on-b2 | 0 | 1 | 52.401 | 65.196 | 111.045 | 113.838 | 148.968 |
| copyflush-off-a2 | 0 | 0 | 40.040 | 56.279 | 73.471 | 589.224 | 1039.278 |

Per-trial capture-stages.json includes WGC arrival gaps, callback/API CPU durations and the actual enable flag. This is an experiment on command submission, not proof of zero-copy or an independent GPU timing measurement. The production executable remains unchanged during these trials.

[Microsoft Flush documentation](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-flush) describes asynchronous command submission and its overhead.

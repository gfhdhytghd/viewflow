# Callback clock audit

Added diagnostic-only callback-entry QueryPerformanceCounter, keeping WGC SystemRelativeTime and frame pixels unchanged. Windows Release build passed. Bounded30second6K fixture, foreground change count0, original native/wrapper restored by runner with hash equality checks. No input or focus injection.

1539 of1565 WGC timestamps are later than callback entry. Callback-minus-WGC P50 -4.6024ms, minimum -9.9831ms. Callback-to-copy-submission P50 0.1133ms/P95 0.1982ms. This places the discrepancy before our SHM selection/host calibration and rules out downstream record association as its sole cause. Driver/compositor timestamp origin remains unresolved; no assertion that a specific driver is faulty.

Microsoft API documentation describes SystemRelativeTime as compositor render QPC: https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.direct3d11captureframe.systemrelativetime . Existing issue127 in Microsoft sample repository discusses window timestamp semantics but does not establish the cause of our future timestamps.

Analyzer now explicitly flags timestamp contradiction and separately reports callback-entry-to-first-sampled-Wayland-presentation:80samples P50 32.373ms/P95 44.686ms. This is a narrower SOFTWARE interval, excludes pre-callback work and panel scanout, and is NOT a replacement for the end-to-end goal. Raw WGC-based values retained for investigation, not validated latency. GPUcopy78samples P50 3.702ms/P95 3.920ms; SHMpublication2.848/3.643ms. Accepted frames approximately57–58.5fps, goal unmet.

Next optimize measured callback-to-presentation stages; for true frame identity/end-to-end measurement, embed and decode fixture frame sequence/QPC pixels rather than trusting only WGC metadata. Keep captured pixel identity distinct from capture callback sequence.

# Windows capture border deployment (2026-09-07)

The WGC backend now sets `IsBorderRequired(false)` and asynchronously requests
borderless access. Access errors retain capture. Windows policy and other
capture clients can still require the indicator; visual acceptance is user-operated.

Built with MSVC 19.44 in
`C:\Users\wilf\Viewflow\border-build-20260907`, Release x64. The isolated source
copy used the existing deployed reverse build's native sources, changing only
`wgc_window_capture.cpp`. Its original contents matched repository HEAD.
The existing build executable and deployed executable had the same SHA256:
`589BF65BDF8FDF1E46C9F9E5F01EB1928DAA14F0E5722BB79A558A286CFD3104`.

All four Windows CTests passed: reverse wire, reverse geometry, WGC contract,
and window-only source. Linux portable WGC tests also passed (2/2).

Backed up the deployed capture executable with a `before-border` timestamp.
The first replacement encountered the exiting process's file lock; after
confirming process exit and the unchanged old hash, replacement succeeded.
Deployed `C:\Users\wilf\Viewflow\desktop-test\viewflow_windows_reverse.exe`:
`CA1E67E04916D71C50AE5371DD84D0EA76D3E39267B7FAEF689CAFE287FA2E85`.
The deployed hash matched the new build.

Restarted `ViewflowMain-Active` and Linux `viewflow-desktop.service`.
Observed receiver PID 5744 and capture PID 4940 in Windows session 1,
committed frame 420, and continuing Linux peer probes. Linux service was
active/running. No mouse/keyboard input or focus change was injected.
The absence of the yellow border has not been visually verified.

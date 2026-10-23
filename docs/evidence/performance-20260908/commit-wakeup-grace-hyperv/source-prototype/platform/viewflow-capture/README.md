# Viewflow capture

Independent, minimal capture provider for the Viewflow MVP. The production
HyprCapture plugin and its in-progress performance work are not modified.

Scope: authorized decorated-window rendering, DMA-BUF/native-fence export,
bounded delivery and exact release receipts. No screenshot UI, recording,
audio, file export, notification UI or global compositor settings.

The GPU core and Hyprland render/control entry build independently into
`viewflow-capture.so`. The Lua namespace is `hl.plugin.viewflow_capture`, with
private-file `window_stream_start` and `window_stream_stop` controls. The atlas
source defaults to `capture_provider: "viewflow"`; explicit `"hyprcapture"`
retains the old diagnostic backend, with no automatic fallback.
Nested Wayland runtime load, three-frame DMA-BUF/fence/release, visual readback,
explicit stop and unload passed on 2026-09-06 (Hyprland 0.56.2 Lua).
Three subsequent 20-second two-window CUDA/NVENC/QUIC/Windows trials completed
with 530, 512 and 498 native submissions and clean source exits after capture
timers were aligned to a common monotonic cadence. Windows screenshots showed
the distinct Atlas-A/B fixtures. These bounded trials do not establish the full
performance, physical-presentation or input acceptance contract.
The existing HCGF/HCGR byte contract is retained to avoid rewriting the encoder
adapter at the same time. Compatibility does not imply a HyprCapture dependency.

Build and check the extracted core:

```sh
cmake -S platform/viewflow-capture -B /tmp/viewflow-capture-build
cmake --build /tmp/viewflow-capture-build --parallel 2
ctest --test-dir /tmp/viewflow-capture-build --output-on-failure
```

Do not unload the user's HyprCapture instance to test this provider. Runtime
acceptance must use a separately named plugin and an explicitly owned window
inside a nested compositor, never the user's main desktop. Use a private short
runtime directory and explicit instance selection for every control command.
The tested nested launch hid physical DRM card/input devices, exposed only
render/NVIDIA compute nodes, disabled seat acquisition and session environment
publication, and used a standalone Lua config without user autostart or plugins.

Incident regression: including `lua.h` without C linkage produced an unresolved
C++-mangled `lua_tolstring` reference. Loading appeared successful but the first
Lua call terminated the nested compositor with a symbol lookup error (exit 127).
The include now has C linkage, a CTest checks the Lua symbol references, and
`-z now` forces symbol resolution at load rather than at first invocation.
The earlier main-desktop exit had no initial crash stack; the nested reproduction
establishes this defect, but does not independently prove that exit's cause.

Capture geometry epochs now advance on changes to logical bounds, pixel sizes,
or the main-surface input sidecar. The producer rebuilds its framebuffer/export
cache when needed and continues the same capture stream across movement,
resize and popup expansion. Returning to old dimensions allocates a new epoch;
it never revives an earlier mapping. Overflow or invalid geometry retires it.

This is **capture-side** support, not complete end-to-end resize: the current
atlas owner now updates matching placements inside its negotiated canvas and
fails closed if they do not fit. Canvas enlargement and fresh input authorization
remain to wire. A 1,025-frame isolated native test
observed five epochs across resize, popup expansion/retraction and restoration;
see [capture geometry evidence](../../docs/window-family-capture.md). It checked
metadata and producer fences, not pixel content or physical display timing.
A subsequent 1,548-frame Linux-to-Windows trial visually exercised all five
geometry stages with remote input disabled; the same evidence page records its
scope and the screenshot helper's shutdown error.

Shadow/alpha visual parity and event-driven capture remain to validate. Periodic
capture now aligns equal-fps streams to the same monotonic tick grid instead of
accumulating each window's render time into its next timeout.

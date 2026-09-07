# Decorated Hyprland window capture

The primary Hyprland integration uses HyprCapture `window_capture`, not a
monitor crop or the generic Wayland toplevel source. The latter remains an
optional compatibility diagnostic. This is a backend decision, not a claim
that the running Viewflow peer already streams this interface.

Source contract inspected: HyprCapture `src/plugin/artifact_capture.cpp`,
`src/shared/protocol.cpp`, and `src/shared/protocol.hpp` in the sibling checkout.
The live compositor lists HyprCapture 0.2.7; that version label alone does not
prove the loaded binary implements every feature of the current checkout.
No plugin reload or global configuration edit is part of this integration.

## Single-frame contract

- Send a private recording-request JSON file to `window_capture`, selecting
  one exact `windowAddress`, mode `window`, border/shadow `keep`, background
  `transparent`. Do not use `export_pipe`: its inspected payload is monitors.
- The plugin replaces request contents with a session response containing the
  selected window's RGBA artifact, physical dimensions, `fullGeometry`, and
  `visibleGeometry`. Revalidate response and artifact paths before reading.
  Replacement is unlink plus exclusive creation, not an in-place write: request
  inode identity must not be required of the response. Artifact storage is a
  separate private `hyprcapture-<uid>/<session>` tree, not the request directory.
- The inspected artifact path unpremultiplies RGBA and repairs/expands shadow
  bounds. Convert straight RGBA to premultiplied BGRA once for VFBG; do not
  interpret it as already-premultiplied bytes.
- Preserve both geometries. `fullGeometry` includes the exported decoration
  extent; `visibleGeometry` identifies the main surface in logical coordinates.
  Map a main-surface point into artifact pixels using
  `(point - fullGeometry.origin) * artifactSize / fullGeometry.size`.
  Do not assume integer scale, symmetric shadows, or zero content offset.
  `viewflow_core::CaptureGeometry` now implements content/pixel round trips and
  placement of the decorated frame from a main-surface origin. It rejects
  nonfinite/invalid geometry and routes decoration pixels to no content point.
  Tests cover the actual 7-DIP/2x capture offset and asymmetric fractional scale.
  This API is not yet negotiated in the live control protocol.
- Decorations are retained as source-rendered pixels. They must not introduce
  a second destination-native titlebar. Pixel retention alone does not implement
  remote decoration hit testing, resizing, or source input routing.

## Remaining streaming work

This file-based CPU API is a bring-up path. A persistent bounded frame channel,
geometry epochs, timestamps, damage, backpressure, and GPU buffers are still
needed for the production latency target. No 6K60 or two-frame result follows
from single-frame capture.

Blur is a distinct destination-composition requirement: transparent source
pixels and shadows do not reconstruct a blur of the destination background.
Do not substitute a baked source wallpaper for that behavior.

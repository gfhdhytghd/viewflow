# Native Rust decorated-window capture timing

2026-09-04, live Hyprland 0.56.2; loaded
`hl.plugin.hyprcapture.window_capture` verified present. No config reload.

Built `hyprcapture_probe` with `cargo build --locked --release -p viewflowd
--example hyprcapture_probe`. Created a dedicated Zenity window titled
`Viewflow Rust capture timing`, PID 3702894, address `0x5605796ce210`.
These are historical test identities, not reusable live targets.

Five consecutive captures returned logical 212×137 and VFBG wire size
464724 bytes (424×274 BGRA pixels plus header). Capture durations in µs:

187708, 188096, 194754, 187977, 208334.

Timing includes request creation, compositor request/response, artifact read,
and Rust conversion; excludes network transport and destination presentation.
Even the minimum exceeds the two-frame target. Replacing Python conversion
alone does not make this one-shot API suitable for live window streaming.
Next implementation needs a persistent compositor window-frame producer that
preserves decorations and alpha, not monitor cropping. Capture artifacts remain
owned/retained by the plugin; the test window has a 45-second auto-close timeout.

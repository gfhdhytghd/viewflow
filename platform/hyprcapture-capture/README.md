# Viewflow HyprCapture one-shot adapter

`hyprcapture_capture.py` is an offline-tested, CPU one-shot fallback. It is
not a stream, an encoder, or a performance path. It writes a bounded 0600
request in HyprCapture's owner-only runtime tree, calls only the loaded
plugin's Lua API through `hyprctl eval`, validates its rewritten response and
raw artifact, and writes a new exclusive-create VFBG v1 premultiplied-BGRA
file. Existing output files are never replaced.

The adapter retains the plugin artifact and response after a successful
conversion. Their lifecycle remains HyprCapture's responsibility; the helper
does not unlink a plugin-named path after validation.

The returned metadata retains both `visibleGeometry` and `fullGeometry` for a
future Viewflow wire integration. This helper is not connected to Viewflow's
live control/media protocol.

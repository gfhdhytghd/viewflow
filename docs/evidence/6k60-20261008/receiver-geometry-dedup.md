# Deduplicate unchanged presentation geometry

Receiver draw previously called wl_egl_window_resize,wp_viewport_set_destination and xdg_surface_set_window_geometry for every video frame. Source search confirms these are the sole call sites for these setters. Added per-Window optional8int cache containing physical EGL dimensions,logical viewport dimensions,and x/y/body dimensions. First draw always sends; resize/scale/body changes resend; unchanged dimensions skip setters. Cache lifetime matches Window/surface lifetime. Actual buffer draw,swap,flush,input and retention paths unchanged.

Linux receiver build passed. This removes redundant API/protocol work; no measured latency gain yet. Headless --validate would not exercise native surface setters,so do not represent that test as geometry UX proof. Normal installed binary unchanged. Live geometry/scale regression remains pending user-operated interaction or a bounded nonactivating fixture; no input/focus injection. Reboot-dependent higher-refresh experiment still awaits user confirmation of saved application state.

## Progressive31 live fixed-size check

Same two-buffer/two-band/high-resolution60Hz settings as26,hostcompletionnotify,asyncdiagnostics.1495host markers all match; observed foreground/trace disruptions0.10-25s generated900/accepted900; preceding5s generated290/accepted290. This supports fixed-size first-map and steady delivery,not interactive resize/scale correctness or uninterrupted whole-run60fps. Generator10-25s median16.657ms,range10.544..22.745ms.

Software feedback80samples median42.235/P9555.499/max127.987ms,clock±0.095ms; sourcegen→callback median23.382ms differs from26,so no causal latency gain claimed. Keep dedup as source/build improvement pending interactive regression; no promotion. Normal guest/host binaries restored by hash checks,plugininventory restored,serviceactive. Higher-refresh reboot question remains pending.

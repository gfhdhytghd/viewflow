# Bounded Wayland toplevel capture

`viewflow-wayland-toplevel-capture` is a deliberately small Linux bring-up
tool for one explicitly selected Wayland toplevel. It uses the standard
staging `ext_foreign_toplevel_list_v1`,
`ext_foreign_toplevel_image_capture_source_v1`, and
`ext_image_copy_capture_v1` protocols and only submits a `wl_shm` buffer.
It never requests an output/desktop source, changes compositor state, or loads
a compositor plugin.

Build it separately:

```sh
cmake -S platform/wayland-capture -B build/wayland-capture
cmake --build build/wayland-capture
```

List currently mapped capturable candidates as JSON Lines (`identifier`, app
ID, title; strings are escaped so titles cannot corrupt records):

```sh
build/wayland-capture/viewflow-wayland-toplevel-capture --list
```

Capture exactly one identifier into a *new* file:

```sh
build/wayland-capture/viewflow-wayland-toplevel-capture \
  --identifier 'exact-identifier-from-list' --output frame.vfbg
```

The output is the Viewflow VFBG wire payload: `VFBG`, version `1`, format `1`
(premultiplied BGRA8), reserved `0`, then big-endian width, height, and stride,
followed by pixel bytes. `ARGB8888` is copied directly on little-endian Linux;
`XRGB8888`, `ABGR8888`, and `XBGR8888` are converted to that payload format.
Other formats and non-normal transforms fail explicitly. The default deadline
is five seconds and all source/buffer/output allocations are capped at 256 MiB.
`--timeout-ms` may lower or raise it up to 30 seconds; `--max-bytes` may lower
the allocation cap.

This is a CPU single-frame transport bring-up path, not a DMA-BUF encoder or a
high-rate capture implementation. The compositor remains the policy authority:
if it denies a source by returning a placeholder image as a successful frame,
the protocol provides no reliable client-side protected-content signal.

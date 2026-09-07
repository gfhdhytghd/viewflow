# Linux per-window capture evidence

The running compositor was Hyprland 0.56.2 (`efb50993780079460b0cbed1363e2166a2de1d9f`).
Its live registry advertised the ext foreign-toplevel list, toplevel capture
source, and image-copy-capture protocols at version 1.

Two newly created Zenity diagnostic windows were selected by their exact
foreign-toplevel identifiers. No existing user document/window was selected.
Both diagnostic processes were closed after capture. No plugin was loaded and
no Viewflow deployment service or quarantine marker was changed.

The second capture (`final-window.vfbg`, preview `final-window.png`) recorded:

```text
identifier=18000c15
format=ARGB8888
width=494 height=250 stride=1976
ready_monotonic_ms=77462989
presentation_time=0:77462.988014350
file_bytes=494020
alpha_min=1 alpha_max=255 partial_alpha_pixels=344
```

The VFBG header, length, dimensions, and premultiplied channel invariants were
checked. The decoded image was viewed and matched the diagnostic window's
title/text and rounded edges. These are capture timestamps, not a measured
cross-machine latency result. The earlier `window.*` pair is also retained.

Hashes at the second capture:

```text
toplevel_capture.c:
5db888f1b09b364040b07ef05c45640b62676b273fbdde2185c98d6f8e2a5468
capture binary:
a251b9d161e75735969a1307ed87cb5962331fb3a76fb7ae2113210c8d4815e3
final-window.vfbg:
5f091799cc1672867606e0f29f84c1f7783db406465a8651504cce8b60956593
```

After this capture, constraint-generation rejection was extended from size
changes to every incoming constraint event. That final source
`94ab341f2c879e8ad2d0990cccd54ecd85fbdbd962aec32385e0a83dbcbc9708`
and binary `61672384646db41f1d689aa63ef83f380b9943dac9250aa712cc1f61463147c0`
passed the Release build and CTest; the image above belongs to the preceding
explicitly hashed build, not a new capture of that last change.

This helper captures one frame to CPU shared memory. Persistent capture,
DMA-BUF export, hardware encoding, window-family composition, exact blur,
and end-to-end presentation/performance acceptance are not established here.
Compositor capture policy remains authoritative; a successful frame can be a
compositor-generated denial placeholder, not proof of protected-content access.

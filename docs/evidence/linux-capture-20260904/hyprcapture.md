# HyprCapture decorated single-frame evidence

Live test on 2026-09-04 used the already-loaded HyprCapture 0.2.7 plugin.
Only the newly created Zenity diagnostic window, PID 2698247, address
`0x560579163360`, title `Viewflow decorated capture test`, was selected.
The diagnostic process was sent SIGTERM after inspection. No plugin reload,
configuration mutation, deployment-service change, or marker removal occurred.

The adapter invoked `hl.plugin.hyprcapture.window_capture` with transparent
background and border/shadow keep. Successful output:

```text
artifact: /dev/shm/hyprcapture-1000/47026e9ac877-af28f4ca85fa8aeb/window-560579163360.rgba
physical size: 564x262; stride: 2256
visibleGeometry: x=0 y=0 width=268 height=117
fullGeometry: x=-7 y=-7 width=282 height=131
VFBG bytes: 591092
alpha: min=0 max=255 partial-alpha-pixels=17668
```

The 20-byte header, exact length, and premultiplied channel invariants were
checked. `decorated-window.png` was decoded from `decorated-window.vfbg` and
visually inspected: diagnostic title/text, rounded corners, and the expanded
decoration edge are present. The observed geometry is capture-local, not a
verified global desktop position; retain offsets without assuming global space.
The 7-DIP expansion at 2x scale is 14 physical pixels per side.

```text
adapter SHA256:
d57deeda24f92865ba041dfbd2b491d1d95f81aba72c3a1d3cf2a096fb038182
VFBG SHA256:
04a6b9cb38921d4b34e4601420de2dacbdffc047e5d977c264358669cda918fa
```

This proves one decorated capture through the loaded own-interface path, not
continuous capture, exact blur reconstruction, destination presentation,
occluded-window behavior, all decoration variants, or the latency target.
Plugin artifact/request-response evidence is retained, not deleted by Viewflow.

The subsequent adapter revision also rejects a response whose defaults do not
echo `windowBorder=keep`, `windowShadow=keep`, and
`windowBackground=transparent`. The retained live response was read again and
passed that check; no new capture was taken for this validator-only change.
Its unit suite contains six passing cases, including changed-policy rejection.

## Authenticated transport regression

`cargo test -p viewflowd --test media_receiver_quic` now includes
`decorated_capture_survives_quic_and_pixel_submission` (passed). It sends this
exact VFBG capture through real loopback mTLS QUIC datagrams, fragments to the
negotiated datagram size, reassembles through `MediaReceiver`, decodes through
`RawBgraSink`, and compares every submitted pixel byte with the capture.
Exactly one complete frame is submitted and partial alpha remains intact.

The presenter is a recording test implementation, not the Windows HWND. Clock
values are synthetic and each packet is drained before sending the next, so
this regression proves payload correctness only, not network throughput,
cross-host clock synchronization, loss handling, or native display latency.

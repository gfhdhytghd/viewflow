# macOS keyboard/mouse live smoke test

2026-09-07. The user explicitly authorized the assistant to perform simple live
tests in this conversation, superseding the usual user-operated-only rule for
this bounded trial. All injected input targeted a newly created, disposable
`Viewflow Input Test` window; existing application contents were not used.

Path exercised: Linux test sender → LAN mTLS QUIC → the already-authorized Mac
`viewflowd` executable, launched as a GUI-session LaunchAgent → Quartz → AppKit
test window. Receiver SHA-256:
`ce2a408dbef7a4daeb4b31eebe09abc0ea3ef70bd875d6d1cb4e318c3f02401b`.
No receiver rebuild or replacement was needed for this trial.

The first LAN attempt timed out before authentication and before any input.
The user then approved macOS's Local Network prompt. The restarted connection
authenticated successfully, and all 28 explicit input events were acknowledged
as applied. This permission is separate from Device Control and Data Access.

Observed inside the target application ([raw result](result.json)):

| Check | Observation |
| --- | --- |
| Absolute motion | Reached the requested fixture position (180, 160 in its content coordinates) |
| Keyboard and Shift | Exact text `vfTest`; six down/up pairs, Shift-modified `T` |
| Single/double click | First two mouse-down click counts were 1 and 2 |
| Held-button drag | Received `leftMouseDragged` events and reached (240, 130) |
| Vertical wheel | `scrollingDeltaY = -20` |
| Horizontal wheel | `scrollingDeltaX = -20` for protocol +0.5 rightward detent |
| Disconnect cleanup | Sender deliberately closed while Shift and left button were held; target received mouse-up followed by flags-changed with zero modifiers |
| Final held state | `shift_held = false`, `left_held = false` |

The target recorded 29 tagged AppKit events including disconnect-generated
releases. One intermediate pointer sample was coalesced by the native event
path; the final drag location and button transitions were observed. This is
not a lossless pointer-sample or latency benchmark.

[Sender log](sender.txt) records the 28 acknowledgements and intentional close.
The JSON assertions checked the text, click counts, drag presence, both scroll
axes and the final cleanup event order. The receiver LaunchAgent was removed
and the fixture was closed after recording the result. Test credentials were
ephemeral, not production pairing credentials.

Reusable tools:

- `platform/macos/input_fixture.m`: AppKit target; records only its own incoming
  events bearing the Viewflow tag, exits after a stop file or 120 seconds.
- `crates/viewflow-transport/examples/macos_input_live.rs`: requires explicit
  `--run-live`, caller-supplied test certificates and the fixture's target
  coordinates. It intentionally disconnects with held input to exercise cleanup.

For any future live run, obtain user authorization, launch the fixture as an
application, confirm it is in front, use its current `target_x`/`target_y` (display
geometry can change), and remove the receiver LaunchAgent after completion.
Do not run the live sender automatically in CI.

This trial does not establish media-key support, native touchpad support,
performance targets, every keyboard layout, all mouse buttons, or full macOS
video/atlas integration.

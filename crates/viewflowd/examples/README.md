# Raw Windows peer diagnostic

`raw_window_peer` sends a bounded sequence of raw BGRA frames. `--file` repeats
one staged VFBG file; Linux `--capture-window` requests fresh frames through
HyprCapture; Linux `--capture-stream` uses one authenticated local producer
session. This remains a bounded diagnostic, not a production streaming service.

Start the receiver on Windows (the private key, certificate, and CA bundle are
the receiver's paired mTLS identity):

```text
cargo run -p viewflowd --example raw_window_peer -- receive \
  --listen 0.0.0.0:4433 --cert receiver.pem --key receiver.key --ca paired-ca.pem \
  --title "Viewflow diagnostic" --x 100 --y 100
```

The default receiver above remains the existing one-HWND GDI `WindowsProxy`
path. An explicit Windows-only composition diagnostic can instead start the
separate native preview executable and feed it VFBG records through its private
stdin pipe:

```text
cargo run -p viewflowd --example raw_window_peer -- receive \
  --listen 0.0.0.0:4433 --cert receiver.pem --key receiver.key --ca paired-ca.pem \
  --composition-presenter C:\\path\\viewflow_windows_composition_preview.exe \
  --composition-blur-rect 9,9,760,626 --composition-blur-radius 18 \
  --visible-ms 60000
```

`--composition-presenter` is receiver-only and requires both blur arguments.
The rectangle is an intentional, CLI-selected diagnostic region, not a blur
mask inferred from alpha or a generic decoration rule. Its positive integer
`x,y,w,h` bounds are checked against the sender's initial negotiated logical
geometry before the child is started; the negotiated logical width/height,
rectangle, radius, and bounded visible interval are forwarded to the native
program. Once that child is alive, a `GEOMETRY` resize is explicitly rejected
before an acknowledgement—there is no hidden scaling or blur-rectangle remap.

Composition writes happen on a dedicated worker with a bounded one-slot,
one-in-flight queue, so a slow anonymous pipe cannot block the Tokio QUIC
receive loop. Queue acceptance is deliberately not called a GPU submission.
The receiver waits for the next ordered native
`submitted_frames=N width=W height=H` stdout acknowledgement before it sends a
successful completion; it also applies the unchanged 33.333 ms source-age gate
at that native-submission observation. An acknowledgement that is late is
rejected even if the child may already have drawn it. This is native composition
submission only, not a display-present timestamp or end-to-end latency
evidence. EOF, child exit, pipe errors, and shutdown are failures/cleanup, not
successful native submission.

Then send from Linux. `--server-name` must match the receiver certificate; no
insecure certificate bypass is available.

```text
cargo run -p viewflowd --example raw_window_peer -- send \
  --remote 172.16.105.70:4433 --server-name windows.example \
  --cert sender.pem --key sender.key --ca paired-ca.pem --file frame.vfbg \
  --logical-width 282 --logical-height 131 --frame-count 3
```

`--frame-count` defaults to 1 and is explicitly bounded to 1..=300. Both modes
default to a 10-second session timeout and 4 MiB pixel limit. They can be
narrowed with `--timeout-ms` and `--max-bytes`. On Windows the receiver keeps
its one native proxy visible for `--visible-ms` (default 2000, bounded
1..=60000) after terminal media processing; this bounded display period is
reserved in addition to `--timeout-ms`. The sender stages and
validates the fixed header and file size before allocating the full payload;
the receiver applies the same pixel limit before native allocation.

Logical dimensions are mandatory for sending and must come from the capture's
`fullGeometry`, not its physical artifact dimensions. The example above is for
the 564x262 capture at 2x scale. The receiver negotiates those logical dimensions
before READY and presents at the target window's DPI. Do not use this updated
sender with an older diagnostic receiver: the control handshake has changed.

The peers exchange four monotonic timestamps over an authenticated reliable
QUIC stream, calculate `ClockEstimate`, and invert it at the receiver before
the existing 33 ms media admission. The receiver collects each diagnostic frame
for at most 100 ms, then sends a terminal completion/rejection; the sender
allows up to one second for that reliable terminal record, independently of
media freshness. The receiver logs only frame ID, terminal outcome, and elapsed
time for this boundary. On the default GDI path, the completion receipt is sent
only after `RawBgraSink` returns successfully from native `WindowsProxy`
submission. In the opt-in composition diagnostic it follows the ordered native
`submitted_frames` acknowledgement and a second unchanged source-age check;
neither route proves physical presentation.
It proves neither physical display presentation nor cross-host end-to-end
latency: monotonic clocks need the estimate's reported uncertainty and the
native proxy API has no compositor-present acknowledgement.

Addresses are numeric IP:port; the TLS server name is separate. Use a unique
paired test identity, and run the Windows receiver in the interactive desktop
session. This example does not configure firewall rules or install a service.
The native proxy is kept alive with its message pump for up to two seconds.
Linux build-check, staged-file unit tests, and existing media loopback tests
pass. Native Windows offline check/build also passed (see
[build evidence](../../../docs/evidence/linux-capture-20260904/raw-peer-windows-build.md)).
One release-build cross-host native submission succeeded (see
[runtime evidence](../../../docs/evidence/linux-capture-20260904/raw-peer-release-live.md)).
Physical visual correctness and capture-to-display latency are not yet verified.

In `--file` mode timestamps start at sending, not the original capture. For
fresh Linux capture replace `--file frame.vfbg` with
`--capture-window 0xEXACT_WINDOW_ADDRESS` (use the actual Hyprland address).
Capture mode uses Rust conversion of HyprCapture's straight RGBA directly,
avoiding Python per-pixel conversion. The source timestamp is sampled before
the capture request and is not reset after readback/conversion. A slow capture
therefore correctly fails admission. Actual physical display time remains
unmeasured in both modes.

Capture mode currently retains plugin artifacts and limits each run's potential
retained pixel bytes to 256 MiB (`max-bytes * frame-count`). Capture requests
are bounded to two seconds. A persistent stream may resize during this bounded
run: the sender fixes that frame's translated source timestamp, sends a reliable
frame-boundary `GEOMETRY(sequence, epoch, logical-width, logical-height)` record,
and does not send media tagged with the new epoch until the receiver's matching
`GEOMETRY_ACK`. The receiver rejects stale/regressing sequence or epoch values,
commits `RawWindowSession` geometry and updates the retained logical presenter
before acknowledging. Old-epoch datagrams are dropped, so one HWND/presenter is
retained rather than recreated. Dynamic offsets, proper artifact lifecycle,
dragging, and destination blur remain unfinished. Source selection is explicit;
the example never automatically captures the desktop.

For the persistent local source use `--capture-stream 0xEXACT_WINDOW_ADDRESS
--compositor-pid PID` instead. It is mutually exclusive with `--file` and
`--capture-window`. The stream header's compositor `CLOCK_MONOTONIC` timestamp
is translated into the QUIC session clock from a paired local sample; it is not
restamped when Rust imports the sealed frame or after a geometry ACK. The
session is explicitly stopped after a normal completed run; error-path producer
cleanup remains runtime-owned and should be verified before treating this as a
continuously-ready lifecycle.

One mTLS QUIC connection and one Windows HWND are retained for the whole
sequence. Frame IDs are strictly sequential and every completion or rejection
receipt carries its exact frame ID, so delayed UDP or control data cannot
satisfy a later frame. The receiver waits only a bounded interval per frame,
pumps the native message queue while waiting, ignores old/future datagrams,
and reports a late or missing frame without preventing the next staged frame.
The control records include packet count, last chunk, first/last arrival time,
normalized age, and clock uncertainty. A three-frame loopback regression
checks first delivery, a middle late rejection, and final delivery with exact
tags. Repeated submitted pixels remain diagnostic input, not continuous capture
or physical-display acknowledgement.

## Local Windows raw preview

`raw_window_preview` is a separate, local-only Windows diagnostic for inspecting
one staged VFBG frame with the same `WindowsProxy.present_logical` renderer used
by the peer receiver. It opens no QUIC connection, needs no certificate, and
does not measure transport or latency. For a 30-second Dolphin visual check:

```text
cargo run -p viewflowd --example raw_window_preview -- \
  --file dolphin.vfbg --logical-width 282 --logical-height 131 \
  --visible-ms 30000 --x 100 --y 100
```

`--file`, `--logical-width`, and `--logical-height` are required. `--visible-ms`
defaults to 2000 and is bounded to 1..=60000; `--max-bytes` defaults to 16 MiB.
The input is metadata-bounded and validated as premultiplied VFBG before native
allocation. Its diagnostic output reports input dimensions/bytes, logical size,
target proxy DPI, and native submission elapsed time, never pixel contents.
Successful submission and message pumping are local renderer evidence only—not
transport, remote display, physical presentation, or latency proof.

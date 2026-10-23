# Coded window peer diagnostic

Pointer diagnostics now require the matching timed native preview. With
`--emit-pointer-motion`, it uses mouse `WM_POINTERUPDATE` and emits the original
QPC-derived `not_after_qpc` and `qpc_frequency` after the existing five identity/
coordinate fields. The receiver requires these fields, drops expired pipe backlog,
and retains the native-derived deadline with the latest motion. Old six-field
output and synthetic PostMessage(WM_MOUSEMOVE) are not this input path.
`--emit-pointer-motion` alone still does not send input. Synchronous stdout is
not a production latency acceptance result.

The receiver additionally implements an explicit `--forward-pointer-motion`
mode, requiring `--emit-pointer-motion` and both `--pointer-owner-id` (the preview
device) and `--pointer-source-id` (the source device), each a nonzero 32-digit
hex ID; they must differ. These IDs must match local pairing configuration and
the source's authorization, not be inferred from incoming pointer text.

The native reader clears old input state on Submitted. Only after the video
writer validates the matching submission/deadline does it attach the complete
authenticated window/epoch/frame identity. Later native moves enter the bounded
input watch with unchanged event deadlines; pre-validation moves are not replayed.
The input task starts after the first fresh video ACK and shares the same QUIC
connection: existing video records stay on their bi-stream, shared control/input
uses uni-streams. Dropping the preview/task closes the input connection.

The Linux GPU sender enables its source route with `--authorize-pointer-motion`,
the same two device IDs, and `--pointer-native-socket /private/path/native.sock`.
This requires `--capture-gpu` and the exact `--compositor-pid`. The socket parent
must already be an owned private directory; the path must not exist. Configure
the native ViewFlow plugin to connect to that path. The sender waits for this
same-user, exact-PID connection before starting capture and never loads/reconfigures
the compositor itself. Normal video-only operation remains unchanged.

Before releasing each GPU frame, the sender retains its input-binding metadata
in a bounded encoder-lineage map. Only the fresh, exact video ACK authorizes that
snapshot. Native BEGIN must succeed before the shared dispatcher advertises input.
Each grant lasts at most five seconds; a fresh video ACK in its last second can
explicitly advance the generation and expiry, with native binding reconfirmed.
Window/surface/geometry changes, capture retirement, owner loss, and missing native
ACKs terminate the route. The input task is aborted and joined before capture stop;
only this invocation's socket inode is removed. Native metadata is consumed for
target-window removal, not used as a discovery UI in this diagnostic.

**Remaining acceptance:** real cross-host pointer behavior has not yet been
verified for this source wiring. Click/drag are not implemented by this motion-only
route. Unit tests or native compilation do not establish GUI/input acceptance.

`coded_window_peer` is a time-bounded Linux-to-Windows compressed transport
check. It continuously imports the newest authenticated HCSF frames until
`--timeout-ms` elapses, while allowing only one receiver/presenter ACK in
flight.
The Linux sender accepts only an authenticated HyprCapture HCSF stream and, in
the `native-nvenc` build, sends a matched H.264 color plus lossless `VFAR`
alpha pair. Descriptors and per-frame `VFCF` metadata use the reliable mTLS
QUIC stream; color and alpha access units use QUIC datagrams.

```text
# Windows: --stdin-compressed is the native VFGP consumer executable.
cargo run -p viewflowd --example coded_window_peer -- receive \
  --listen 0.0.0.0:4433 --cert receiver.pem --key receiver.key --ca paired-ca.pem \
  --stdin-compressed C:\\path\\gpu_presenter.exe

# Linux (native NVENC required)
cargo run -p viewflowd --features native-nvenc --example coded_window_peer -- send \
  --remote 192.0.2.10:4433 --server-name windows.example \
  --cert sender.pem --key sender.key --ca paired-ca.pem \
  --capture-stream 0xWINDOW --compositor-pid 1234 \
  --logical-width 282 --logical-height 131 --composition-blur-rect 9,9,200,100 \
  --composition-blur-radius 18 \
  --max-frame-bytes 4194304
```

The receiver requires exact window/frame/epoch/config identity, matching
color/alpha source timestamps, matching descriptor dimensions, and an initial
paired IDR before it serializes `VFGP`. The 33.333 ms freshness budget is
unchanged. The source HCSF timestamp is mapped once into the QUIC session clock
and is never reset after capture, encoding, or ACK waiting. Resize is rejected
explicitly: restart the diagnostic with the new geometry.

Frames already stale before encoding are dropped. If a local encoded AU becomes
stale, the sender stops transmitting the reference chain, requests a native IDR
without recreating the hot NVENC context, and continues importing/encoding only
to preserve delayed color/alpha matching. Transmission resumes solely at an
actual IDR from an input at or after the request; delayed P frames are never
sent as a recovery shortcut. A receiver sends an exact-identity `REJECT` only
when the current reliable `VFCF` slot becomes late before presentation or its
matching datagrams do not arrive within that same 33.333 ms bound. The sender
accepts only that exact receipt, requests a native IDR, and continues the same
QUIC session under the existing IDR gate. Datagram tails from the rejected
frame cannot satisfy the next `VFCF` slot. Malformed records, codec failures,
and any identity mismatch remain terminal.

The bounded control-response wait is deliberately separate from presentation
admission: an exact late `REJECT` remains usable evidence that no VFGP
submission occurred, while an exact `PRESENTER_ACK` is rechecked against the
original source timestamp and fails once the 33.333 ms budget is exhausted.

QUIC's `max_datagram_size()` is read for each plane because its current path
MTU allowance may change. That allowance is fixed for all chunks of the plane.
If Quinn returns `TooLarge` mid-plane, the sender drops that incomplete pair,
waits for its exact `REJECT`, and then requests IDR; it never re-fragments the
same frame with a conflicting chunk count or assumes a fixed 1200-byte payload.

On Windows the VFGP child stdin is an explicit anonymous `CreatePipe` rather
than opaque `Stdio::piped`: its requested buffer is
`min(--max-frame-bytes, 1 MiB)` (never zero). Only the child read end is
inheritable; the parent writer is non-inheritable and is dropped during normal
or error shutdown so the child can observe EOF. This is a buffering change,
not a relaxation of source freshness or pipe-ACK deadlines.

At shutdown the sender emits one low-noise summary with capture count,
pre-/post-encode stale drops, IDR-gate drops, recoverable rejections,
sent/ACKed frames, sent payload bytes, bounded source-age samples, and
bounded host-only encode p50/p95 samples. These are diagnostic host timings,
not capture-to-scanout latency. The sender explicitly stops its HyprCapture
stream on normal, error, and timeout exits; stream cleanup is not delegated to
Drop.

Only one presenter submission is in flight. A matching native submission ACK
means that the child accepted its pipe record; it is not GPU scanout, physical
presentation, or end-to-end latency proof. Windows GPU presenter compilation
and a real cross-host visual/scanout check remain required gates.

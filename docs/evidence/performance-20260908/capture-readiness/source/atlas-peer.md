# Atlas peer processes

`vf-media-peer receive` is the Windows process entry for the atlas receiver.
It owns one paired QUIC connection attempt, its refreshable clock stream and
the supervised native presenter. It does not enable input by default, select a CPU
fallback, install a service, or replace the existing health-check daemon.
`vf-media-peer send` is the Linux GPU source entry. Initial membership is
explicitly configured. The opt-in desktop mode can discover additional local
windows crossing its configured viewport; see [desktop contract](desktop-drag-contract.md).
Automatic removal/replacement and reconnect are not yet wired here. Optional
paired `pointer` configuration on both peers enables window selection and
pointer forwarding; it requires `disposition_recovery`. Input remains gated
by the committed layout, original event deadline and source authorization.
Current two-window motion/button evidence and remaining limits are recorded in
[`evidence/atlas-input-expiry-20260906.md`](evidence/atlas-input-expiry-20260906.md).

Build on Windows and run from a desktop session that supports Composition:

```powershell
cargo build --locked -p viewflowd --bin vf-media-peer
.\target\debug\vf-media-peer.exe receive --config C:\Viewflow\receive.json
```

Example configuration (replace the illustrative peer address, identities,
paths and measured display/capture geometry with the authorized pair):

```json
{
  "bind": "0.0.0.0:44129",
  "expected_peer_ip": "192.0.2.10",
  "certificate": "C:\\Viewflow\\receiver.pem",
  "private_key": "C:\\Viewflow\\receiver.key",
  "certificate_authority": "C:\\Viewflow\\pair-ca.pem",
  "native_presenter": "C:\\Viewflow\\viewflow_windows_composition_preview.exe",
  "disposition_recovery": false,
  "input_recovery": false,
  "stream_id": "00000000000000000000000000000063",
  "geometry_epoch": 1,
  "config_generation": 1,
  "width": 1626,
  "height": 1240,
  "max_tiles": 4,
  "max_encoded_bytes": 8388608,
  "max_decoded_bytes": 67108864,
  "refresh_hz": 60,
  "startup_timeout_ms": 10000,
  "media_idle_timeout_ms": 3000,
  "clock_silence_timeout_ms": 3000
}
```

Unknown fields, relative identity/presenter paths, zero identities, incompatible
codec geometry and invalid resource/time limits are rejected before listening.
`refresh_hz` must describe the target refresh rate, not an arbitrary lower value
chosen to lengthen the deadline. The live age limit is exactly
`floor(2_000_000_000 / refresh_hz)` nanoseconds. Startup, clock-silence and media
idle limits do not replace that per-frame limit.

The native child receives an explicit `--max-frame-bytes` bound covering the
largest authorized V5 header, encoded pair and decoded allocation policy.
The legacy 16 MiB default is not silently imposed on this path. Accepting a
large configuration is not proof that the hardware can decode that resolution;
startup still has to complete native warmup successfully.
It also receives `--atlas-proxy-capacity` from `max_tiles` (1..4096). During
warmup it creates that many hidden HWND/Composition targets with independent,
unbound visuals on one shared graphics device. Live frames acquire prepared
slots; exhausted capacity is an error, not permission for live allocation.
No startup pixels are bound and no reserved window is shown. Removal/replacement
that exhausts the prepared slots requires a new owner; dynamic replenishment
is not implemented. Invalid capacities fail before GPU initialization.

## Linux source

Build with `cargo build --locked -p viewflowd --bin vf-media-peer --features native-gpu-nvenc`
and run `target/debug/vf-media-peer send --config /absolute/path/send.json`.
Source configuration uses `bind`, `remote`, `server_name`, absolute
`certificate`, `private_key`, `certificate_authority` paths, `compositor_pid`,
`fps`, `startup_timeout_ms`, `media_idle_timeout_ms`, `media`, and `windows`.
`media` contains the receiver's exact `stream_id`, `geometry_epoch`,
`config_generation`, `width`, `height`, `max_tiles`, `max_encoded_bytes`,
`max_decoded_bytes`, and `refresh_hz` values. Each `windows` entry contains
`window_id` (32 lowercase hex digits), `address` (Hyprland `0x` address),
`width`, `height` (full decorated capture pixels), and `geometry_epoch`.
IDs and addresses must be unique; a window ID cannot alias the media stream.
The source sorts IDs before packing. Resize/membership drift fails closed.

The GPU encoder is prepared before capture starts and produces three
independently decodable warmup pictures, using a 200ms
original-capture budget below the producer's 500ms release wait. That startup
allowance is never applied to live media. During connection/native negotiation,
the same capture streams are continuously drained: only unsubmitted frames
are released, preventing the producer's release wait from expiring. After
acceptance the live session takes the same encoder, capture pool and stop
authorities. Capture/frame lineage is never reset; the first live frame
continues after warmup and requests an IDR. Pending capture deadlines tighten
from their original timestamps to the live age policy (never beyond 200ms).
`startup_timeout_ms` starts after GPU preparation and bounds capture warmup,
connection and negotiation together. SIGINT/SIGTERM requests checked shutdown;
native capture startup workers are gathered rather than cancelled.

The source calibrates eight clock samples every 250ms, with a one-second probe
deadline and two-second mapping validity. Receiver clock-silence configuration
must allow this cadence. A clock failure closes the dedicated connection.
Nested independent-provider cross-host trials now reached 424 single-window
and 537 two-window native submissions in separate bounded 20-second runs.
Earlier repeated two-window trials failed deadlines. After aligning capture
cadence, three additional 20-second runs completed with 530, 512 and 498 native
submissions and clean local source exits. Distinct Windows fixture pixels were
also inspected. This remains bounded coverage, not the full latency contract. See
`evidence/nested-atlas-20260906.md` for the successful and failed boundaries.

On 2026-09-06, the ignored
`atlas_source::tests::real_capture_warmup_releases_and_stops_producer` test
passed against an owned 800x500 Wayland fixture, whose full decorated capture
was 1644x1044 at geometry epoch 1. It generated three independent H.264/VFAR
pairs (5935 color bytes and 59062 alpha bytes each), checked producer shutdown,
and the temporary fixture process was subsequently closed and absent from
the compositor client list. The owned-buffer CUDA/NVENC boundary test also
passed. These tests do not exercise network transmission or remote display.

To repeat the capture test, explicitly set `VIEWFLOW_ATLAS_TEST_WINDOW` to an
owned fixture address and `VIEWFLOW_ATLAS_COMPOSITOR_PID` to the active
compositor PID, then run `cargo test -p viewflowd --lib --features native-gpu-nvenc
real_capture_warmup_releases_and_stops_producer -- --ignored --nocapture`.
Do not point this test at a business window or infer pixel size from logical
client dimensions; the test probes actual capture metadata first.

Cross-host diagnostic evidence is under `/tmp/viewflow-atlas-e2e.D4Ctyr/`.
The Windows UDP receive buffer was initially 65536 bytes; the atlas entry now
uses the established media receiver's bounded 4194304-byte buffer. This did
not by itself make the run pass. In the paired-budget run, source frame 1
finished encoding at age 15849us (17483us remaining); native pipe admission
had 7522us remaining, and decode left about 73us. The owner correctly retired
on the unchanged deadline. This is failure evidence, not display acceptance.
That failed revision used a separate live encoder that had not exercised its
complete capture/alpha path during startup. The current source reuses the
warmed pipeline with continuous capture draining; its end-to-end latency
was subsequently exercised but still failed. `receiver-continuous.log` shows
live frame 4 reaching pipe admission with 14971us remaining and finishing
decode with 7191us remaining, before timing out in proxy initialization.
Per-proxy graphics devices now share the warmed D2D/Composition device while
retaining independent visuals and pixel surfaces. A repeat
(`receiver-shared-device-repeat.log`) reached decode with 6614us remaining
but did not reach the post-`CreateWindowEx` diagnostic before retirement.
The subsequent revision adds bounded hidden proxy-window preparation and
buffers its timing samples in memory rather than writing unit-buffered stderr
inside live deadlines. `receiver-submission-count.log` then recorded **159
successful native visual submissions**, followed by a frame submission timeout.
This establishes the native handoff path, not physical scanout, multi-window
acceptance or continuous-session reliability. The original two-frame age bound
was unchanged. Native CTest and negative capacity tests are separate checks.

Recovery remains opt-in work, not an enabled property of this entry. The native
binding tracker now has a tested `DiscardUnbound` operation: it only resolves
one exact pending identity, preserves layout/source replay floors, and requires
the next pair to be a fresh keyframe. It rejects ambiguous multi-frame queues,
duplicate/unknown discard and stale source identities. This bookkeeping does
not itself prove that pixels were unbound.

The native executable now exposes an experimental `--atlas-disposition-v1`
flag after the full `--stdin-atlas-v5 --max-frame-bytes N
--atlas-proxy-capacity N` arguments. Its distinct ready line is
`atlas-native-ready disposition=v1 input_enabled=false`. In that mode it can
discard an exact expired binding before decode or before any visual mutation,
and emits `atlas-disposition-v1` with frame identity, tile count, outcome,
original QPC deadline/frequency and commit ticks. A successful commit records
QPC after all visual mutations and requires it to precede the original deadline.
This is native API submission, not physical scanout. Clock errors and expiry
after mutation begins remain terminal. No default mode changes.

The Rust disposition parser rejects identity/clock mismatches, ambiguous fields,
out-of-interval commits and legacy acknowledgements. Windows MSVC compilation
and the existing 16 native CTests passed after this change; these tests do not
exercise the new live disposition path. The supervised Rust child now exposes
`spawn_with_dispositions` and `submit_disposition`, requiring the distinct ready
marker with no legacy fallback. Writes must finish under the original deadline;
only receipt reading has a separate ceiling of original deadline plus 100 ms,
with a 320-byte line limit and same-host QPC interval validation. Exact expiry
requires the next frame to carry paired keyframes. Partial writes, malformed
receipts and cancellation retire the pipe/child, not restart the decoder.
Both process configurations now expose `disposition_recovery` (default false).
When both opt in, V3 warmup opens a dedicated reliable feedback stream; V2/V3
mismatch closes startup. Each encoded pair waits for its exact 73-byte feedback
record before the sender can enqueue another. Feedback echoes stream/frame,
geometry/config generation, layout revision, original source time and tile count.
Expired-unbound feedback requests paired IDR at the source encoder. There is no
legacy fallback and no physical scanout/input authority in this feedback.

The first V3 WindowsVM trial made three submissions then failed before a native
write. That zero-byte boundary now produces a local expired-unbound result.
The repeat made five submissions and handled one expiry before network
reassembly returned `Late`. Pre-decode expiry handling is being added, but has
not yet passed a sustained native trial. Both trials also reported unconfirmed
HyprCapture stop after its producer had retired; this must not be called clean
source shutdown. Windows task/process cleanup was verified separately.

The MVP now prioritizes an independent capture plugin in
`platform/viewflow-capture`, avoiding the concurrently changing HyprCapture
workspace. Its core and render/control entry now build into `viewflow-capture.so`.
The source config defaults to `capture_provider: "viewflow"`; the explicit
`"hyprcapture"` option retains the old diagnostic provider without fallback.
Start and stop retain the selected namespace for the same owned stream. Nested
load, visual DMA-BUF readback, exact release, stop and unload were exercised.
The Lua C-linkage defect and sender socket mode mismatch were corrected. No
production HyprCapture plugin was changed; further live capture tests must stay
inside an explicitly selected nested compositor.

## Linux capture readiness

The live GPU atlas source wakes on HCGF socket readability by default. Set
`VIEWFLOW_CAPTURE_EVENTS=0` to use the previous periodic-only capture polling
for comparisons. A one-millisecond Tokio timer remains as the fallback for
input, enrollment and feedback housekeeping; its actual wake time is subject
to runtime scheduling.

Each receiver lazily retains one duplicate socket descriptor registered for
readability. The existing nonblocking receive still validates and consumes the
frame. Readiness does not release a GPU allocation, renew timestamps or read a
second frame from a held slot. A failed readiness registration falls back to
periodic polling and retains the session. Cancellation of the readiness wait
does not detach a reader or stop the producer.

The [four-run performance comparison](evidence/performance-20260908/capture-readiness/README.md)
reduced capture-to-socket-read median time from about 1.3 ms to 0.2 ms in the
tested Linux-to-Windows path. Full 4K60 and presentation within two frames
remain unverified.

## Source handshake contract

Before calling `offer_warmed_atlas`, the source opens `AtlasClockClient` on the
same dedicated paired connection. The first bidirectional stream is the `VFCT`
clock stream: each probe contains its four-byte magic and one big-endian source
monotonic `u64`; each reply contains receiver `t1` and `t2` as two big-endian
`u64` values. The stream remains open for subsequent probes while the second
bidirectional stream performs the version-2 warmup negotiation.

The receiver uses one session-local monotonic clock for replies and media
admission. The source must use its capture's native clock when probing.
`calibrate` takes eight bounded samples and selects the lowest-RTT unexpired
sample; `refresh` takes one. Excessive uncertainty is rejected, not normalized
away. Mapping adds the measured receiver-minus-source offset and subtracts the
full measured uncertainty. Each mapping has an expiry and TLS connection
binding; it cannot be used after reconnect or on a different connection.
The source must refresh while startup/media work is ongoing and must map each
original capture timestamp only once. Clock-model/hardware drift and physical
presentation timing remain live acceptance work.

After exact local-plan matching and all three native warmup completions, the
process prints `atlas-peer-ready input_enabled=false physical_present_receipt=false`.
Only then can the source send live atlas manifests/datagrams. A source client
must keep the clock stream responsive; receiving media does not extend the
clock silence deadline. The native presenter may create proxy windows once live
V5 frames arrive. Input is off by default; host-blur policy remains separate.

The native Windows executable additionally accepts `--atlas-pointer-v1` after
`--atlas-disposition-v1` (with the existing byte limit and proxy capacity flags).
This diagnostic mode announces
`atlas-native-ready disposition=v1 input_enabled=true pointer=v1` and emits
`atlas-pointer-v1` mouse motion/button records from each proxy HWND. Records
contain the atlas/layout identity, window ID, placement generation, source
geometry/frame, client coordinates and original OS-event QPC deadline. Each
proxy retains 32 committed identities so a queued OS event maps to the layout
at its timestamp, rather than the newest frame. Focus/capture loss retires the
pointer state; pipe/process loss must release source-side held buttons.
The input-disabled receiver still rejects this distinct ready line. The explicit
`AtlasPresenterChild::spawn_with_pointer_events` API now enables it and owns a
continuous stdout demultiplexer plus bounded pointer queue. It separates video
receipts from idle-time pointer events; queue overflow, malformed events, native
input retirement and consumer closure terminate that reader. Its caller must
supervise pointer EOF and retire input/the child together. Event conversion
preserves the source frame and original deadline; expired button transitions
terminate input rather than silently dropping a release. Output is synchronous diagnostic I/O,
not a production nonblocking event queue. Portable identity/history tests pass;
the new Windows event path still requires a Windows build and physical testing.

Receiver CLI now accepts optional `pointer` configuration with `owner_device`
(receiver) and `source_device`, each a distinct nonzero 32-digit hexadecimal ID.
It requires `disposition_recovery: true`; omitting `pointer` retains video-only
behavior. This mode owns the native producer, shared writer, forwarded control
queue and input task together. Only validated committed native dispositions
publish layouts into the 32-frame input history; expired-unbound frames do not.
An early event waits for that history under its original deadline. Input or
media failure retires the combined attempt.

Source CLI now accepts `pointer: {"devices": {"owner_device": "...",
"source_device": "..."}, "native_socket": "/absolute/private/input.sock"}`
with the same device pair and `disposition_recovery: true`. The native socket
must be inside an existing private owned directory, and the Viewflow Hyprland
plugin must connect to that path (its `VIEWFLOW_HYPRLAND_SOCKET` setting).
Configured capture windows supply the local membership map automatically.
The source owns a single shared writer and native input session, retains 32
committed capture snapshots, and resolves received selections against them.
Initial binding uses the first configured captured window; local idle renewal
requires a newer unchanged capture. Input cancellation is awaited before capture
shutdown. Native input startup must finish within the configured startup timeout.
Both CLI paths are now wired, but the combined real Windows/Hyprland mouse demo
has not yet passed end-to-end acceptance.

For the first runnable input demo, paired peers may operate the configured
captured windows; a separate fine-grained allowlist or approval UI is not a
prerequisite. Window identity and disconnect cleanup remain required.

The source's local stop now signals its loop and awaits the original bounded
handoff and capture cleanup before closing the endpoint; it must not sever a
pending exact feedback receipt itself. Three later two-window trials confirmed
exit code zero after the supervisor requested SIGTERM at 20 seconds. Terminal transport or
cleanup failures remain nonzero exits, including a disconnect after successful
startup. There is no automatic reconnect/retry loop in this entry yet.

## Verification limits

The source now copies per-window input binding metadata before releasing GPU
capture storage. After exact V3 committed feedback, the live capture session
retains one bounded atlas snapshot keyed by window ID. It validates source frame
IDs, per-window geometry epochs, pixel extents and exact membership against the
sent manifest; the atlas frame counter is not a window capture counter.
Local/remote expiry, missing feedback negotiation, retirement and a new submitted
batch do not carry the previous snapshot forward as new evidence. This is native
API disposition evidence only, not physical scanout or permission to inject.
Atlas CLI input remains disabled: local policy, native multi-window selection
and receiver event production still need integration and end-to-end verification.
The native pointer backend owns one seat route, not concurrent per-window
sessions. The source runtime now supports explicit locally authorized switching
on that connection: revoke old event admission, send END, require its exact
confirmation, then send the new BEGIN with increasing command and authorization
generations. Input stays unavailable until BEGIN is confirmed. The switch keeps
the existing button mode and rechecks the new authorization's original expiry
after END; rejection or expiry closes the route. Unix socket tests cover these
transitions. An opt-in source-selected-authorization entry now drives this
switch through the existing single control reader/writer and clock dispatcher;
the original single-window entry still rejects target changes. A mutual-TLS
loopback test with native Unix-socket acknowledgements confirms that neither
END-pending nor BEGIN-pending publishes the new authorization, old-window motion
is rejected without a native command, new-window motion receives an ACK only
after native confirmation, and dropping the selection owner closes the route.
Compositor-level switching and atlas media/input dispatcher wiring remain
unverified; do not start this standalone dispatcher beside the atlas reader.

Shared-control integration now has an explicit single-writer owner. Atlas can
attach it before its first manifest, keeping media frame IDs independent of
connection-wide control sequence numbers. Queueing and QUIC send share an
absolute deadline/cancellation gate; an ambiguous failure retires the connection.
The atlas receive pump can forward parsed pointer authorizations/ACKs and clock
controls through an opt-in bounded queue after its existing replay check, while
retaining sole ownership of the control read. Backpressure retires the media
owner rather than dropping a control. Loopback tests exercise mixed control
sequences, atlas media admission, cancellation, queue overflow and replay across
the media/input boundary.

The source's `serve_selected_on_shared_control` now reuses that writer while
owning inbound input/clock dispatch. The receiver's `serve_forwarded` consumes
the atlas pump's sequenced control queue without accepting streams; it shares
the receiver writer and runs the existing preview admission/ACK state machine.
Authorization and pointer ACK queue sends use the same absolute cancellation
gate as manifests. A mutual-TLS loopback test runs the real atlas pump, both
shared writers, clock probes and input dispatch together: it admits one test
media frame, forwards preview motion, withholds success until the mock native
socket confirms it, and closes input/media tasks when the native sample owner
is dropped. Another test interleaves a manifest with source-selected switching.
These are exercised integration APIs, not enabled CLI input or real compositor
event production/presentation acceptance yet.

`AtlasWindowSelection` is a new request-only control (protobuf tag 34). It binds
the selected window to the exact atlas frame, atlas epoch/config/layout and tile
placement/source-frame/source-epoch, plus an event sequence and deadline. It
contains no native address, lease generation or button permission. The generic
coordinator and non-enabled input routes reject it; it is not silently promoted
to a grant. The source's `serve_atlas_selections` now forwards these requests
from that same sequenced control reader to the capture supervisor, with the
input route's clock snapshot and receipt timestamp. Queue closure/overflow
retires input. Tests verify that receipt alone does not issue a native command;
the existing source-owned authorization update still drives confirmed END/BEGIN.

Receiver `AtlasPreviewInput` consumes the native pointer queue and locally
committed layout history. It selects windows only from matching native events,
waits for the source's matching authorization under the original event deadline,
and forwards ordered events through the existing preview ACK state machine.
Window switches retain connection-wide counters and wait for pending input.
An early initial authorization is retained without selecting its window.
A mutual-TLS test selects two windows with distinct source-frame IDs and mocked
source confirmations, then verifies closure when the native producer disappears.
CLI/capture supervisor wiring and real compositor acceptance remain unfinished.

The source-local `AtlasInputPolicy` validates these requests against its explicit
device/window/native-address allowlist and committed capture snapshots. It maps
the request deadline using the authenticated route's clock estimate, rejects
stale captures and consumes denied request sequences to prevent later replay.
Lease duration is a local policy (at most five seconds), not a remote field;
repeating the same frame does not renew it. A newer frame may renew a still-live
same-window lease near expiry; expired native authority requires a new session.
The capture/input supervisor must revoke grants on capture or connection loss.
Protocol and policy tests cover identity mutations, denial, expiry and replay;
native selection generation and CLI policy ownership still need wiring.

Unit and loopback tests cover configuration, two-frame arithmetic, refresh,
calibration selection, mapping expiry/binding, cancellation and startup gating.
The ignored Windows process test uses explicit native/H.264 fixture paths and
is intentionally warmup-only; it sends neither V5 records nor input events.
It is not a multi-window display or latency acceptance test.

On 2026-09-06 the Windows process test passed in WindowsVM session 1 in 1.57 s:
the real `vf-media-peer` executable completed clock calibration, accepted native
1626x1240 H.264/VFAR warmup, then retired after the fixture disconnected. The
collector verified no owned process remained and removed the temporary task.
Negative, overflowing and undersized native byte limits were also rejected
before GPU initialization. Native CTest passed 16/16, Windows atlas library
tests passed 30 (one separate native test ignored), and Linux workspace tests
passed in default/GPU configurations. Strict library/binary Clippy passed;
this is not a claim that the pre-existing workspace all-target warnings are fixed.

Evidence directory: `/tmp/viewflow-atlas-entry-20260906.K0vIB6/`, including
`calibrated-build.log`, `process-build.log`, `native-process.log`, `cleanup.log`,
`final-default-tests.log` and `final-gpu-tests.log`.
Source archive SHA-256:
`8f543efba6f99da16c7437f5696c3cf4438db7883b4a5f6aeb95ceb9033395a6`.
Receiver EXE SHA-256:
`6487b6ebddee72ea2dabecc30aef98c669d17b8f42f08e3b7c8a78fc05a93db2`.
Native presenter EXE SHA-256:
`044ff1c1ff0a8797c37924d133a529fb71b501e470b8af04a4422749cce53730`.

### Explicit selection rejection (required paired capability)

Both atlas endpoints must advertise and echo `AtlasSession.selection_rejection_version = 1`.
The startup exchange compares the entire offer/acceptance to the local expected plan;
an older peer's missing value (`0`) is rejected before media/input admission. Update
both endpoints together; this capability has no silent legacy fallback.

`AtlasWindowSelectionRejected` (control field 45) preserves the original selection's
entire identity, sequence and deadline. Capture age expiry, event-time expiry and
window withdrawal invalidate source policy. If native input ever became active, the
source confirms an exact-generation native END before sending the rejection; only a
session that never began native input may report released generation zero. Missing or
failed cleanup closes the connection. Cleanup and the rejection notification have a
separate bounded safety transaction, which never extends the rejected input deadline.

No later selection or renewal can overtake a queued rejection. After the rejection,
a new selection must provide a newer source generation and fresh frame/binding;
old button presses are never replayed. Capture expiry at the age limit is rejected
as well as expiry beyond it (for example 41.924882 ms against 33.333333 ms), even when
the selection event itself still has time remaining.


### Cursor event expiry and confirmed rollback

An expired or rejected cursor event remains failed at its original two-refresh
budget. The cursor worker stops forwarding, drains the original bounded ACK
records without replay, and starts a separate bounded cleanup operation. Windows
must acknowledge the next lease generation as revoked after releasing held input;
only then may the source confirm native capture release to the original local
anchor. Successful cleanup preserves the shared video connection and requires a
new physical edge crossing before cursor forwarding resumes. Queued capture tails
from the revoked lease are discarded before their stale timestamps are examined.

Cleanup does not renew an event deadline, turn a late ACK into Applied, retry a
button or key, or infer that a missing ACK meant no injection. Unknown receiver
cleanup or native release still retires the connection. Deterministic tests cover
successful rollback with the connection retained, receiver/native cleanup failure,
and terminal late ACKs; these are not a live physical-input acceptance result.


### Independent ordered cursor receiver

The sole atlas control reader now routes cursor leases, events and revocations
through a separate bounded FIFO before the preview actor. Cursor injection and
ACKs can progress while preview recovery awaits its native fence or writer.
Both actors retain the same authenticated connection and shared control writer;
cursor position, button, key and revoke order is unchanged. No event is coalesced
or retimestamped. Queue exhaustion, actor loss and disabled/foreign-owner input
remain terminal, and leaving the owning scope releases held receiver input.

Fake-backend tests leave the preview queue undrained while cursor Applied,
duplicate-sequence rejection and confirmed revoke ACKs complete in order. They
also cover disabled routes, foreign lease ownership and bounded queue exhaustion.
These tests generate no desktop input and do not claim live latency acceptance.

# Architecture

The newer [security and availability policy](security-and-availability-policy.md)
governs this design: no extra restrictions beyond the user's Windows remote
window and Sunshine/Moonlight baseline. 33 ms/two refresh periods is a
performance target, not a security boundary or a session-exit condition.

This document separates the implemented foundation from the target native
pipeline. It must not be read as evidence that three-platform streaming or the
performance targets have already been achieved.

## Implemented foundation

The Rust workspace currently provides:

- protocol 2.1 protobuf/domain validation for topology, windows, geometry,
  deadline-gated input, clipboard, file drag, per-application audio, HID, and
  clock sync;
- a coordinator for topology, window families, geometry epochs, input/HID
  leases, clipboard/file state, and audio routes;
- mTLS-authenticated QUIC with independently typed reliable control/blob
  streams and bounded media datagrams;
- remote monotonic-clock mapping, media reassembly, P50/P95/P99 counters, and
  a separate exact-blur latency class;
- atomic color/alpha admission, committed-epoch enforcement, latest-frame
  queues, and opaque tile culling;
- a separate-process Deskflow/HID local IPC protocol with generation gates;
- Hyprland 0.56 monitor/window enumeration and a non-blocking compositor
  metadata plugin.

The Hyprland crate and plugin were build/tested on Hyprland 0.56.2. Temporary
live plugin trials have since verified window-scoped motion, clicks, short
same-surface drags and held-button disconnect cleanup against an owned Wayland
probe. The latest 40-gesture and held-disconnect runs and their exact limits are recorded in
[window input status](window-input-integration-status.md). These trials are not
acceptance of the full device/session model below.

## Target session model

Device placement uses monitor resolution, scale and global logical coordinates,
as documented in [display layout](display-layout.md). Adjacency and visible
window intersections are derived from these rectangles. Deskflow edge/percentage
configuration is not the device topology source.

The intended runtime uses one authenticated peer connection per pair of
devices and one `vf-media-peer` process per remote device. Windows are textures
within a stable atlas, not independent streaming sessions. The
platform-independent coordinator owns topology, window families, geometry
epochs, input leases, and transfer offers.

The coordinator now has an explicitly configured stable pixel-layout atlas per
source/destination pair. It retains unrelated reservations across layout changes
and can invalidate content across disconnect without losing those reservations.
This is local layout state, not GPU atlas composition, remote layout publication
or persistent native proxy ownership; see [atlas layout](atlas-layout.md).

The hot path is GPU capture -> atlas -> hardware encode -> QUIC datagrams ->
hardware decode -> GPU proxy composition. Color and alpha are separate planes
with one `frame_id`; a proxy may present them only as an atomic pair. Every
stage before encoding uses latest-frame semantics, so congestion drops work
rather than adding latency. Encoded inter-frame video must still preserve codec
dependencies and use IDR recovery; encoded packets cannot be discarded
arbitrarily.

Deskflow remains a separate process. Viewflow grants it a generation-numbered
input lease and supplies canvas/window coordinates over local IPC. The sidecar
captures or injects input on the lease owner's behalf and cannot make window or
media routing decisions.

Physical-key routes use source-side text composition: the source application
and input method interpret the forwarded keys. A destination texture proxy is
not a local text editor and must not run a competing local composition session.
The Windows atlas native-input path establishes this policy before creating
windows, using a thread-scoped IME disable on its dedicated proxy UI thread.
It does not change system input-language settings or other applications. This
policy does not by itself implement native keyboard forwarding or prove remote
IME candidate/commit behavior; both remain explicit native acceptance gates.
The separate [window keyboard foundation](window-keyboard-input.md) now provides
an unambiguous physical-key wire message and source admission/cleanup state.
An explicitly authorized Linux native direct-application route has bounded Qt
delivery/disconnect-release evidence; it rejects active Wayland IME grabs.
Remote keyboard forwarding is disabled by default and now has explicit source
and receiver opt-in, with bounded two-window Windows-to-Qt key delivery evidence.
A later [Qt/Fcitx source composition trial](window-ime-integration.md) committed
Chinese text in both windows after correcting stationary pointer-focus loss;
earlier focus and clock-budget failures remain recorded. These bounded results
do not close the full source IME gate or active Wayland-grab routing.

## Target native backends

- Windows: WGC + DirectComposition + signed IddCx virtual display.
- macOS: ScreenCaptureKit + Metal/IOSurface + notarized virtual display bridge.
- Hyprland: compositor plugin + DMA-BUF + headless output.

Protected content is rejected explicitly. An exact source-compositor blur
implementation may require a background round trip; destination-native blur
is a separate rendering strategy. Neither strategy is exempt from the user's
two-frame target. Stage timings must identify any extra cost explicitly.

These full native backend combinations are not product-complete. The opt-in
`coded_window_peer` example currently exercises a narrower HyprCapture GPU
window capture -> NVENC -> QUIC -> Windows hardware decode/composition path.
The Viewflow Hyprland plugin exports metadata and authorized window-scoped
pointer injection; the pixel provider is the separate HyprCapture plugin.
Windows source capture and macOS native backends remain incomplete. A standalone
single-window example does not establish the shared per-device atlas/session
runtime described above.

The native coded pipeline now lives in `viewflowd::coded_peer` (Windows, or
Linux with `native-nvenc`); the `coded_window_peer` example is a compatibility
entry point into that library. `run_from_args` defaults to one bounded connection
and offers explicit persistent/reconnect modes. It must run on the calling OS
thread because the GPU encoder is thread-bound. Limited transport reconnect is
implemented; active native-input recovery and atlas ownership remain open. Reusing this
implementation avoids a second native pipeline when the per-device owner is
wired; moving code alone does not close those integration gates.

`NativeMediaPeer` now retains the configured QUIC endpoint across sequential
`run_next` calls. Each attempt rebuilds its clock, codec, presentation and input
state and closes only its own connection. A cancelled attempt fences its owner;
capture-stop failure also prevents reuse. The real-loopback lifecycle test
verifies two source connections from the same bound endpoint before native
capture starts. Receiver retirement now checks child exit, joins all pipe
workers, and awaits the input task; cleanup failure keeps the owner fenced.
A Windows loopback test reuses the endpoint after two checked presenter-start
failures, without GPU output. Broader reconnect recovery, persistent proxy
windows, atlas orchestration and the daemon entry-point wiring are still open.

The separate [`vf-media-peer` atlas entry](atlas-peer.md) now has a Linux source
and Windows receiver, owning clock service, native warmup and admitted-frame
forwarding from explicit local configuration. Its independent Viewflow capture
plugin was exercised in a nested Hyprland; three bounded two-window runs reached
Windows native submission and clean source stop, with distinct fixture pixels
visually checked. V3 adds exact expired-unbound feedback without claiming
physical scanout. Dynamic window discovery/layout, persistent reconnect
ownership, full physical presentation/latency and atlas input routing remain open.

`run_next_until_shutdown` accepts a caller-owned stop future. On requested
shutdown it permanently closes the retained endpoint, then awaits the original
attempt so checked input/capture/presenter retirement can finish. Its report
keeps both the stop flag and the original result, including cleanup failure;
requesting shutdown is not evidence that retirement succeeded. Dropping the
method's future is still cancellation and fences the owner. Tests cover a
pending source handshake, idle receiver accept, and a delayed failing cleanup
fixture. They do not yet prove shutdown of a live GPU/input session. The process
entry point now registers SIGINT/SIGTERM on Linux and Ctrl-C/Ctrl-Break on
Windows before binding the peer, then routes those events through this API.
It retains the attempt result, so a locally closed transport can still produce
a nonzero exit status after a requested stop. Linux process smoke tests verify
both signals during a pending loopback handshake. A Windows isolated-console
smoke test also verifies Ctrl-C/Ctrl-Break during idle receiver accept. Neither
test proves live GPU cleanup. Forced process termination does not exercise this
graceful path.

A live GPU trial now verifies source SIGTERM after a confirmed held button:
the source probe observed cleanup release, and receiver/presenter retired
without harness termination. This is one source-stop case, not reconnect or
general live-shutdown coverage. The plugin also performs the same bounded input
drain before render reconciliation; a subsequent trace proves that path ran,
but the long gesture trial still failed on a late native up acknowledgement.
No freshness/authorization deadline was relaxed to obtain those results.

Input-task retirement now retains the task's actual result instead of dropping
it behind a media connection-close error. Normal task errors retain a distinct
input-failure marker and their underlying cause; panic, unexpected cancellation
or exceeding the 250 ms cleanup join bound is a cleanup failure that fences the
owner. This bound is not an extension of any input-event deadline. Cancellation
of source shutdown retains the task handle in its owner for abort-on-drop.
The explicit `--reconnect` policy retries pre-native transport-admission
timeouts and direct QUIC reset/idle-timeout errors after retirement, retaining
one endpoint while rebuilding connection-local state. Backoff doubles from
250 ms to five seconds and is interruptible by shutdown. Cancellation during
backoff fences the owner. Combined media/input failures preserve both typed
causes and permit retry only if both are classified transport failures. Native
input errors, cleanup errors, application closes, TLS/protocol errors and unclassified errors
remain terminal. Broader active-input recovery and persistent atlas/proxy
ownership remain incomplete.

A typed clock-probe liveness timeout can account for the input dispatcher's
accompanying local media close after checked retirement. This does not make
arbitrary local closes retryable. Source native commands and preview input
confirmations expose an unconfirmed-operation flag; a liveness timeout while
that flag is set is terminal, so it cannot conceal an input-confirmation failure
that becomes ready in the same scheduling turn. This policy has unit/socket
coverage but still requires live GPU reconnection acceptance.

The explicit `--persistent` mode now removes the total live-session cap while
retaining a bounded startup confirmation and per-operation/capture-stall waits
from `--timeout-ms`. Both peers must opt in for a long-lived connection. Each
retained frame keeps its original freshness and presentation deadlines; this
mode does not make late frames or input valid. The default remains a bounded
diagnostic, and persistent mode rejects one-shot warmup-alpha export. It is not
itself an automatic retry policy; `--reconnect` is a separate opt-in requiring
persistent mode. A first live persistent trial exceeded its five-
second startup/operation budget but stopped on an input-context rejection;
see the input-status evidence rather than treating it as sustained acceptance.

The native media regression tests moved with the implementation. Run them with
`cargo test -p viewflowd --lib coded_peer:: --features native-gpu-nvenc` on Linux,
or `cargo test -p viewflowd --lib coded_peer::` on Windows. Testing only the
compatibility example now runs no media unit tests.

## Geometry and resize ordering

Resize follows the useful ordering learned from FreeRDP RAIL rather than
assuming a continuous resize PDU: begin ownership, accept coalesced compositor
geometry updates, then commit the authoritative final geometry. New-size media
is tagged with the new epoch but cannot be presented before `End(epoch)`.
`FrameQueue` rejects both stale and future epochs, so only content matching the
committed geometry is presentable.

## Performance contract

- Standard media: every retained source-submit to presentation sample must be
  no greater than two target refresh periods; this is 33.3 ms at 60 Hz. P99 is
  reported as a diagnostic, not used to relax this absolute limit.
- Blur: report separate stage timings, but include its cost in end-to-end
  two-frame validation. A slower exact-blur mode cannot be counted as meeting
  the target without an explicit user-approved change of requirements.
- 6K60: explicit optimization point, never a negotiated hard maximum.
- Resolution, refresh, codec, chroma, alpha, and transport limits remain
  capability-negotiated and resource-bounded.

The coded example wires deadline admission and stage timing into a native
cross-host pipeline. Bounded trials are evidence only for their recorded size,
transform, workload and configuration; they do not prove sustained operation,
every retained standard/blur sample at every target, or the 6K60 optimization
point. See [remaining integration gates](integration-acceptance-gates.md).

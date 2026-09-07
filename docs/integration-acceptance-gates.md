# Remaining integration acceptance gates

This checklist preserves the target in `architecture.md` and `README.md`; it
does not redefine the product as the current single-window diagnostic example.
Audit updated: 2026-09-06. Source status is distinguished from native acceptance.

| Target | Current evidence | Evidence still required |
| --- | --- | --- |
| Window capture, alpha, composition | Bounded HyprCapture/NVENC/Windows coded trials; upright/full preview checked | Sustained current-build runs, target transforms/resolutions, alpha/blur visual and timing gates |
| Window-scoped input | Bounded click/drag, held-wheel, two-window scan-code and Qt/Fcitx Chinese-composition trials; earlier failures retained | Repeated current-build interaction, native timeout/focus failures, reconnect, physical keyboard, full source IME and outside-window behavior |
| Shared logical desktop session | Coordinator/per-device media owner and bounded two-window Linux-to-Windows atlas trials | Sustained product session, topology and complete window-family behavior without independent ad hoc sessions |
| Resize and geometry ownership | Capture/atlas trials 87–88; native rebind/terminal guard trials 89–91; authenticated shared-network test; Windows-to-Qt unheld motion across one resize in trial 92 | Sustained/repeated resize/move/transform, held-input cancellation/drag and physical takeover/lock, with event-time mapping and no cross-epoch input |
| Clipboard and file drag | Additive clipboard transfer protocol, seven authenticated QUIC runtime tests, consent-gated Linux command adapter with eight unit tests; reliable file-transfer handlers | Clipboard connection multiplexing/product-session wiring and real OS delivery; cross-surface/application file drag/drop with destination/result verification |
| Per-application audio | Protocol/coordinator routes, family-bound source runtime, private Linux sink routing and bounded PCM capture adapter; seven capture tests including owned-child cleanup | Real native PCM capture, transport, playback, observed window-family binding and synchronization proof |
| Platform coverage | Narrow Hyprland-source/Windows-preview path; Windows window-only WGC static library built on Windows with two passing CTests | Real Windows source window/pixel acceptance and session integration; full macOS native backends, virtual-display components and platform-specific authorization/deployment gates |
| Two-refresh-period media target | Deadline-gated coded pipeline and stage statistics | Sustained retained-frame boundary validation, explicit blur accounting and 6K60 optimization evidence; no percentile substitution |

The latest concrete input evidence and failures are in
`window-input-integration-status.md`. A successful short run closes only that
bounded case. It does not close a row above or prove the full goal complete.

Parallel implementation checkpoint: clipboard transfer controls require a dedicated
exclusive control-reader lease and explicit local consent at both endpoints. The
generic coordinator rejects them instead of treating a wire correlation token as
OS consent. No live clipboard was read or written for these tests. Audio routing
tests likewise do not touch the user's audio server. Windows WGC compile/CTest
does not call `WindowCapture::start` on a real HWND. See
`linux-clipboard-adapter.md`, `application-audio-runtime.md`, and
`../platform/windows-window-capture/README.md` for the concrete boundaries.
The clipboard lease registry excludes only other clipboard lease holders; it
cannot detect the normal daemon's independent reliable-control reader. Do not
attach this lane to an already managed connection. A shared dispatcher/inbox is
still required before product-session enablement.
The two Linux-only `clipboard_linux_adapter` integration tests now pass the
authenticated receiver's exact verified offer/accept/payload to the actual Linux
adapter with a fake command runner. Successful fake ownership precedes the
Completed receipt; denied native consent produces Failed with zero writes. This
closes the callback/adapter data-binding test gap, not live clipboard delivery.

Latest keyboard/IME follow-up: [trials 65–73](window-ime-integration.md) record
real source-side Fcitx Chinese commits in both windows after correcting stationary
pointer loss, plus earlier focus failures and a confirmed Windows clock-budget
rejection. No deadline was relaxed. These results supersede older statements below that no
native keyboard/wheel forwarding exists, but do not close their acceptance gates.

Atlas follow-up: [native input evidence](evidence/atlas-input-expiry-20260906.md)
records current-build trials 49–51. The dedicated Windows proxy UI thread now
uses source-side composition policy, avoiding local IME activation work. Normal
launchers passed an unheld external-focus retirement and one 12-second two-app
drag with exact coordinates, balanced buttons, and no input discards. An earlier
repeat did discard four motions, so sustained reliability remains open. Native
keyboard/wheel forwarding routes now have bounded implementation/evidence, and
source IME has bounded Fcitx commit evidence. Full native OS/application
acceptance, active-grab behavior and sustained IME/input reliability remain open
gates; pointer success must not stand in for them.

[Window wheel work](window-wheel-input.md) now includes a distinct validated
wire payload, cross-kind ACK rejection, ordered preview forwarding and native
record parsing. Real Windows OS capture and application wheel
acceptance remain pending.

The Hyprland native wheel session and explicit local grant/command are now
implemented and build/unit-tested. Source dispatch is connected under explicit
`pointer.wheel` authority (default false), with real socket/QUIC regression
coverage. The preview component has 19 passing tests and distinct wheel receipt
counts, and is connected to the atlas receiver's explicit `pointer.wheel` policy
and strict native wheel readiness contract. Native Windows capture is implemented
and its Release build plus 18 CTests pass; live OS/application acceptance remains
pending. The linked wheel evidence
also records one intermittent GPU-socket test failure before successful reruns.

Wheel trial 56 now provides bounded live evidence: eight fractional wheel events
from Windows OS input reached two Qt source windows, in order at unchanged points.
Three motion timing discards prevent a full mixed-input pass. A held-wheel record
was rejected in trial 53 and its exact failing field still needs diagnosis;
outside-window, reconnect and sustained acceptance remain open. See the linked
wheel evidence for all failed and successful trial boundaries.

Follow-up trials 57–59 identified and fixed held-wheel rejection: Windows mouse
button bits are now matched against admitted native button state instead of
requiring zero. Trial 59 passed a 12-second two-window run with 40 exact motions,
eight held wheel events, balanced buttons and no input discards. Trial 58 still
failed a fresh-capture renewal check and remains recorded; sustained and negative
path acceptance are not complete.

The source renewal policy now defers an unchanged committed frame within the
existing lease instead of treating it as a terminal error. A red/green regression
plus original-expiry and binding-change tests passed; no lease deadline or capture
age bound was increased. Live verification of this follow-up remains pending,
and the old generic trial-58 error does not identify its exact subcondition.

Outside-wheel trial 63 verified that a real OS wheel at a point outside the
foreground proxy went to the owned local witness window and not either source Qt
window. This is current-OS routing/no-leakage evidence; it did not exercise the
proxy's internal outside-coordinate rejection/retirement branch. That distinction
and the failed helper trials are recorded in the wheel evidence.

Reconnect boundary audit: the persistent CLI client retries authenticated QUIC
connections without restarting its endpoint. The real-loopback regression
`persistent_client_reconnects_and_restarts_control_sequence` verifies two
authentications from the same bound client address and a fresh sequence-1 clock
probe after the peer closes the first connection. This is transport proof only.
Both ordinary CLI peer handlers currently install `None` for the window source
and preview routes. The source-authorized window dispatch entry points exist,
but the coded example owns their lifetime separately. Native window recovery
therefore still requires wiring those media/input owners into the persistent
per-device session; merely restarting the coded example is not acceptance.

Next implementation/verification order: retain the current event-time history
and exact-receipt invariants; run longer/repeated input against the dedicated
probe, investigate any first failure without relaxing deadlines, then exercise
outside-window/resize and the remaining native input operations. Product-session
wiring and other rows remain explicit work, not assumed consequences of the
diagnostic example.

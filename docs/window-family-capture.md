# Window-family capture geometry

The standalone capture plugin now owns a monotonic geometry epoch per stream.
It compares the outward-rounded logical/pixel bounds and the encoded main-surface
input sidecar before rendering. These include scale-only pixel changes and main
content movement inside unchanged outer bounds. Invalid geometry or epoch overflow
fails closed. The sender's existing exact sequence/epoch HCGR release gate still
prevents recycling a framebuffer with an outstanding consumer.

This removes capture's previous stop-on-geometry-change behavior. It does not
enlarge native input authority: the input target still admits only negotiated
main-surface coordinates. The subsequent atlas integration below updates source
placements within the existing canvas; canvas expansion and input reauthorization
remain separate work.

## Native trial 87

An explicitly isolated Hyprland 0.56.2 instance loaded capture plugin SHA-256
`5feb05271cdb4f4eebcffee5fac3ccce93509097cc4dd7f772e72c4ceed5e734`.
The owned Qt geometry probe resized its main surface, showed an XDG tooltip
extending beyond it, hid the tooltip, and restored the original size. No
keyboard/mouse injection or main-desktop configuration changes were performed.
The newly loaded binary also contains the earlier popup visible-region fix;
this run does not independently validate its pixel effect.

The [frame trace](evidence/window-family-capture-trial87-frames.jsonl) records
1,025 allocations and these transitions:

| Phase | Epoch | Capture pixels |
| --- | --- | --- |
| Initial | 1 | 404 × 304 |
| Main resized | 2 | 504 × 354 |
| Popup extends beyond main | 3 | 713 × 467 |
| Popup hidden | 4 | 504 × 354 |
| Main restored | 5 | 404 × 304 |

The [application phase log](evidence/window-family-capture-trial87-probe.log)
and capture sequence show uninterrupted production across every transition.
The verifier checked exact producer PID/UID, message/FD shape, increasing frame
sequence, epoch changes matching the geometry/sidecar fingerprint, and signaled
producer fences before exact allocation release. It did **not** import/read the
image or measure encoding, Windows rendering or physical presentation. The
capture stream was explicitly stopped and all owned children reaped; the
isolated compositor then had no clients.

Six capture CTests and the existing Qt IME witness CTest passed. The new pure
geometry-epoch test covers stable observations, popup expansion/retraction,
pixel-only scale changes, sidecar-only changes, invalid samples and overflow.
The Rust atlas regression additionally requires a new placement for an epoch
change even at unchanged dimensions, and rejects pixel growth under an old
allocation. These checks do not substitute for the pending live renegotiation.
All 13 GPU-compatible encoder tests passed with `--features native-gpu-nvenc`;
running the filter without that feature selects zero tests and is not evidence.

The reusable witness is `platform/linux-pointer-probe/family_geometry_probe.cpp`;
`tools/verify_capture_geometry.py --help` documents its guarded metadata verifier.

## Atlas trial 88: dynamic layout reaches Windows

`StableAtlas::from_snapshot` validates negotiated lineage, bounds, alignment and
non-overlap before reconstructing free space, preserving all existing placements
and generations. `GpuAtlasDevice` now stages the captured dimensions/epochs in a
candidate allocator each batch. Changed windows receive new placement generations;
unrelated windows retain their reservations. The existing encoder requires exact
capture/placement matching, forces fresh color/alpha keyframes for layout changes,
and publishes the manifest atomically with those planes. Insufficient space or
invalid lineage retires this owner; this is not automatic canvas enlargement.

Eight allocator tests passed, including malformed snapshots, transactional
failure, preserved unrelated placements and 2,000 randomized reconstruction
checks. All 13 GPU-compatible encoder tests passed with the native GPU feature.
The Linux source Release binary was
`02ac1ccbb3b8fa91099024f18789cda4a4301200e5bab9a36e550347c067c4c3`.
The capture plugin was unchanged from trial 87 and the Windows receiver/presenter
were unchanged from trial 86. Trial 88 explicitly disabled remote input so this
result cannot be mistaken for successful geometry reauthorization.

Using the same five-phase source probe and a pre-negotiated 1600×608 canvas,
the [source](evidence/window-family-atlas-trial88-source.log) reached planned
stop exit 0 after 1,548 enqueued pairs and two clean expired media frames.
The [receiver](evidence/window-family-atlas-trial88-windows.log) reported 1,548
native visual submissions. Its clock worker ended after source shutdown; this
does not establish a sustained physical-presentation latency bound.

All five Windows client screenshots were inspected:
[initial](evidence/window-family-atlas-trial88-1.png),
[resized](evidence/window-family-atlas-trial88-2.png),
[expanded popup](evidence/window-family-atlas-trial88-3.png),
[popup hidden](evidence/window-family-atlas-trial88-4.png), and
[restored](evidence/window-family-atlas-trial88-5.png).
Their dimensions are 404×304, 504×354, 713×467, 504×354 and 404×304 respectively.
The blue main panel and magenta popup remain at their natural sizes; the popup
is visible beyond the main panel, and the proxy shrinks again on removal.
Transparent family gaps reveal the Windows desktop behind the proxy; these are
screen captures, not isolated source-image exports.

The [watch helper log](evidence/window-family-atlas-trial88-watch.log) contains a
client-rectangle read error after the five files had been produced. It is not a
clean helper-exit result, and its console stage output was not retained there.
The screenshots and independent source/receiver counts establish the bounded
media result without relying on that log as a successful verifier. The source
and probe were reaped; Windows cleanup confirmed Ready/no-child state before
unregistering the test task, and the isolated compositor had no remaining clients.

## Input geometry handoff primitive

The source input dispatcher can now hand off an explicit local authorization to
new geometry of the **same exact native target**, using its existing confirmed
END → BEGIN protocol. This is not in-place renewal: owner/target devices,
window address, main-surface address and PID must remain equal; geometry epoch,
presented frame and authorization generation must advance. Permission modes and
the native connection's command sequence are preserved. Input cannot resume
before the old END and new BEGIN acknowledgements, and revoked sessions remain
irreversible.

The new native-socket regression checks identity substitutions, stale generation,
the END/BEGIN barrier, new extent, capability preservation and rejection of old
generation/epoch/frame packets. A separate authenticated QUIC dispatcher test
verifies that the new authorization is not announced before the native handshake,
that old-geometry input receives rejection without native forwarding, and that a
new-geometry event requires its native receipt. All 36 `window_input_runtime`
tests passed. The native peer in these tests is a controlled socket witness;
this is not a compositor/application resize acceptance test.

Still needed: handle a main-surface resize which has **already** caused native
revocation. That recovery must not revive local-input takeover, session-lock,
expiry or destroyed-target revocations. The compositor's current irreversible
revocation guard was not weakened. This handoff primitive alone does not make
live resize input work, nor does it grant input beyond the main surface.

The next integration step now connects the selection side: only an ordered native
event matching a committed atlas frame may select a new geometry. The receiver
keeps a selected-epoch floor, clears both pointer and keyboard grant histories on
advance, requires a higher authorization generation, and filters late grants for
other epochs before they reach admission. Regressing the local selection or
reusing the previous generation is rejected. Source policy accepts a higher
same-window epoch only with a newer captured frame, retains the exact native
binding checks, and assigns a fresh generation for the END/BEGIN handoff.

The local-geometry test verifies both authority histories, late pointer/keyboard
grants, generation reuse, epoch rollback and separate keyboard reauthorization.
The source capture-binding test verifies new-generation issuance and rejection
of an old-epoch selection after it. Seven atlas selection transport tests passed.
These selection changes have not been deployed to the Windows test receiver.
Native resize revocation and idle old-geometry maintenance remain terminal;
full live input recovery still requires the suspension/recovery work above.

### Resize revocation observation groundwork

Native target listeners now allow an observed `Resized` reason to be promoted
to a later terminal reason (local motion/button/axis/key, lock, unmap, destruction
or other safety failure) while that target remains alive. Repeated resize events
and empty observations cannot clear revocation; a terminal reason can never be
downgraded to resize. Session cleanup records its actual retirement reason rather
than replacing resize with generic cancellation, and the ended session reports
any terminal promotion observed before controller retirement. A missing surface
in a commit callback is classified as destruction, not resize.

The lifecycle regression exhausts all 256 pairs of defined reason codes, tests
resize → terminal → resize sequences, and checks that higher-generation BEGIN
still cannot bypass revoked connection authority. The native plugin rebuilt and
all eight CTests passed. This change has **not** been loaded into a compositor.
Those tests establish reason retention only, not resize input recovery or live
native event ordering.

### Native resize suspension and rebind

The controller now retains an ended, successfully cleaned-up resize-only session
as an inert guard. Its exact target listeners continue observing takeover and
target destruction; polling and every command recheck the original lease deadline
and current lock/seat/identity conditions. Ordinary BEGIN remains rejected while
suspended. New local opcode 61 (`WINDOW_INPUT_REBIND_RESIZED`) requires a strictly
higher generation and exact window/surface/PID/current extent; it creates a new
session with the old capabilities, overlapping target listener lifetimes. END,
terminal guard observations, expiry, failed rebind and disconnect remove recovery
authority. Resize notification is sent only after successful cleanup and guard
validation; expired or failed-cleanup resize sessions report a terminal reason.

Native authority regressions cover paused renewal, consumed denied generations,
explicit rebind, no-guard reconnect, and terminal revocation during suspension.
The parser checks the full binding payload for the new opcode. Rust has a matching
request codec with exact result, layout and invalid-field tests. Eight native
CTests and nine Rust pointer codec/socket tests passed. Neither the source daemon
recovery state machine nor a live compositor test is covered by these results.
No new plugin was loaded in that step.

### Source resize recovery state

The selected-authorization source route now opts into `ResizeSuspended` only for
an exact-generation native resize notification received in Ready state. Pending
native work, other revocation reasons and unselected routes remain terminal.
Suspension revokes the old pointer/keyboard grants without dropping the native
connection, preserves the old expiry, and rejects incoming input without claiming
delivery. A newer local selection must advance frame, epoch and generation while
preserving both devices and the exact window/surface/PID. It sends opcode 61,
preserves permission modes and command sequencing, and keeps announcements gated
on the native Begun receipt. The recovery-unconfirmed fence stays set during
suspension: older plugins used the same resize reason code without the newer
cleanup guarantee. Maintenance polls native revocations before applying
selection updates, and ignores the unchanged old authorization while paused.

Capture maintenance now waits on a fresh higher epoch instead of implicitly
renewing it; repeated maintenance does not extend the old deadline. A matching
regression checks expiry at that original deadline. Thirty-eight source input
tests passed, including controlled native-socket resize recovery, wrong identity,
stale geometry, pending BEGIN, missing opt-in, wrong generation, terminal takeover,
lock/unmap/expiry and repeated-revocation cases. The dedicated resize cases use a
socket witness, **not** a live compositor or Windows receiver. Real resize input,
the shared-network resize announcement barrier, and resize racing an in-flight
input command still require integration verification. No release binary or plugin
was deployed by this source-state change.

### Shared-network resize barrier regression

The authenticated QUIC dispatcher now has a dedicated resize case using the real
shared writer and a controlled native socket peer. After native resize it keeps
the route alive without publishing another authorization or issuing native
commands. An old-geometry motion receives Rejected without native forwarding.
A new explicit local selection then emits only opcode 61 (no END/ordinary BEGIN),
and no authorization is published while its native receipt is withheld. Begun
releases the new grant; old-geometry input remains rejected and new-geometry input
requires its own exact native receipt. Dropping the authorization owner closes
the native route. All 39 source input tests passed with this regression included.

This closes the controlled shared-network resize announcement-barrier check
listed above. It does not close the live compositor, Windows presentation/input,
resize-during-pending-command, or sustained-interaction gates.

## Trials 89–91: real native resize rebind and terminal guards

An owned Qt window ran in the existing isolated Hyprland 0.56.2 compositor, with
no pre-existing clients. Only that compositor's input plugin was replaced with
the resize-guard build (SHA-256
`84512d3ac18b564adae683224552309207b534923fc1a88e8a3e51534121c613`). The main desktop
was not changed. The verifier checks both native/capture SO_PEERCRED identities,
uses the same captured HCGI window/surface/PID/extent, and waits for producer
fences before releasing GPU allocations. It does not import or inspect pixels.

- [Trial 89 native receipts](evidence/window-native-resize-trial89.jsonl): motion-only
  BEGIN generation 1 and old-size motion succeeded; the window resized from
  400×300 to 500×350 and reported Resized. Ordinary BEGIN generation 2 was rejected.
  Explicit rebind generation 3 succeeded, followed by new-size motion and END.
  The [Qt application log](evidence/window-native-resize-trial89-probe.log) records
  exact old/new local coordinates `(100,50)` and `(150,60)`.
- [Trial 90](evidence/window-native-resize-trial90.jsonl): after resize the original
  native lease expired. Rebind generation 3 and ordinary BEGIN generation 4 were
  both rejected. The [probe log](evidence/window-native-resize-trial90-probe.log)
  contains the initial motion only.
- [Trial 91](evidence/window-native-resize-trial91.jsonl): the owned Qt process was
  terminated during resize suspension. Native target-loss notification followed;
  rebind generation 3 and ordinary BEGIN generation 4 were both rejected. The
  [probe log](evidence/window-native-resize-trial91-probe.log) contains no recovered
  motion.

All three verifier processes exited successfully, capture streams were stopped,
owned probes reaped, and input/capture sockets removed. The isolated compositor
again reported no clients and no config errors. The geometry probe build and its
existing Qt CTest passed; the new verifier passed Python compilation.

Reproduce only on an explicitly isolated owned compositor with
`tools/verify_native_resize.py`; `--terminal expiry` and `--terminal unmap` select
the negative cases. These are application-observed native motion/guard results,
not Windows resize interaction, held-button/key cancellation, physical local
takeover/lock testing, or a latency bound. The source daemon release was not
rebuilt/deployed for these trials; the verifier drove trusted local IPC directly.

## Trial 92: Windows OS motion across a source resize

The current Linux source Release (`aea6395656f982c37f5fe91b252557c8871cb754be00f24c32f76fd7ea25b14d`)
and rebuilt Windows receiver (`B3F08291184194B49BD15A8416AEEFE92BF5B7ECDF62C2485BDCAEA75A663FE4`)
ran the selected-input atlas path with the trial-89 native plugin. The Windows
receiver build updated the three geometry-selection/preview source files; the
native Windows presenter was unchanged. One owned Qt source window resized
itself; a bounded helper checked the exact receiver child PID, proxy class/title,
foreground ownership, client geometry and cursor ownership before each OS motion.

The [Windows helper record](evidence/window-resize-trial92-events.log) contains
three moves at client size 404×304 and three at 504×354. Its points
`(102,52), (103,53), (102,52)` and `(152,62), (153,63), (152,62)` map through the
two-pixel capture inset to the six exact coordinates in the
[Qt application log](evidence/window-resize-trial92-probe.log):
`(100,50), (101,51), (100,50)` and `(150,60), (151,61), (150,60)`.
This is real Windows OS input, shared transport, native recovery and application
delivery evidence, rather than a synthetic native-socket witness.

The [source log](evidence/window-resize-trial92-source.log) reports 8 local
authorizations, zero input timing/capture discards, 774 enqueued color/alpha pairs
and 2 expired-clean media dispositions. The
[receiver log](evidence/window-resize-trial92-windows.log) reports 774 native
visual submissions, not physical display receipts, and retirement after the
source's planned stop. The source exited 0; its children were reaped. Windows
cleanup verified the owned task Ready with no owned child processes before
unregistering it; the isolated compositor had no clients and its input socket
was absent. The main desktop configuration and plugins were not modified.

This bounded case closes ordinary unheld motion recovery across one main-window
resize. It does not prove held-button/key cancellation, drag continuity, physical
takeover/lock, repeated transforms/resizes, window-family outside-main input,
product-session reconnect, or sustained media latency. No screenshots were
captured in this trial; client-size and input-coordinate evidence is independent
of the earlier trial-88 visual captures.

## Trials 93–95: application-observed held-input cleanup

The isolated native verifier now supports `--held button` and `--held key`.
The owned Qt probe records button transitions and physical key scan/repeat state;
it does not record text or observe input in other windows.

- [Trial 93](evidence/window-held-resize-trial93.jsonl) began with button authority,
  sent one left-button down, and deliberately sent no up. Resize caused exactly
  one application-observed up before the new-size motion. Ordinary BEGIN was
  rejected, explicit rebind succeeded, and END completed. The
  [application log](evidence/window-held-resize-trial93-probe.log) retains the order.
- [Trial 94](evidence/window-held-resize-trial94.jsonl) used explicit keyboard
  authority and one HID A down. Native operations completed, but the verifier
  failed its scan assertion: it incorrectly expected raw evdev 30 instead of
  Qt's reported XKB scan 38. Its [application log](evidence/window-held-resize-trial94-probe.log)
  is retained; this run is not labeled a successful verifier result.
- [Trial 95](evidence/window-held-resize-trial95.jsonl), after correcting that
  assertion, passed. Its [application log](evidence/window-held-resize-trial95-probe.log)
  contains exactly one non-autorepeat down/up pair for scan 38. Qt generated
  autorepeat pairs while held; none followed the terminal non-repeat release.
  The release preceded new-size motion after explicit rebind.

Trials 93 and 95 exited 0; trial 94 exited 1 with the assertion failure. All
three cleaned their streams, sockets and owned processes, and the isolated
compositor returned to no clients. The updated Qt probe built and its existing
CTest passed; the verifier passed Python compilation. Production source/receiver
binaries and plugins were not changed in these trials.

These prove native cleanup at the source application, not Windows held-input
recovery. The Windows `AtlasPointerState::commit` currently retires the input
state if a key is held across a tile geometry/placement change. That fail-closed
boundary needs an explicit cancellation-and-physical-release drain protocol;
simply clearing its held state or enabling it again would lose evidence about
which releases belong to the old source grant. End-to-end held-key/button and
drag recovery therefore remain open.

### Windows cancelled-key drain

Geometry cancellation now preserves the old admitted-key ledger and separately
tracks the physically held keys that must drain. The native window absorbs their
valid repeats and final releases without emitting remote input or running local
text/system-key handling. Invalid scan/repeat sequences, unexpected keys,
modifier mismatches and lost foreground/focus fail closed. A repeated geometry
commit does not repopulate an already drained physical ledger.

Physical drain is explicitly **not** source cleanup confirmation: the original
admitted keys remain recorded, and neither an up event nor another visual commit
re-enables input. Regression tests check this distinction, modifier release
ordering, invalid transitions and duplicate releases. This is the cancellation
half only. The native presenter still needs a bound source-confirmation control
path before it can resume; end-to-end held-input recovery is not yet implemented.
The two portable state tests passed with warnings treated as errors; the Windows
Release build and all 21 native CTests passed. The rebuilt native executable is
`68FA3A55D50EFA550C7302DE794CBC804DE4EF1D51439010D37F7D66CB0A0C4E`.
No interactive Windows trial was run for this change; tests of state transitions
and a compiled window handler do not prove real OS message ordering.

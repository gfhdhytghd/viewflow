# Atlas input startup and manifest expiry — 2026-09-06

Partial progress only; this is not cross-host pointer or full-plan acceptance.

Three bounded two-window trials used the isolated nested Hyprland and Windows
staging prepared under `/tmp/viewflow-input-20260906.J4vBWv/` and
`C:\Users\wilf\AppData\Local\Temp\viewflow-input-20260906-J4vBWv`.
The nested compositor was PID 4039456; main compositor PID 3386992 remained
untouched. Input was enabled in the receiver configuration, but no mouse
events were injected. All three source runs exited early, before their planned
12-second stop. The owned Windows scheduled task and preview processes were
confirmed removed/absent after the third run. The nested compositor was retained
for follow-up; test Qt clients had exited.

The first two receiver errors reported input producer/owner closure. Preserving
the pending media cleanup result when input ends exposed the primary third-run
error: `atlas admission rejected: Expired`. It occurred after three native visual
submissions. Receiver logs are `receiver-{first,second,third}.log` in the Linux
temporary evidence directory; these are failures, not successful input delivery.

The receiver now permits V3 disposition sessions to discard a fully validated
manifest that is already expired before decode. Its lineage advances to prevent
replay, but it never becomes pending admissible pixels. The existing
`ExpiredUnbound` response requires a subsequent keyframe. Stream, layout and
source-lineage violations remain errors, and V2 retains fatal expiry behavior.
The two-frame freshness budget and source timestamps are unchanged.

Targeted regressions cover expired-manifest replay/layout/source checks and an
actual QUIC exchange that skips an expired frame, retains the input channel,
then admits and acknowledges a fresh keyframe. Linux default atlas tests passed
64/64; Linux GPU-feature atlas tests passed 74 with two hardware tests ignored.
Strict `native-gpu-nvenc` library Clippy passed. Windows rebuilt the real
receiver executable and passed 54 atlas tests; one interactive hardware test
remains explicitly ignored. Windows builds retain existing dead-code warnings.

## Follow-up runtime failures

Fourth trial, after the manifest fix: 27 native visual submissions, then
`early atlas datagram outside clock bounds`; source exited before planned stop.
That old combined error cannot distinguish an expired from a future timestamp.
The early-datagram path now separates those conditions: future timestamps still
fail; V3 expired bytes are discarded without feedback until the reliable manifest
can be validated. No early datagram alone produces an expiry receipt. The QUIC
regression now checks this discard and continued ownership, plus rejection of a
future timestamp. Linux GPU atlas tests again passed 74 with two ignored;
Windows rebuild and atlas tests passed 54 with one ignored. Strict Linux GPU
library Clippy passed after removing a redundant older-frame check.

Fifth trial with that early-expiry handling: one native visual submission,
then the source terminated with `atlas input capture expired`. Receiver logs
confirmed peer closure (`atlas source input stopped`), not a receiver admission
failure. Investigation next targets stale capture during source authorization;
the rejection must not be weakened to allow stale input. No mouse injection
occurred in either trial. Logs use `source-fourth.log`, `receiver-fourth.log`,
`source-fifth.log`, `receiver-fifth.log` in the same temporary evidence directory.

These runs do not establish native mouse motion/click delivery or sustained
streaming. Earlier preparation hashes describe the earlier build, not these
binaries. The fifth Windows build precedes only the behavior-neutral removal
of the redundant older-frame check from local source.

## Source bootstrap fix and sixth trial

`AtlasInputPolicy::maintain_capture` now returns no authorization for stale
capture evidence instead of a fatal error. The source retains its native
connection while waiting within the original startup deadline. Renewal similarly
cannot extend a lease from stale evidence; expired sessions, future captures,
invalid bounds, changed bindings and stale remote selections still fail.
Regressions verify that skipped stale evidence consumes no generation, fresh
evidence can authorize/renew afterward, and the original lease expiration remains
terminal. Strict GPU library Clippy and the real GPU source CLI build passed.
GPU atlas tests passed 74 (two hardware tests ignored); window-input runtime
tests passed 21/21.

Sixth trial used newly verified Qt PIDs 4135267/4135363 in the same nested
compositor, with no injected input. The source completed its full planned
12-second run and exited 0 (`PLANNED_STOP_EXIT 0`), reporting 286 enqueued
frames and one source-side clean expiry. Windows confirmed 286 native visual
submissions and zero native expired-unbound dispositions, then logged the
expected source-requested connection closure. Those submissions are not
physical scanout receipts. Windows processes and the owned scheduled task were
confirmed absent after cleanup. Logs: `source-sixth.log`, `receiver-sixth.log`.

This establishes one bounded streaming run with input enabled, not mouse-event
delivery. Application-side motion/down/up and switching between the two test
windows remain to be exercised.

## Guarded motion harness trials

An owned temporary Windows harness uses real `SendInput` motion (no buttons),
checking the exact receiver executable, its native child, interactive session,
visible proxy class/title and point hit-test before sending. It raises only the
owned proxy and restores the cursor only if it remains at the test's last point.
It does not send synthetic window messages or claim those would be native input.

Seventh trial ran 12 seconds and submitted 259 frames, but the harness rejected
an absent exact visible proxy before injection. A subsequent attempt reused the
still-visible 90-second witnesses too late in their lifetime; they exited during
the attempt, warmup did not finish by planned stop, and the harness found no
native child. That attempt provides no input acceptance evidence.

Ninth trial used fresh witnesses PIDs 4168435/4168521. The receiver terminated
after six native visual submissions with `clock probe 1 timed out`. The harness
detected proxy retirement and stopped. Both Qt logs contain only `ready`, so no
application-side motion is proven. C# console messages were not retained by
PowerShell redirection; the exact attempted SendInput count is therefore unknown.
The local harness now buffers inventory/send records and writes them explicitly
in `finally`; that logging update has not yet been transferred/rerun.

All three owned Windows tasks/processes were cleaned up and verified absent.
Evidence remains in the temporary directory as `source-{seventh,eighth,ninth}.log`,
`receiver-{seventh,eighth,ninth}.log` and `motion-{seventh,eighth,ninth}.log`.
Next diagnosis is the clock-probe startup ordering relative to fresh-capture
input bootstrap. No input timing or authority checks have been relaxed.

## Input clock startup ordering and tenth trial

A regression delaying source readiness by 400 ms failed before the change: the
preview had already sent its probe and expired the 250 ms liveness timeout.
The preview now waits within the **original connection startup deadline** for
the source input route's clock probe or authorization, then starts the unchanged
250 ms probe loop. It replies to the source probe first; it does not require an
authorization that itself depends on clock synchronization. No readiness means
bounded closure with no outgoing probe. The expanded two-window regression uses
that source-probe-first order, and a separate test covers readiness timeout.
Linux GPU atlas tests passed 75 with two hardware tests ignored; strict GPU
library Clippy passed. Windows receiver rebuilt and passed 55 atlas tests with
one hardware test ignored.

Tenth trial used fresh Qt PIDs 2260/2363, current captured window identities and
the corrected persistent harness event log. It recorded a successful Windows
`SendInput` motion to the exact owned proxy `Viewflow atlas 0:1`. The request
reached source selection processing, but the source rejected it as
`ClockUnsynchronized` and closed the session after 32 native visual submissions.
The most recent source estimate had 5,339 microseconds uncertainty, exceeding
the existing 4,000 microsecond input limit. The Qt witnesses still recorded only
`ready`; this is not application-side motion acceptance. No button was injected.

Logs: `source-tenth.log`, `receiver-tenth.log`, `motion-tenth.log`, and the UTF-16
`motion-events-tenth.log`. Owned Windows task/process cleanup was verified;
main and nested Hyprland remained alive. Next work is safe rejection/recovery
of a selection during temporarily insufficient clock quality, without accepting
that event, renewing its timestamp or relaxing the uncertainty limit.

## Selection rejection recovery and eleventh trial

The source now discards selections whose original clock snapshot is insufficient
or whose original deadline expired, consuming the selection sequence so a later
clock update cannot revive/replay that request. A matched committed capture that
has itself expired yields a typed unavailable result, also without authorization.
Fresh subsequent sequences can proceed. Invalid requests, rebinding and lease
expiration remain errors; button uncertainty still closes the receiver route.
Tests cover unavailable/over-uncertain clocks, expired requests and captures,
replay rejection and unchanged generation/lease upon recovery. All 21 input
runtime tests passed; GPU atlas tests passed 75 with two hardware tests ignored.
Strict GPU library Clippy and the real source CLI build passed.

Eleventh trial used fresh Qt PIDs 24692/24769 and recorded 18 successful guarded
Windows SendInput motions to proxy 0:1 before retirement. Both application
witnesses still contain only `ready`. The receiver submitted 45 native visual
frames and then failed `atlas disposition write exceeded deadline`. This error
comes from the Rust-to-native presentation pipe's post-write deadline check,
**not** the QUIC feedback write; the source then observed connection closure.
The owned Windows task/processes were verified absent after cleanup.

Evidence files use the `eleventh` suffix. Source retirement now reports bounded
summary counters for timing-discarded selections, capture-discarded selections
and authorizations; these counters were added and built after the eleventh run,
so that run cannot be retrospectively classified by those counters. No button
events or application-side pointer delivery have been accepted yet.

## Completed native write resumption and first application motion

A deterministic writer test completes all record bytes but returns from its
flush poll after the deadline. It reproduced the old post-write rejection.
After the change, a **successfully completed** write can use the existing bounded
receipt grace to validate an exact native on-time commit or unbound expiry.
Partial/timed-out writes remain terminal. Native commit at/after the unchanged
QPC deadline remains rejected; no frame deadline was extended. The full-write
test exercises accepted on-time commit, accepted unbound expiry and rejected
late commit; the separate partial-write regression still passes. Linux GPU
atlas tests passed 76 with two hardware tests ignored; strict GPU library Clippy
passed. Windows receiver rebuilt and passed 56 atlas tests with one ignored.

Twelfth trial, fresh Qt PIDs 51416/51519, recorded four successful Windows
SendInput motions to owned proxy 0:1. **The Linux Atlas-A application received
one spontaneous mouse motion at (87,94)**, with preceding enter and subsequent
leave. The fourth injected client coordinate (89,96) maps to (87,94) after the
two-pixel decorated capture offset. Atlas-B recorded no input. This is the first
actual application-side motion evidence in this input-enabled atlas workflow;
it does not prove click, sustained motion, or two-window switching.

The receiver then retired after eight native visual submissions with
`late or mismatched window ACK`. Source counters were timing-discarded=1,
capture-discarded=0 and selection-authorized=0; initial bootstrap authorization
is not counted as a selection authorization. The connection did not reach its
planned stop. Logs use the `twelfth` suffix, including `Atlas-A-twelfth.jsonl`
and the UTF-16 motion event log in the same temporary evidence directory.
The next boundary is ACK identity/timeliness; application motion alone cannot
be treated as a successfully acknowledged input operation.

## Control dispatch during native presentation and thirteenth trial

The receiver previously stopped polling its sole reliable control reader while
awaiting native presentation. `with_handoff_controls` now continues forwarding
input/clock controls during that await, retaining the same sequencer and pending
read. A premature next atlas manifest remains a protocol error before the
current disposition. The QUIC regression requires a control to reach its
consumer **before** the simulated native presenter can complete. Linux GPU atlas
tests passed 77 with two hardware tests ignored, strict GPU library Clippy
passed, and Windows rebuilt with 57 atlas tests passing and one ignored.
ACK diagnostics now distinguish identity mismatch from a late receipt, without
changing the deadline or accepting a failed confirmation.

Thirteenth trial used fresh Qt PIDs 77036/77155. The harness sent 14 motions to
proxy 0:1; Atlas-A recorded one spontaneous motion at (117,114), matching client
(119,116) minus the two-pixel border. Atlas-B recorded no input. The receiver
submitted 70 visual frames before `window motion confirmation timed out`.
Source counters: timing-discarded=10, capture-discarded=2, selection-authorized=0
(bootstrap authorization excluded). This is further application delivery evidence,
not a confirmed input operation or continuous-control acceptance. The owned
Windows task and processes were verified absent after cleanup. Logs use the
`thirteenth` suffix. Next measurement targets event age and remaining confirmation
budget at transmission; no deadline has been increased.

## Timing diagnostics and fourteenth trial

The preview now records three local-clock values for its pending input: pump
start, original deadline and writer completion. Timeout/late-ACK errors include
these values. The source records network receipt/native completion alongside
its existing native send/deadline tuple and prints them only at session cleanup.
No per-event logging or timing/authorization change was introduced. Linux input
runtime tests passed 21/21; Windows preview tests passed 15/15 and the receiver
rebuilt. Strict GPU library Clippy passed after extracting the unchanged pending
confirmation guard into a small helper.

Fourteenth trial used fresh Qt PIDs 104938/105079. All 40 guarded SendInput
motions were sent, 20 to each owned proxy. The source completed its planned
12-second run with exit 0 and 269 enqueued frames, but neither Qt witness received
motion. Selection summary: **23 timing rejections** (clock quality or original
deadline expiry; this counter does not distinguish them), **12 stale-capture
rejections**, zero selection authorizations. Thus this run never produced an
application motion/ACK pair for the new timing instrumentation to measure.
It establishes input-admission starvation in this run, not an ACK latency result.
Logs use `fourteenth`; input injection is not acceptance evidence by itself.

## Source input service during media awaits and sixteenth trial

The source previously polled input selection only before and after a complete
GPU media poll/send await. It now services input at a one-millisecond skipped
tick while that same media future is pending. Only already committed snapshots
remain eligible; no input deadline, capture-age limit or authorization scope was
changed. Input service failure cancels media and follows the existing explicit
input/GPU shutdown path. A regression requires input service to run before media
can complete, and checks propagation of service failure and unexpected completion.
GPU atlas tests passed 78 with two hardware tests ignored; strict GPU library
Clippy and the actual Linux source build passed.

The fifteenth attempt ended before media transfer and provides no input result.
The sixteenth used fresh Qt PIDs 142200/142312 and completed the planned 12-second
source run with exit 0: 178 enqueued frames, three clean expiries. The Windows
harness sent 40 guarded motions across the two owned proxies. Neither Qt witness
recorded application motion. Source selection counters were timing-discarded=2,
capture-discarded=33 and authorized=0. Timing counts still combine clock-quality
and original-deadline rejection. This run identifies stale-capture selection as
the dominant recorded rejection, not proof of improved timing or accepted input.
Receiver retirement followed the planned source closure after 178 native visual
submissions. The Windows task reached Ready and both test process names were
absent. Evidence files use the `sixteenth` suffix in the same temporary directory.
Continuous motion, button input, switching and acknowledged delivery remain open.

## Capture-age diagnostics and 60 fps attempts

Capture rejection now carries measured age and its unchanged limit. The source
retains only the last rejected selection tuple (sequence, source frame, age ns,
limit ns) and prints it at retirement, avoiding per-event logging. The existing
policy test checks that age exactly equal to the limit rejects with those exact
values and consumes its sequence; all 22 window input runtime tests passed.

Seventeenth trial increased only the temporary source capture request from 30 to
60 fps; the receiver remained 60 Hz and the original two-refresh-period limit
was unchanged. Fresh Qt PIDs were 165241/165344. Source stopped after five frames
with `before atlas frame preparation: atlas operation deadline expired`, before
the motion harness could provide application evidence.

That boundary is now a typed `AtlasFrameExpiredBeforeSend`: it is emitted before
any sender mutation, manifest enqueue or media enqueue. The GPU owner can recover
only this exact error, retain completed/released capture ownership, request a
paired keyframe and publish no committed-input evidence. All post-enqueue errors
still retire the sender. A real QUIC regression rejects expired frame 1 and proves
the first received frame is the subsequent valid frame 2. GPU atlas tests passed
79 with two hardware tests ignored, strict GPU library Clippy passed, and the
Linux source binary rebuilt.

Eighteenth trial, also 60 fps, used fresh Qt PIDs 184108/184174. It stopped after
eight frames with `shared control send deadline expired`. This is not the typed
pre-send boundary and remains terminal. Both Qt witnesses logged only readiness;
no selection rejection was available for the new age diagnostic in either run.
Therefore neither run compares successful 30/60 fps input operation or validates
continuous input. Receiver logs use `seventeenth`/`eighteenth`; both Windows runs
reached Ready with test processes absent. The next remaining boundary is time
spent before and during shared-control transmission under the original deadline.

## Source runtime scheduling and nineteenth trial

The Linux CLI used a current-thread Tokio runtime, so synchronous GPU work also
prevented spawned QUIC writers, clock probes and native input sessions from
being polled. Its runtime now has two worker threads while the GPU root future
remains in `Runtime::block_on` on the caller. The executable regression blocks
that caller waiting for a spawned worker and checks the root thread identity
after an await: it passes with the new runtime and cannot make progress on the
old current-thread builder. The executable test, strict executable Clippy and
source build passed. Windows runtime and all admission/deadline rules are unchanged.

Nineteenth trial used 60 fps capture, fresh Qt PIDs 200925/201137 and unchanged
60 Hz limits. Source enqueued 68 frames with one clean expiry, then stopped with
`GPU encoding failed with status 3: frame deadline expired before fence wait`.
The harness sent six guarded motions, but both Qt witnesses recorded only
readiness. Source recorded five capture rejections, zero timing rejections and
zero selection authorizations. The last rejection tuple was
`[5, 326, 102491540, 33333333]`: sequence 5 referenced source frame 326, aged
102.491540 ms at source policy handling against a 33.333333 ms limit. This is
measured stale-capture rejection, not evidence of a wrongly relaxed input gate.
It does not isolate which stage aged that frame. The GPU failure is within the
native tile preparation loop and is not covered by the safe pre-send recovery.
The owned Windows task reached Ready with no test processes remaining; source,
receiver and motion evidence use the `nineteenth` suffix. Input acceptance and
sustained 60 fps operation remain unproven.

## Clean expiry before a tile fence wait

Native source review located a recoverable boundary in the nineteenth failure:
before entering a tile's fence wait, that tile has no imported resources, and
every previous tile has already completed stream synchronization and checked
import cleanup. Deadline expiry at this exact point now returns the existing
`ExpiredBeforeSubmission` disposition. Monotonic-clock read failure, fence
failures, driver errors and cleanup errors still return failure, not clean expiry.
No frame deadline is extended. Test injection is compiled out of production.

An isolated Debug build with `VIEWFLOW_TEST_GPU_EXPIRY=ON` passed the native
DMA-BUF/CUDA/NVENC integration test. New injections cover expiry before the first
tile and before the second tile, after the first tile has completed preparation.
Both produce no color/alpha output, followed by successful encoding on the same
encoder with decoded color and exact alpha checks. The C ABI test also checks
clean status and null output before the first fence wait. Existing stage-1/2
expiry and continuous GOP decoder checks still pass. Build/log directory:
`/tmp/viewflow-fence-expiry.oRcCw3`, result `integration.log` ends with PASS.
The production Rust source rebuilt without injection; four GPU-runtime boundary
tests passed and the separate manual owned-buffer test remained ignored. No new
cross-host trial has yet exercised this native recovery change.

## Twentieth cross-host trial

With the production fence-boundary recovery build and 60 fps capture, fresh Qt
PIDs 234267/234379 were used. The source enqueued seven frames and recorded two
clean expiries before the receiver closed the connection. These counters do not
distinguish which clean-expiry stage occurred. Four guarded Windows motions were
sent to proxy 0:1; **Atlas-A received one spontaneous motion at (81,90)** followed
by leave, while Atlas-B recorded readiness only.

Source delivery sequence 1 was received at native monotonic 30641852302230 ns
and completed at 30641853409082 ns: 1.106852 ms. Its native send deadline was
30641855723315 ns, so completion preceded that deadline by 2.314233 ms. This
supports application motion and source-side native completion, not independently
verified receiver ACK acceptance. No ACK timeout was reported before retirement.
Three further selections were rejected for stale capture; the last age was
94.237502 ms against 33.333333 ms. No button or continuous switching acceptance.

The receiver logged `stage=foreground-gpu-copy` with `atlas native deadline
expired` after seven visual submissions. Source review shows the stage label
persists after copying, so it does not uniquely identify the failing deadline
check; `Present` contains later checks before and during visual mutation. Do not
classify this as a recoverable unbound-copy expiry without locating that check.
The owned Windows task reached Ready, was unregistered and test process counts
were zero. Source, receiver, Qt and motion evidence uses the `twentieth` suffix.

## Native deadline phase labels and twenty-first trial

`CheckDeadline` now labels decoded admission, unbound-copy completion, the first
visual mutation and a subsequent partial mutation separately. These labels only
change failure diagnostics; deadlines, checks and recovery are unchanged. Windows
Release rebuilt and all 17 assertion-enabled CTest cases passed. Presenter SHA256:
`E05EFD682F6777828E7F07F98DD758EAB4B417714C1E015BA9FEA3907CD2F5AE`.

Twenty-first trial used fresh Qt PIDs 254394/254637 and 60 fps capture. Atlas-A
recorded one spontaneous motion at (78,88), while Atlas-B remained input-free.
Native source completion took 2.098351 ms and preceded its original deadline by
1.075380 ms. Source enqueued 15 frames with one clean expiry, then the connection
closed. Its last stale capture was 64.335707 ms old against the same 33.333333 ms
limit. Receiver error chain reported `atlas input control owner disappeared` and
`sending stopped by peer: error 0`; **no native deadline label was emitted**.
Thus this trial does not locate the earlier display expiry, and does not prove
continuous control or receiver ACK acceptance. Its error must not be relabeled
as another GPU-copy deadline failure. Logs use `twentyfirst`; the Windows task
reached Ready and was unregistered with test processes absent.

## Media-error preservation and subsequent boundaries

The source input/media race now drains the already-admitted media future for up
to five seconds after input service failure, preserving a media error produced
during producer cleanup. Input failure closes the paired connection first; this
is not an extension of input/frame deadlines or permission to send a new frame.
The outer owner still performs checked shutdown if draining times out. Regression
coverage models a media failure followed by delayed cleanup and a consequent input
disconnect, asserting the media error remains the root cause. Strict Linux GPU
library Clippy and the source build passed.

Twenty-second trial (Qt PIDs 279350/279451) enqueued 27 frames with four clean
expiries and no application input. Windows reported `atlas commit exceeded native
deadline`, which is after visual mutation and cannot use unbound-frame recovery.
The presenter now avoids redundant visual-size, SetWindowPos and ShowWindow calls:
actual client size and visibility are checked, and retained-window set allocation
happens before visual mutation. The last QPC check remains immediately before
binding pixels. Deferred diagnostics count resize/show calls. Release build and
17 assertion-enabled CTest cases passed; presenter SHA256 is
`14095FD7FE7435FA9B8349430FEF7E221655733356A9DE687A50801D6EB1440A`.

Twenty-third trial (Qt PIDs 293861/294217) enqueued 19 frames with two clean
expiries. Atlas-A recorded one spontaneous motion at (90,96); source native
completion took 2.116502 ms, with 10.568326 ms remaining to its original deadline.
The receiver instead failed `atlas expired during admission: Expired`. No deferred
window-update counts were recovered before child retirement, so this run does
not quantify the Win32-call optimization.

That admission-to-decoder boundary now uses negotiated expired-unbound feedback:
an exact age expiry after paired admission, but before decoder handoff, resets
the reference chain and preserves input ownership. Other admission errors remain
terminal. A real QUIC test advances time between pair admission and handoff, then
verifies that only the subsequent fresh keyframe reaches the caller. Linux atlas
tests passed 81 with two hardware tests ignored; strict GPU library Clippy passed.
Windows receiver rebuilt, atlas tests and all 15 preview-input tests passed;
receiver SHA256 `EAE693FE455878A3B553294B538D621A1949D36D94D8CB0D0D3A66A16B5FE9B2`.

Twenty-fourth trial (Qt PIDs 315226/315574) enqueued 42 frames with one clean
expiry, no application input and a final selected-capture age of 84.020208 ms.
The preserved source error was `shared control queue deadline expired`, rather
than only the consequent input disconnect. All these tests retained 60 fps
capture and 60 Hz deadlines. Both peers still used Rust debug binaries; optimized
Release binaries are being prepared for a separate timing trial. Each owned
Windows task reached Ready and was unregistered with test processes absent.
Evidence suffixes are `twentysecond`, `twentythird` and `twentyfourth`.

## Optimized Release trials and first two-window application motion

Both Rust peers were rebuilt in Release without changing source, protocol or
deadlines. Linux source SHA256:
`c2d441421400c844880acc86ce59cdf6f8c62e6069ea15bc78780a820b8cb6e5`;
Windows receiver SHA256:
`715FAF39CDD013DDACF2A82268FD101465F08C066722E84DFC32FD58646803FD`.
The Windows native presenter remains the Release `14095FD7...EB1440A` build.

Twenty-fifth trial (Qt PIDs 331049/331123) completed the planned 12-second source
run with exit 0, 378 enqueued frames and one clean expiry. However, the motion
harness correctly rejected the Release executable because its identity guard
still required the debug path. **No input was injected.** Its copied
`motion-events-twentyfifth.log` is stale from an earlier run and must not be used
as trial evidence. A separate Release harness now checks the exact Release path,
retaining the same host/session/native-child/owned-window guards.

Twenty-sixth trial (Qt PIDs 342210/342286) used that corrected harness. All 40
guarded motion injections completed; source ran the planned 12 seconds with
exit 0, 277 enqueued frames and two clean expiries. **Atlas-A received two
spontaneous motions, at (81,90) and (120,116), then leave. Atlas-B subsequently
received enter and spontaneous motion at (96,100).** This is the first actual
two-window application motion/switch evidence for this atlas workflow.
Source recorded two selection authorizations, 38 stale-capture rejections and
zero timing rejections. The last selected capture was 57.043090 ms old against
33.333333 ms. Three delivered motions out of 40 injections do not constitute
smooth or continuous control; no button was injected. Receiver retirement followed
the planned source closure after 277 native visual submissions. Both owned
Windows tasks reached Ready and were unregistered with test processes absent.
The isolated monitor was read back as 1280x960 at 60 Hz, scale 1; its configuration
was not changed. Evidence suffixes are `twentyfifth` and `twentysixth`.

## Selection queue timing and twenty-seventh trial

Source rejection diagnostics now retain source-queue duration, conservative event
budget remaining and the local sampling span, using the existing request-receipt
timestamp and unchanged clock/deadline validation. No admission behavior changes.
Strict GPU library Clippy, both input-service regressions and the Release source
build passed.

Twenty-seventh trial (fresh Qt PIDs 381977/382082) completed the planned 12 seconds
with source exit 0, 348 enqueued frames and five clean expiries. All 40 guarded
motions were injected; only Atlas-B received one spontaneous motion at (90,96).
Source counted 36 capture rejections, four timing rejections and one authorization.
Its last rejected capture age was 37.174951 ms, with diagnostic tuple
`[1500258, 4869812, 5135]` ns: 1.500258 ms in the source selection queue,
4.869812 ms of conservative event budget left, and 0.005135 ms sampling span.
That sample does not establish an already-stale visual at event time: the
conservative event-time capture-age lower bound is only about 8.706 ms. It does
show that source queueing alone cannot explain the consumed 33.333334 ms event
budget. Next measurement should separate Windows native-event/pipe delay from
receiver-side selection delay. The owned Windows task reached Ready and was
unregistered with test processes absent. Evidence uses `twentyseventh`.

### Native stdout bounded read-ahead

Inspection after trial 27 found `dispatch_stdout` passed the raw native pipe
to a byte-at-a-time bounded line parser. It now owns a persistent 4096-byte
`BufReader`, avoiding an underlying read per byte when a complete batch is
available. Read-ahead survives record boundaries; the 1024-byte line limit,
event queue bound, original event deadline, and fail-closed behavior remain
unchanged. This is a read-path optimization, not a proven explanation of the
Windows event latency.

A counted-reader regression supplies one readiness record and two distinct
pointer records. It verifies one underlying batch read plus one EOF read,
ordered source-frame identities, exact readiness bytes, and terminal EOF.
The terminal-input test also covers an oversized record with buffered input.
Local validation: all 70 default-feature Atlas tests passed; strict
`native-gpu-nvenc` library Clippy and formatting checks passed. This change has
not yet been deployed or measured on Windows; trial 27 remains the latest
live evidence and does not demonstrate continuous input acceptance.

### Trial 28: buffered native stdout, all guarded motions delivered

Built the changed Windows release receiver successfully (SHA-256
`96B256FB85FBD5E4A88F53C53A0D11F92EE917D7705D5CCC31BC40854D696FEE`).
The native presenter and Linux release source were unchanged from trial 27.
Fresh isolated Qt applications were verified as Wayland clients before binding
their current addresses in the test configuration. The existing guarded
release-mode harness injected 20 motions in each of the two owned proxies.

The source ran the full planned 12 seconds and exited 0 after SIGTERM, with
640 enqueued frames, one clean pre-send expiry, zero timing discards, zero
capture discards, and 41 authorizations. The receiver reported 640 native
visual submissions and zero expired-unbound submissions before the planned
source shutdown. These are not physical scanout receipts.

Both Qt event logs contain exactly the expected ordered 20 spontaneous motion
coordinates `[78 + 3*i, 88 + 2*i]`, for `i=0..19`. Independent `jq -e`
comparisons passed for both logs; the UTF-16 Windows event log contains exactly
40 `owned-motion` records. Thus all 40 guarded motions reached the intended
applications across the window switch in this trial, unlike trial 27's one.
This strongly implicates the unbuffered pipe read path in the prior failures,
but is not a direct per-stage latency measurement or a sustained-load bound.

Evidence files in the owned temporary test directory use `twentyeighth`.
The Windows task reached Ready and its staged processes were absent before
unregistration. Button/drag delivery, longer stress coverage, and the broader
plan's other acceptance requirements remain unproven by this motion-only run.

### Trial 29: first held movement delivered; second-window press retires input

The Qt witness now records the held-button mask (`qt_buttons`) on motion and
button events; its rebuild succeeded. A separate guarded release-mode harness
presses left after motion 3, moves while held, releases after motion 18, and
finishes two unheld motions before switching to the second owned proxy. It
refuses to start with the local left button held and releases its own successful
press in `finally` on failure. The receiver/source binaries were unchanged.

Atlas-A recorded a spontaneous press at (84,92), 15 held motions, and a
spontaneous release at (129,122), returning `qt_buttons` to zero. The Windows
log subsequently records the first press attempted in Atlas-B, but Atlas-B has
no application-side button event. Native output reports the combined reason
`atlas-focus-or-capture-lost`; the source exits early after 113 frames, with zero
timing/capture discards. Therefore this proves one in-widget held movement,
not two-window button acceptance or application drag/drop semantics.

Inspection found unconditional retirement on `WM_KILLFOCUS` and
`WM_POINTERCAPTURECHANGED`, while leave retires only when a button is held.
The combined diagnostic does not identify which message caused this run to
end. Native source now emits separate reason strings for these three cases;
the termination policy is unchanged and this diagnostic build is not yet live.
Before changing focus-transfer policy, reproduce with the distinct diagnostic.
The owned Windows task reached Ready with staged processes absent and was
unregistered. Trial evidence files use `twentyninth` (including `drag-events`
and `drag` harness logs).

The distinct-reason native Windows Release build subsequently passed all
17 CTest cases. Its SHA-256 is
`60D93C96C4173A57838EBB80EE7E81CA4565F911D63345F9F2E15A4F06F79AD8`.
It is staged for the next reproduction, not yet exercised in a live session.

### Trials 30–31: internal focus transfer corrected; both held movements pass

Trial 30 reproduced early retirement after 106 frames with the new specific
reason `atlas-focus-lost`. The second proxy's press caused the first proxy's
normal focus loss to terminate the shared input session. No timing/capture
discard occurred. Both owned probes and the Ready Windows task were cleaned up.

The native handler now permits a focus transfer only to another visible HWND
in this process and UI thread with the exact Atlas class window procedure and
a non-null Atlas input binding. Both input states must be enabled, unheld and
bound to distinct windows of the same committed stream/frame/layout identity.
All other focus loss, capture loss and held-pointer leave retain retirement.
This does not authorize a source route or change any input deadline.

Pure state tests cover successful internal transfer and rejection of self,
empty, disabled, retired, foreign-stream, held and different-frame targets.
An initial fixture reused button-mutated motion state and tripped the existing
duplicate-position test; isolating its state preserved that assertion.
Windows Release build and all 17 CTest cases then passed. Native binary hash:
`902A35FF49797F722D9514995DD895EF56A3971CC64DC8B1CAA579299F22AFCC`.

Trial 31 used this native binary and the unchanged release peers/harness.
It ran the full planned 12 seconds, exiting 0 after SIGTERM: 623 frames,
two clean source expiries, zero input timing/capture discards, 45 authorizations.
Receiver reported 623 native visual submissions and zero expired-unbound.
Both application logs match all 20 expected ordered coordinates and held masks:
motions 4–18 have `qt_buttons=1`, all others zero. Both recorded a spontaneous
press at (84,92) and release at (129,122). Windows recorded exactly 40 motions
and four button transitions. Per-application `jq -e` comparisons passed.

This proves two sequential in-widget held movements across an internal focus
switch, not semantic application drag/drop, held cross-window transfer,
physical scanout, or sustained stress. External-focus retirement on this build
still needs a targeted live negative check. Evidence uses `thirtieth` and
`thirtyfirst`; the latter Windows task reached Ready with no staged processes.

### Trial 32: external-focus negative gate not reached

A separate harness first repeats the two owned-window held movements, then
requires an unheld second-proxy foreground before showing an empty owned
WinForms window. It checks that the new window actually becomes foreground
and observes receiver exit without further input. This run stopped at the
initial foreground check (`owned unheld foreground missing`), so the external
window was never activated. The 12-second source stop (550 frames) is not
external-focus retirement evidence. One source timing discard was observed;
the earlier zero-discard runs must not be generalized to this run.

The harness has now been changed to explicitly request foreground activation
of the exact visible owned second proxy, refusing held-left state, checking
the activation return value and verifying the resulting foreground HWND.
Only then may it show the external witness. This corrected harness is staged
but not yet exercised. Native/Rust production code was unchanged in this trial.
The Ready Windows task had no staged processes and was unregistered. Evidence
uses `thirtysecond`, including `focus-events` and the harness error in `focus`.

### Trial 33: external focus achieved, terminal reason not retained

The corrected harness logged the verified second-proxy foreground HWND,
then the verified external empty-form foreground HWND. The receiver exited
28 ms after the harness started its post-focus observation stopwatch; no
additional input was injected during that observation. This is observed process
exit timing, not a native-release latency or exact focus-event timestamp.

Receiver output retained only `atlas input producer ended`, not the native
focus-loss reason. Consequently this run verifies the foreground transition
and subsequent exit but does not close the cause-specific negative gate.
Source stopped early after 172 frames, with three timing and one capture
discard. Atlas-A received 16 motions; Atlas-B's 20 coordinates/held masks
matched exactly. Do not count this as another 40/40 interaction pass.

Native retirement now writes its reason to inherited stderr immediately after
retiring local state and before notifying stdout. The stdout notification can
trigger immediate reader/child teardown, so it must not be the only diagnostic
copy. This adds no admission exception or deadline change. Rebuild and a new
live reproduction are required. The owned task reached Ready without staged
processes and was unregistered. Evidence uses `thirtythird`.

### Trials 34–37: isolate focus gate and preserve reader failures

The native stderr diagnostic build passed 17 Windows tests; SHA-256:
`B19BB01DBAB3267AB8DDC9F98027ED58CF2B727C75D29105BA900AD92B20B553`.
Trial 34 ended after 19 frames with `atlas button expired awaiting selection`
and one source capture discard, before external focus. The focus-negative
harness therefore no longer requires the independently tested drag sequence.
It requests the exact owned proxy foreground directly, with no injected input.

Trial 35 missed the initial native-child discovery timeout and ran to the
planned stop (408 frames). Its copied event log was stale from trial 34 and
must not be counted. The harness now creates an empty event log before child
discovery and allows 30 seconds for discovery, without changing production
startup or event deadlines. Trial 36 reused still-observed probes approaching
their automatic exit and produced zero live frames before media idle timeout;
no visible proxy was available for focus setup. Fresh probes are required for
subsequent trials; focus setup now waits up to five seconds for the exact
visible proxy instead of assuming it is ready after a fixed sleep.

Trial 37 used fresh probes and produced three native submissions. Foreground
activation returned success but its immediate HWND read-back did not verify
the target; receiver again reported only `atlas input producer ended`. No
external-focus pass is claimed. Native/Rust errors, foreground setup, and
rendering readiness must not be conflated. All four owned Windows tasks
reached Ready without staged processes and were individually unregistered.

Inspection identified a diagnostic race in the Rust stdout worker: the
`dispatch_stdout` future dropped its pointer sender before the outer wrapper
logged its error. A concurrent input owner can observe closure and abort that
wrapper first. Error logging now happens inside `dispatch_stdout`, explicitly
before dropping the sender. The duplicate outer log is removed. Pointer parsing,
queue bounds and terminal policy are unchanged. Five pointer tests and strict
GPU-feature library Clippy passed; Windows receiver rebuild is pending below.

All 70 default-feature Atlas tests subsequently passed. Windows release
receiver rebuild succeeded (16 existing unused-code warnings), SHA-256
`B51954CE51BA17497807F9D80DA783C4FDC99A8DE2EEB0D39C6E6FC5F92AA5A1`.
This diagnostic-order build has not yet been used for the focus test.

### Trials 38–39: handoff cancellation masked the original timeout

Trial 38 used the diagnostic-order receiver and fresh probes. It ended after
64 frames with the same generic producer-closure result and unverified
foreground setup. No stdout-reader error was logged. Inspection then found
another cancellation boundary: `with_handoff_controls` could return a control
connection error while the already-admitted native submit future was still
terminating its child after a presentation error. Dropping that future erased
the original error. The input owner had closed the connection after observing
the child output queue close.

On a handoff control error, the receiver now closes control/input authority
immediately and drains only the already-admitted submission, bounded to three
seconds. A native failure retains its typed root with control context; a native
success still returns the control failure. No new frame is admitted and no
submission deadline is extended. A real authenticated QUIC regression admits
a V3 frame, closes during simulated 10-ms native cleanup and asserts both
cleanup completion and typed original error preservation. The first test
fixture waited for sender feedback before doing the receiving work; correcting
that ordering made the regression exercise the intended race. All 71 Atlas
tests and strict GPU-feature library Clippy passed.

Windows release receiver `E04361E57DE911CAFD7494578A3D8CD5A656E4EFF20707A9CD74979871D016BB`
was then exercised in trial 39 with the same native diagnostic build. After 68
native submissions, the final chain preserved the original `deadline has
elapsed` underneath `atlas handoff control also ended`, rather than losing it
to producer closure. Focus setup was not verified; the external window was
not activated. Both test tasks reached Ready with no staged processes and were
unregistered. Evidence uses `thirtyeighth` and `thirtyninth`.

The disposition pipe now adds distinct contexts for write timeout/write I/O
failure and receipt timeout/read failure, preserving the underlying error.
This separates the two timeout boundaries in the next reproduction; it does
not relax them. The native focus-loss safety gate remains open.

The contextual-error build passed 12 presenter tests and strict GPU-feature
library Clippy. Windows Release rebuild succeeded, SHA-256
`5072C596F24B86D7F406E9EB5DFFFA9F71753221D57B04FFCDBFF8EFE75E63CC`.
It is staged for the next live timeout classification, not yet exercised.

### Trials 40–42: receipt timeout localized to default activation handling

Trial 40 (53 native submissions) classified the preserved original failure as
`atlas disposition receipt deadline expired`, not pipe-write timeout. No
external focus was verified. The harness's immediate foreground assertion was
also incorrect for cross-input-queue activation: Microsoft's explanation of
[`SetForegroundWindow` followed by `GetForegroundWindow`](https://devblogs.microsoft.com/oldnewthing/20161118-00/?p=94745)
describes the asynchronous activation step. The helper now waits up to one
second for the exact owned foreground HWND, retaining all ownership/held-state
checks and without attaching input queues. Trial 41 verified owned foreground,
but failed its external foreground assertion and again timed out on the receipt
after 55 submissions. External-form activation now also has bounded read-back.

Added opt-in `VIEWFLOW_ATLAS_PROGRESS_DIAGNOSTICS=1` native stall sampling.
When disabled (default), there is no watchdog thread. When enabled, atomic
phase/timestamp snapshots are checked every 10 ms, with one diagnostic emitted
for a non-idle phase observed unchanged for at least 80 ms. This is diagnostic
sampling, not an acceptance timer or authority to extend frame deadlines.
Phases: 1 message polling, 2 WndProc dispatch, 3 default WndProc, 4 decode,
5 region copy, 6 visual bind, 7 receipt. Windows build and all 17 tests passed;
native SHA-256:
`8B1974DF3514A39ED95632F90E3D4CBDFE7ACBDEBEDBE968C63A053DF2C480C2`.

Trial 42 enabled this diagnostic via its separate owned launcher. After two
native submissions, it recorded `atlas-stall phase=3 message=6 observed_ms=93`:
the last marked UI phase was `DefWindowProcW` for `WM_ACTIVATE`. The final receiver
failure was again disposition receipt timeout. The harness recorded owned and
external foreground HWNDs and observed receiver exit 18 ms into its subsequent
watch; that is not proof of focus-loss retirement, since the retained root is
receipt timeout and no native focus-retirement reason was emitted. The sample
does not yet distinguish activation from deactivation or identify the blocking
work. The initial sampler did not clear its default-procedure phase on return,
so this sample alone cannot prove that the call was still active. It narrows
the next investigation to that message
handling boundary, rather than decoder or pipe-write performance.

Evidence uses `fortieth`, `fortyfirst` and `fortysecond`; the first two owned
Windows tasks were unregistered after Ready/no-process verification. The third
is checked and cleaned separately after collection. The progress sampler remains
off in normal launchers; diagnostic timing is not sustained interaction proof.

Follow-up instrumentation now clears the default-procedure marker immediately
after its return and marks every message-poll iteration. This avoids attributing
a later queue stall to an earlier default-procedure call. That refinement has
not yet been used live; trial 42 must retain the caveat above. Its subsequent
Windows Release build passed all 17 tests, SHA-256
`43782F5552F8D1735DE8418473BFFB53FF35A81B141E9541317465375670790C`.
Trial 42's task was also unregistered after Ready/no-process verification.

### Trials 43–44: active-window default handling; IME hypothesis remains open

Trial 43 used the refined marker boundaries and again observed default-procedure
phase 3, message 6 (`WM_ACTIVATE`), unchanged for 94 ms before receipt timeout
after three native submissions. Unlike trial 42, the default-procedure marker
is cleared immediately on return, so the earlier stale-marker caveat no longer
explains this sample. The owned/external foreground read-backs and subsequent
5-ms process-exit observation still do not establish focus-policy retirement.

The optional watchdog then gained `WM_ACTIVATE` parameter recording and
read-only [wait-chain queries](https://learn.microsoft.com/en-us/windows/win32/api/wct/nf-wct-getthreadwaitchain)
for its own UI thread. It does not enable debug privileges or log object names;
permission failures remain explicit. Build and 17 tests passed, native hash
`112FAD359D2E56B522F078DF53C7AC0A26BA7F4D30B15BF28A8F446C34F9124D`.
Trial 44 observed `phase=3 message=6 detail=1 observed_ms=94`, establishing
`WA_ACTIVE`, not deactivation, before receipt timeout after 54 submissions.
The wait chain returned one thread node with status Running and no cycle;
that does not identify a blocking object or exclude unsupported waits.
An earlier decode-phase stall was during startup, before `atlas-peer-ready`.
Both tasks were unregistered after Ready/no-staged-process verification.

Windows default activation processing sets keyboard focus. Local IME work is
one hypothesis, not an established cause. Added the separate diagnostic flag
`VIEWFLOW_ATLAS_DIAGNOSTIC_NO_IME=1`: before any UI-thread windows are created,
it calls [ImmDisableIME](https://learn.microsoft.com/en-us/windows/desktop/api/imm/nf-imm-immdisableime)
only for that thread and rejects failure. The normal path remains unchanged.
A separate owned no-IME launcher also enables the progress watchdog for the
comparison. Its Release build and all 17 tests passed; native SHA-256
`1944A92B3FBF97A2DE906576FB9163DF451B51EF7D7F759F344DC0456C049AEC`.
Evidence uses `fortythird`/`fortyfourth`.

### Trials 45–46: no-IME activation and guarded external focus

Trial 45 enabled only the diagnostic no-IME path plus the watchdog. It completed
the planned 12-second source lifetime, 340 native visual submissions, without
receipt timeout or an activation stall report. The helper verified the owned
proxy foreground but Windows refused its subsequent programmatic external
foreground transition. Thus this is not a focus-retirement pass.

For trial 46 the helper raised its own blank witness window, verified its PID,
visibility and exact HWND at a client point, and clicked only that point. It
rejects a pre-held left button and balances its own button press in cleanup;
cursor restoration is conditional on the cursor remaining where it put it.
Both owned-proxy and external-witness foreground HWNDs were read back. Native
output explicitly emitted `native-pointer-retired reason=atlas-focus-lost`;
the receiver exited 73 ms after external foreground observation, after 12
native submissions. The source saw peer closure rather than its planned stop.
There was no receipt deadline failure. The following EOF is teardown, not a
physical-present receipt. This closes one external-focus negative case only
with the diagnostic IME flag enabled; it does not establish a production fix,
normal-path acceptance, or causation. Trial 45's owned task was unregistered
after Ready/no-staged-process verification; trial 46 received the same cleanup.
Evidence files use `fortyfifth`/`fortysixth` under the owned harness directory.

### Trials 47–48: baseline reversal with guarded witness click

Trial 47 reused probes near their 90-second automatic lifetime and admitted
zero visual frames. Its media-idle/wait timeout cannot test activation or IME;
exclude it from the comparison. The task was cleaned after Ready/no-process
verification. Subsequent comparisons must launch fresh probes and verify their
addresses immediately before the source starts.

Trial 48 launched fresh probes and restored the normal IME path, retaining the
same watchdog and guarded witness-click helper as trial 46. The owned and
external foreground read-backs both succeeded, but the native output again
reported `phase=3 message=6 detail=1 observed_ms=94` and disposition receipt
deadline expiry after three native submissions. No native focus-retirement
reason was emitted. The 525-ms post-foreground exit observation therefore is
not a focus-policy pass. This reversal supports IME-related activation work as
a causal candidate: two diagnostic-disabled runs avoided the failure, and the
normal-path reversal reproduced it. It does not identify the exact IME/TSF
component or justify silently changing future keyboard/text semantics. The
flag remains diagnostic and off by default. No media deadline was relaxed.

### Trials 49–51: source-composition policy in native-input startup

The physical-key/HID architecture places text composition with the source
application. Atlas proxies are not local text editors. Native-input startup now
therefore disables local IME on its dedicated UI thread, before COM or proxy
window creation. Preview-only startup remains unchanged (apart from the
existing explicit diagnostic flag). This uses the documented thread-scoped
[ImmDisableIME startup boundary](https://learn.microsoft.com/en-us/windows/win32/api/imm/nf-imm-immdisableime),
not a system setting or process-wide disable. Failure rejects startup. A new
unit test covers opt-out/no-call, exact thread scope, API failure, and rejecting
zero/process-wide sentinel IDs. All 18 Windows Release tests passed, native
SHA-256 `A74FD0E133DE73BFCA105605AAA23DE5B5E4959503A44ABF2DA71DBFE76A8FEC`.
This replaces the default-policy status above, not the historical observations.

Trial 49 used the normal launcher without either IME/watchdog diagnostic flag.
Both foreground HWNDs were verified, the native path explicitly retired with
`atlas-focus-lost`, and the receiver exited 83 ms after the external observation,
after 15 native submissions. No receipt timeout occurred.

Trial 50 also used a normal launcher and completed 12 seconds, 473 submissions,
with balanced press/release in both source applications. Only 36/40 motions
arrived (20 in A, 16 in B); three timing discards and one capture discard were
reported. The latter retained a 255487327-ns capture age against 33333333 ns.
This is not complete interaction acceptance and is not attributed to IME.

Trial 51 used fresh probes with only those two source clients present. It
completed 12 seconds, 472 native submissions, zero input timing/capture discards.
Both Qt applications received all 20 expected motions, exact client coordinates,
one press, 15 held-motion events, and one release returning the button mask to
zero. Source logs remain `application_delivery_proven=false` because transport
alone cannot prove delivery; these application JSONL records provide the bounded
delivery evidence. Native submissions still are not physical receipts. There
was no activation/receipt timeout. This closes the current-build short two-app
drag and unheld external-focus cases, not sustained performance, keyboard/IME
candidate/commit behavior, or the full integration checklist.

Evidence uses `fortyninth`, `fiftieth`, and `fiftyfirst` in the owned harness.
Tasks 48–51 were unregistered after Ready/no-staged-process verification.

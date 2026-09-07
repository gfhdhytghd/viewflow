# Window-scoped input integration status

## Live reconnect harness ready; reconnect20 ended before fault injection

The new bounded `tools/udp_fault_relay.py` forwards one loopback client to one
explicit test UDP peer and drops both directions once on SIGUSR1, without
changing system networking or replaying packets. Its real-socket test verifies
loss, recovery, exact-client isolation, non-repetition and clean process stop.
The reconnect20 runner requires two distinct presenter processes under one
receiver and fresh down/up confirmations in each stage; it cannot count old
log totals as recovered input.

The first live run ended before its first button: Linux reported native
authorization revocation with `reason=LocalKey`; Windows reported that the
preview was no longer the exact active target. Five frames were sent and ACKed,
but there were zero button events and no completed recovery stage. The relay
reported `fault_used=false`, zero dropped packets, and 169/63 forwarded packets.
This is not a reconnect failure or success: no outage was injected. Local-input
revocation/target checks were not bypassed.

Receiver 1548, presenter 20552, relay 1857583 and probe 1858015 were reaped;
the collector verified no diagnostic process/port, removed its task and restored
Deskflow. Linux restored the managed plugin, removed its owned input socket
directory and had no configuration errors. Evidence and exact guarded runners
are in `/tmp/viewflow-button-live.ro1yLl/*reconnect20*`.

## Clock-liveness recovery admitted only without unconfirmed input

Clock probe timeout now retains a dedicated typed cause. After checked input
retirement, it can explain a paired local media close and permit the opt-in
retry loop to rebuild the connection. Unclassified media errors and cleanup
failures still reject retry. Plain timeout strings and standalone local closes
cannot select this path.

Both source native operations and preview-side pending confirmations expose
their unconfirmed state to the shared dispatcher. If a probe times out while an
operation remains unconfirmed, an explicit terminal marker blocks recovery;
probe-task selection cannot silently promote a pending native input failure.
Accepted native replies/preview confirmations clear the state; rejected replies
do not. Existing input-event deadlines are unchanged.

Linux passed 318 native-library tests with six hardware tests ignored, including
the real socket clock-timeout/revocation case and the retry classification cases.
Windows passed 14 pointer and 72 coded tests and Release build. Native-library
Clippy and Linux Release build passed. Live GPU reconnection on this new policy
is still unverified; heldstop19 below used the preceding policy revision.
Current Linux source SHA-256:
`3d4194cb94b624997e715afa2545471ecebb140e3c74716a64eb655094bd6984`.

## Current-binary live held-button source-stop passed (heldstop19)

On the current Linux source (`03ae79ae…9ca8db3`) and Windows receiver
(`c74f711e…616ee83`), a real Windows preview press reached the dedicated Wayland
probe. While its latest state was `held=1`, the harness sent SIGTERM to the exact
owned source PID 1767749. The source reported requested-stop retirement returned,
preserved both media/input errors, and did not report a cleanup failure.

The probe recorded one down at 180171548 ms and one cleanup up at 180171688 ms,
ending `held=0`. The 140 ms span includes the harness's intentional 100 ms hold
and is not a measured signal-to-release latency. Windows confirmed one down and
zero forwarded ups; receiver 8800 and presenter 20664 exited without a harness
kill. Windows-local button release occurred only after their exit, so it cannot
explain the probe's release. Source media recorded 87 sent / 86 ACKed frames.

The Windows collector verified no diagnostic process/port, removed its own task
and confirmed Deskflow Running. Linux restored the managed capture plugin,
removed its owned native socket directory, reported no configuration errors and
reaped probe 1765445. Evidence is in `/tmp/viewflow-button-live.ro1yLl/`:
`sender-heldstop19.{stdout,stderr}`, `probe-heldstop19.jsonl`,
`receiver-heldstop19.{json,stderr}`, and `native-heldstop19.json`.
This repeats held-stop acceptance with the new checked input-task join and typed
errors; it is one successful stop, not active reconnect or sustained gesture
latency acceptance. The earlier persistent18 missed-up failure remains open.

## Native-input disconnect causes retained without retaining the old route

The source input wait/delivery paths now retain the typed QUIC close reason
instead of replacing it with a string. Native ACK deadline checks still run
before consuming a ready reply or accepting transport recovery. A new real-mTLS
plus Unix native-socket fixture disconnects during native BEGIN, verifies the
typed application-close cause and observes EOF after session destruction.
The confirmed-press disconnect fixture now also checks the typed cause as well
as native-route EOF. All 18 input-runtime tests passed. These fixtures use a
test native endpoint, not a compositor, and do not prove physical button release
or a newly authorized live session after reconnect. Application closes remain
terminal under the retry policy.
Linux `native-gpu-nvenc` library tests passed 317 with six hardware tests ignored;
Clippy and Release build passed. The rebuilt binary's reconnect-backoff process
smoke stopped SIGINT/SIGTERM in 2.329/3.085 ms, preserving the error and completing
retirement (no native input was started in this smoke). Source SHA-256:
`03ae79aec39b321e8d53a5313d34ea97de2a6165f2ba4c445de6459819ca8db3`.

## Automatic replacement after established-connection timeout verified

Linux source and Windows receiver tests now drive the actual
`run_reconnecting_until_shutdown` owner, not just its error classifier. The first
authenticated connection opens a control stream and expires through negotiated
idle timeout; the owner waits its 250 ms backoff and handles a second, distinct
connection on the same bound endpoint. An explicit application close on the
second connection returns a terminal error with exactly two attempts and no
pending retry. Tests stop before clock/geometry admission, so no GPU or input
session is created and this does not prove live-session recovery.

Linux passed 75 coded tests and library Clippy with warnings denied. Windows
passed 14 pointer and 71 coded tests, including automatic receiver replacement,
and Release build. The architecture entry-point description now reflects the
implemented opt-in reconnect rather than describing it as wholly absent.

## Real QUIC idle-timeout error propagation verified

`TransportError::source` now exposes its typed underlying network/codec errors.
Previously control-channel failures hid the QUIC cause, so the reconnect policy
could not recognize them. A real authenticated loopback test establishes a stream,
reads one byte, retains both peers and lets the negotiated 500 ms idle timeout
fire. Both the media stream I/O error and `receive_control` error qualify as
transport failures, including their combined result; a cleanup-failure marker
still rejects retry. No test-harness close creates this timeout.

Linux passed 74 coded tests, 47 transport unit tests and native-library Clippy
with warnings denied. Windows passed 14 pointer and 70 coded tests, including
the real idle-timeout test; its Release build passed (16 existing unused-code
warnings). Receiver SHA-256:
`0ac40512a4c0aee416557140d5bf86f2a70db43504575125b26f325df3b6776a`.
This verifies error propagation and retry admission,
not creation of a replacement live GPU/input session or restored held-input state.

## Opt-in admission reconnect implemented; live recovery remains open

`--persistent --reconnect` retries classified admission timeouts and direct
QUIC reset/idle-timeout errors after checked retirement. One endpoint is retained
but each attempt rebuilds connection-local state. Backoff grows from 250 ms to
five seconds, is interruptible by stop signals, and cancellation fences the
owner even during backoff. Native input errors, cleanup failures, policy closes,
TLS/protocol errors and unclassified failures remain terminal.

Linux tests cover endpoint reuse, interrupted/cancelled backoff and conservative
classification (312 native tests passed, six hardware tests ignored). The real
process smoke test with `--reconnect` waits for two failed admissions against
its own UDP blackhole and verifies a single source port per process. SIGINT and
SIGTERM stopped backoff in 3.600/3.253 ms while preserving the last error.
Windows passed 14 pointer and 67 coded tests and the Release build. The isolated
console smoke passed ordinary Ctrl-C/Ctrl-Break (5/5 ms) and reconnect backoff
Ctrl-C/Ctrl-Break (10/4 ms), preserving the last error and completing retirement.
An initial direct-SSH smoke timed out in both ordinary and reconnect mode:
the controller inherited the independent Ctrl-C ignore flag. Explicitly clearing
that flag before child creation made the direct-launch reconnect test pass;
the helper owns and reaps timed-out children. This is a harness correction,
not evidence of a reconnect implementation defect or of active-input recovery.
Windows receiver SHA-256:
`86c49b847aa583ed1926bb599bf67aaa6e162f60414159ea6e5ba2f5ea6a0f26`.
These tests never reach GPU/input admission. Active-input reconnect policy,
actual GPU reconnection and the complete per-device atlas model remain open.

Follow-up: combined media/input failures now retain both typed causes rather
than formatting away the media cause. Retry requires both causes to be classified
transport errors; a native ACK timeout, frame invariant failure, or cleanup
failure on either branch prevents retry. QUIC read/write connection-loss causes
wrapped in `std::io::Error` are recognized by type, never by message or I/O kind;
stream resets, stopped streams and local connection closes remain terminal.
Linux passed all 73 coded tests with `native-nvenc` and library Clippy with
warnings denied. The Windows test/build script and Release build passed on this
revision. Live native-input recovery remains unverified; the hash and earlier
process-smoke evidence above describe the preceding policy revision.
The current Windows reconnect-backoff smoke passed Ctrl-C/Ctrl-Break in 6/5 ms,
with checked retirement and original error retained; no diagnostic process
remained. Current receiver SHA-256:
`b46a01a15a34ebb1075bc8df2ae906c9a9e1501cfd8ea91a2ed19a93afc83515`.

## Input-task errors now survive media connection closure

Both source and receiver previously discarded the input task's returned error
during retirement. They now allow a bounded orderly join and retain the input
error and its underlying cause alongside the media error. Task panic or forced
retirement after a 250 ms join timeout remains a distinct cleanup failure and
fences the media owner. All native input-event deadlines remain unchanged.
The source retains its join handle across await so cancellation of shutdown
still reaches its abort-on-drop fallback rather than detaching a live task.

Tests cover error provenance, ordinary completion, panic, timeout with observed
task destruction, and cancellation of source stop. Linux native library tests
passed (309 passed, six hardware tests ignored), as did Clippy and Release build.
Windows passed 14 pointer and 66 coded tests and Release build. Linux process
SIGINT/SIGTERM smoke tests still pass before native admission. Current hashes:
sender `c1fce133cc8cd24b2b26654ed3fee8f9fcbb8bb21c91d3dd1b1c780e3005ae81`;
receiver `8BAA64500F68332F0ED869C739826D9F1051EAD157AC5BF843B735B6227DBE93`.
The changed join path has not yet repeated the live held-stop test, and this
does not implement automatic retry or close the sustained-input failure below.

## Persistent18: render-pre servicing observed, 40-gesture gate still fails

With the render-pre servicing addition, the persistent trial sent and
acknowledged 808 frames, with two pre-encode stale drops and no receiver frame
rejections. Source motion spans 13,604 ms. Confirmed totals were 39 downs and
38 ups, not 40 complete gestures. Native sequence 139 was successfully serviced
with `dispatch_origin=3`, proving the new path actually processed a button.

Sequence 141 (the 39th up) still timed out: native receipt was
177935607097340 ns versus deadline 177935593060270 ns; the preceding dispatch
ended at 177935525735253 ns. It was rejected (`sent=false`), and the source
probe's final 39th up was cleanup, not an accepted event. Probe held state ended
at zero. The additional render-pre opportunity therefore does not establish a
complete latency fix. Diagnostic tasks/processes/ports were cleaned, Deskflow
restored, and temporary plugins/probe retired. Sustained acceptance remains open.

## Held source SIGTERM exercised with live GPU/input; long-run gate separate

Heldstop16 failed before a confirmed motion or held button: native sequence 2
was read roughly 88 ms after the source wrote it, by the watchdog, and was
rejected as expired. No test SIGTERM was sent, so this is not shutdown evidence.

The plugin now also services the existing bounded input drain before render
reconciliation (at most once per four-millisecond reconciliation interval).
FD readiness and the watchdog remain enabled; permission checks, original
deadlines and the 64-command drain cap are unchanged. `RenderPre` is diagnostic
origin 3. This additional servicing opportunity is not proof of the underlying
cause of missed/delayed FD callbacks. Plugin build and all five CTests pass;
the plugin hash is
`31ec749f2d7e6a7a63f47ce775b6ead8b12e61760ceb384345ba3fa61705facf`.

Heldstop17 then verified an actual SIGTERM while the Linux probe reported
held=1. Windows confirmed one down and no forwarded up. The source probe
observed a cleanup up and final held=0, and the source logged that checked
attempt retirement returned without a cleanup-failure marker. Windows reported
`receiverExitedWithoutKill=true`, waited for presenter exit, and recorded no
harness errors. Sender totals were 87 sent / 86 ACKs at intentional shutdown.
No synthetic Windows up could traverse the already-exited receiver. This proves
one live held-input source-stop path, not sustained multi-window reliability.
Both trials restored Deskflow, cleaned diagnostic tasks/ports/processes and
restored the managed capture plugin; probe processes were terminated explicitly.

## Process stop signals wired and tested before native admission

The native media entry point now installs Linux SIGINT/SIGTERM and Windows
Ctrl-C/Ctrl-Break handlers before starting the attempt. Listener setup errors
prevent startup; listener termination requests checked shutdown and remains an
error. The original attempt result is not suppressed, so these transport-close
tests intentionally exit with code 1 after retirement returns.

`tools/test_native_media_shutdown.py` ran the actual Linux Release process
against a bound loopback UDP blackhole: SIGINT stopped in 2.040 ms and SIGTERM
in 2.816 ms. `tools/windows_media_shutdown_smoke.cpp` compiled with MSVC
`/W4 /WX` and created its own isolated console plus an idle receiver: Ctrl-C
stopped in 7 ms and Ctrl-Break in 6 ms. No user console received either event.
An earlier Windows harness omitted the required presenter argument, causing
early child exit; that failed run was not signal-path evidence. The corrected
harness verifies the child is still running before delivering the event.

Linux native tests passed (305 passed, six hardware tests ignored), Clippy
passed, and Windows passed 14 pointer plus 63 coded tests. Both Release builds
passed. Current sender hash is
`54fa3ca0f591fe93e3c06e1b5354085acea25ff2fa34b0a2348556d4a4a8148b`;
receiver hash is
`E85D05BAFC14BE187CF309D6B5885B11DA28F60C2E905698A8A97DDE640D273C`.
These checks stop before capture/presenter/input admission and do not prove
live GPU shutdown, held-input release, reconnect, or the full per-device model.

## Explicit owner shutdown API added; live GPU shutdown unverified

The media owner can now drive an attempt with a caller-owned shutdown future.
Stopping closes transport and awaits checked retirement instead of cancelling
the attempt, retains the original error, and permanently fences the endpoint.
Linux native-feature library tests pass (305 passed, six hardware tests ignored),
including handshake wakeup and preservation of delayed cleanup failure.
This is a library lifecycle step, not automatic reconnect, a wired daemon stop
signal, sustained input acceptance, or the complete per-device atlas runtime.

## Native readable-source regression checked; live stall cause still open

The socket integration test now uses a real Wayland event loop, with no tick
or watchdog: 256 queued drain-to-EAGAIN cycles and 32 delayed writes waking
blocking dispatch all preserve command sequence and connection ownership.
All five native plugin CTest targets pass. This tests the socket/readable
boundary, not compositor scheduling under GPU load or registration replacement.
No native timing budget, watchdog interval or live plugin was changed.

Persistent15 sequence 85 reached the plugin at 176085742147354 monotonic ns,
after its 176085741872656 deadline; it was rejected without sending input.
The previous input dispatch ended at 176085625778877. These timestamps do
not establish whether the compositor stalled or readiness registration was
lost. The existing readable handler is registered independently of the 100 ms
watchdog; reducing the watchdog interval is not yet an evidence-backed fix.

## Persistent14/15: publication gap no longer observed; native ACK still fails

Persistent14 used the publication-gap fix and confirmed one down/up before
the sender retired: GPU output transfer finished 59,200,551 ns past deadline.
The native call and both output copies had completed successfully. Recoverable
encoding now returns that completed coded output to the existing sender
freshness gate, which drops stale output and requests an IDR; it is not
misclassified as pre-NVENC clean expiry. Legacy encoding still rejects it.

Linux serial native-feature tests passed (302 passed, six hardware tests
ignored), and library/example Clippy passed. A parallel suite run had one
lease-revoke deadline failure; no deadline was increased to make it pass.
Sender Release hash is
`aabbf3a373f7de3b662c023323cb3260e55738108334fc1e5939a9cc6755a813`.
Windows receiver remains
`C5E255EA0ABF0FD72BF2F2090312ED3B0A2A5400F5D408736851E6DEE7015FC5`.

Persistent15 sent and acknowledged 516 frames. Exactly 23 downs and 23 ups
were confirmed, matching source probe counts with final held=0; motion spans
8,403 ms. The 24th down was not confirmed: the source's native Pressing
operation (generation 3, sequence 85) timed out after 25,027 us. The preview
then closed and the test's exact-target guard stopped input. Neither the
publication gap nor output-transfer expiry recurred, but this is NOT a
40-gesture pass and does not prove sustained reliability or full-plan completion.
Both trials verified diagnostic process/port/task cleanup and Deskflow restore;
source probes exited and temporary plugins were unloaded.

## Publication-gap input fix: regression coverage, live acceptance pending

The persistent13 failure is reproduced by a unit test: presenter completion
temporarily clears the preview watch before validated publication, while an
already verified FIFO button event can still be queued. The input owner now
defers that event until a valid visual is published, retaining its original
frame, sequence and deadline. It does not admit events against `visual=None`.
Expiry, geometry changes, owner closure and authorization renewal still reject
the operation; waiting allocates no outgoing input sequence.

Linux native-feature library tests passed (301 passed, six hardware tests
ignored). The 40-gesture persistent live trial has not yet been rerun with
this change; neither persistent input acceptance nor the full plan is complete.

## Persistent lifetime added; live trial exposes another input-context gap

Explicit `--persistent` mode separates the startup deadline from the live
connection lifetime. `--timeout-ms` still bounds startup and individual waits;
per-frame freshness/ACK deadlines are unchanged. Linux passed 61 coded tests
and native library/example Clippy; Windows passed 60 coded tests and Release
build. Sender hash is
`34d47e27c7b1b690141cbc6b28e033cd1bb4da5da559ff01c46194ea369732a7`;
receiver hash is
`EEAE65B692287CBDD96A49833ECDF2B5318759D31BB64BF60B7A814BC7C645BC`.

Trial persistent12 used a five-second budget but both peers timed out before
handshake, with no frames/input. After verified cleanup, persistent13 waited
for the exact receiver's UDP port before starting the sender. That trial
produced 304 sends / 302 ACKs / one recoverable rejection. Probe motion spans
5,148 ms, and the receiver's final input error is at 6,008,744,450 session ns;
the connection therefore ran beyond its five-second configured budget rather
than terminating at a total-session cap.

The 40-gesture trial did NOT pass: confirmed totals were 13 downs / 12 ups.
The rejected up reported `visual=None`, with authorization and verified sample
both at frame 323 and an unexpired sample deadline (6,038,410,510 ns).
The probe recorded 13 downs / 13 ups and final `held=0`; native history ends
at the thirteenth down, so the final up is disconnect cleanup, not an accepted
thirteenth gesture. This localizes a presentation-state publication/retirement
boundary for investigation; it does not establish the root cause yet.

Both trials restored Deskflow, removed diagnostic processes/ports/tasks,
restored managed HyprCapture and unloaded temporary plugins. Exact probe
processes were terminated. Persistent media and input acceptance remain open.

## Receiver retirement checked; endpoint reuse after presenter failure tested

The receiver now awaits its input task and explicitly retires the presenter on
every post-spawn result. Retirement verifies child exit and joins writer/stdout/
stderr threads, caching either success or failure. A thread panic, child-retire
failure or poisoned child lock is not silently treated as success. Missing
startup pipes also trigger checked child retirement. `NativeCleanupFailure`
survives an accompanying transport failure and prevents owner reuse.

Windows passed 57 coded tests, including a real-loopback two-connection test
that deliberately starts an incompatible test child, verifies cleanup and
reuses the same receiver endpoint. Child/pipe tests cover already-exited and
running children, idempotent shutdown, and cached worker-panic failure. They do
not use the GPU presenter or prove cross-host visual recovery. Linux passed
58 coded tests and the full native-feature library suite (296 passed, six
hardware tests ignored); library/example Clippy passed with warnings denied.
Both Release builds passed. No process remained in the dedicated Windows test
directory after the tests.

Sender SHA-256:
`6cc830fd4368aaeca8b879a7a3237f2df44125e31b4d86e46dff8fe23df611af`.
Receiver SHA-256:
`5385D6A7B753EDF36E8B6A743456D556DCACD8E641B2CA549FAA3A5C69139562`.
Presenter/input-plugin hashes are unchanged. Automatic retry orchestration,
long-lived GPU/atlas ownership and live recovery acceptance remain open.

## Retained media endpoint implemented; native reconnect acceptance remains open

`NativeMediaPeer` separates endpoint ownership from sequential connection
attempts. Source and receiver loops now retire their connection rather than
closing the shared endpoint. New source attempts reconstruct clock, codec,
presentation and native-input state. A real mTLS loopback test runs two failed
pre-capture connections from one owner/bound address. A second test cancels a
pending attempt and verifies the owner rejects reuse without incrementing its
attempt counter. Capture-stop failure fences reuse; receiver errors remain
fenced pending an explicit presenter-retirement result.

Linux passed 54 coded tests and the native-feature library suite (292 passed,
six hardware tests ignored), plus library/example Clippy with warnings denied.
Windows coded tests and Release build passed with platform-unused-code warnings.
New sender SHA-256:
`d38786664cedba89436741f91c0e933cd72a9608face65322d6756e4ac0deac5`.
New receiver SHA-256:
`9BEB683D8EAB531EB441A1BB5ADEBB197D74909164590A2B50E089688C130340`.
No live media trial has exercised this lifecycle change yet. This is not
automatic window recovery, retained proxy/atlas state, or daemon integration.

## Shared native-runtime extraction built; previous live results are historical

The native implementation and tests moved from the example into
`crates/viewflowd/src/coded_peer.rs`; the example delegates to the library.
Linux native-feature library tests passed (290 passed, six hardware tests
ignored), including all 52 coded tests. Windows passed all 51 coded tests.
Both Release examples built. Linux library/example Clippy passed with warnings
denied; Windows still reports existing platform-unused-code warnings.

New Linux sender SHA-256:
`07a1f69b51c37d79b8a4893f8d87bed37e7d7eb6abfb925589928f9735a2621c`.
New Windows receiver SHA-256:
`3E9CB4E7796E392021B55443FB8CD0DF01B7BFC6CA571E8DA33115E24128C2C3`.
Presenter and input plugin are unchanged. This extraction has not yet had a
live cross-host trial. It enables reuse, but does not implement the persistent
window owner, reconnect orchestration, or atlas.

## Held-disconnect11: current-build autonomous button release verified

On the same binaries as nativeclock10, the Windows harness confirmed one down
and zero ups, then forcibly ended its exact receiver and presenter processes.
It reported no errors. Before unloading the Linux input plugin, a separate
probe snapshot contained one down, one up, and final `held=0`. Thus plugin
unloading and a forwarded Windows up cannot account for this release. The
Windows-side owned button was separately released only after the receiver and
presenter had exited.

Probe event times were 172748685 ms (down) and 172749081 ms (up), a 396 ms held
interval. This is not a synchronized kill-to-release latency measurement.
The source reported clock-probe 7 timeout after the deliberate process kill;
87 frames were sent and 86 ACKed before shutdown. This closes this bounded
current-build abrupt-disconnect release case, not reconnect, repeated-failure,
or latency acceptance. Cleanup restored Deskflow and managed HyprCapture and
verified diagnostic process/port removal; the exact probe was terminated.

## Nativeclock10: full 40-gesture trial passed on the instrumented plugin

The `61ad1709...22e3659` plugin, `303CF89F...D740422` presenter, and
`2C7BFCE8...833C60B` receiver completed 40 confirmed downs and 40 confirmed ups
with 61 confirmed motions. The independent Wayland probe also recorded exactly
40 downs / 40 ups and ended with `held=0`. The Windows harness reported no
errors. Retained native history includes generations 3 and 4; all retained
commands were serviced by readable dispatch. This demonstrates interaction
across renewal, but does not resolve the intermittent nativeclock9 dispatch gap.

The source sent 833 frames and observed 832 ACKs before the harness ended the
receiver after its successful gestures. Two frames expired during clean encode;
none were stale at post-encode or dispatch. The source then reported clock probe
59 timeout / closed connection. This is not a clean sustained-media completion
and is not counted as one. The Windows harness's gesture result and independent
probe establish only this bounded input pass.

Cleanup verified no Windows diagnostic process or port, restored Deskflow,
restored managed HyprCapture, unloaded temporary Linux plugins, and terminated
the exact probe process. Repeat/disconnect and outside-window/geometry cases,
as well as the remaining product requirements, still need acceptance.

## Empty-dispatch history instrumentation built, not yet live-tested

Pointer timing records now include the preceding InputCapture dispatch's start
and completion, including dispatches that read no command. This closes a gap in
the command-only history: a long inter-command interval alone does not establish
whether the event loop was idle, delayed, or continuing to service callbacks.
The preceding interval is diagnostic only and does not authorize an event or
extend a deadline. The plugin build and all five CTests passed, including JSON
serialization of zero/default and explicit prior-dispatch timestamps. Runtime
verification with this new plugin is still pending; nativeclock9 used the old
plugin and cannot supply these fields retroactively.

## Nativeclock9: 25 confirmed gestures, then Linux readable-dispatch gap

The new `303CF89F...D740422` presenter and `2C7BFCE8...833C60B` receiver
completed 563/563 coded-frame ACKs with no receiver late/timeout rejection.
The trial confirmed 25 button downs and 25 ups, with 38 confirmed motions,
before generation 3 / sequence 92 (the next press) timed out at the source.
The Wayland probe ended with `held=0`; the rejected press was not delivered.

Source send completed at 172295682097887 ns. Native read occurred at
172295764249085 ns, about 82.15 ms later, through watchdog dispatch (origin 2),
not the readable-FD callback used by preceding events. The original deadline
was 172295711924251 ns; native result was rejection, with no reply delivered
after the source had already closed. This localizes this failure before native
command processing, not to Windows presentation or reply transmission. It does
not yet explain why readable dispatch failed to service the socket promptly.
Increasing the acknowledgement timeout would not make this expired press valid.

The Windows harness attempted 26 downs / 25 ups and stopped when the preview
ceased to be its exact target. Its cleanup restored Deskflow and verified no
diagnostic process/port remained. Linux restored managed HyprCapture, unloaded
temporary plugins, and terminated the exact probe process. This is partial
live evidence, not completion of the intended 40-gesture trial or full plan.

## Native delivery timestamp build verified; live timing diagnosis pending

The Windows presenter now records monotonic QPC timestamps for the latest
compressed chunk's ReadFile completion, UI-thread take, and flushed frame ACK.
These diagnostics distinguish queue residence from the existing decode and
composition timings; they do not change the media deadline or input admission.
The chunk timestamp test checks that completion is positive and no later than
the consumer observation. Clean Release build and all 12 native CTests passed
on Windows. Presenter SHA-256 is
`303CF89F176ECAC54B945219940D017BB307F6D104EF1F622715CE9E0D740422`.
Receiver remains `2C7BFCE8...833C60B`. This presenter has not yet been exercised
in a live cross-host trial; the previous ACK stall remains unresolved.

## Windows publication-queue build verified; live run hit an earlier media gate

The updated receiver was built in the dedicated Windows test directory after
verifying no diagnostic process or port was active. All 51 Windows example
tests passed. Receiver hash is
`2C7BFCE85FC1ABF060D0F0663AD9F98699430702D002F43A5F56D9B56833C60B`;
native presenter remains `3BD892E4...742E5`. Example source hash matched Linux
(`c374ef7935d03b19fbfe71e8afb74e5317ff48688562c2d0c7e663792ba79a1a`).

`ro1yLlnativeclock8` ended before button gestures. Frame 26 failed with
`coded frame became late after presenter ACK`: pre-write budget 27,968 us,
write 27 us, write-to-stdout 41,411 us, stdout-to-notify 10 us and
notify-to-resume 51 us (total 41,518 us). Native reported decode pipeline
2,109 us and composition submit 447 us. These cover different boundaries;
their difference is not by itself proof of a particular blocked operation.
The run had 13 sent/12 acknowledged frames and zero clean expiries. Final
motion confirmations reached one, but the harness did not observe readiness
before exit; no button was sent. This does not accept or disprove the queued
publication fix under its intended button race.

Logs/query/probe are the `nativeclock8` files under
`/tmp/viewflow-button-live.ro1yLl`; receiver/presenter/probe PIDs were
20340/24252/1074743. Process/task/port cleanup, Deskflow restoration, managed
capture restoration and private input directory removal passed. No held
button remains. Next compare full native admission/queue/ACK timestamps for
the 41-ms interval without relaxing the freshness requirement.

## Pending-publication ordered queue implemented, Windows runtime pending

Ordered pointer events for the exact currently presented but unvalidated frame
are now held in a 64-entry queue. Writer publication drains it under the same
state lock only after matching full-tag validation. Original event deadlines
and order are preserved; no retagging or deadline refresh occurs. Replacing
a frame with pending transitions closes the event route and clears pending
state rather than silently losing buttons. Closing the presenter also clears
the queue. Motion-only watch behavior remains unchanged; historical events
during a publication gap are still rejected by the existing checks.

Two new regression tests cover down/motion/up deferral without pre-validation
forwarding, final ordered publication, deadline retention, queue capacity and
replacement/close cleanup. All 52 native-feature example tests and Clippy pass.
Linux release hash:
`1142f82c08d31c5c65df162fc207fe4ed852a1dec4aededf5369a08aa07c63b1`.
Windows has not yet been rebuilt/deployed; the fix is not a live acceptance
claim and must be exercised against the original release-route failure.

## Release-route error originates in Rust publication gate

The `button has no ordered route or published frame` string is emitted by
`record_presenter_pointer_event` in the Rust receiver, not by the native C++
presenter. `record_presenter_completion(Presented)` clears published_presented
before writer-side `publish_presenter_input_frame` validates the full tag.
Unlike motion, a button in that interval is immediately rejected. This is a
real publication gap in the current code; the old live error lacked the event
frame/state fields needed to distinguish this gap from a closed ordered route.

The error now includes event/latest/published identities, route presence,
retained-history membership and pending-motion identity. Fifty native-feature
example tests pass and Linux sender rebuilt as
`795a39b1f2f50d330b1f50ae73a6312bb5612b4bbc1533b948e24fd433b521b8`.
Windows has not been rebuilt/deployed with this change. A fix must preserve
validation: bounded ordered deferral for an exact pending frame, original
event deadlines, and failure/close cleanup—not forwarding an unvalidated tag.
Historical-event handling during the gap also needs explicit tests.

## Controlled hardware expiry recovery and continuous GOP decode passed

A test-only build flag injects a one-shot expired predicate after each of the
two GPU preparation synchronization points. In the real DMA-BUF/EGL/CUDA/NVENC
fixture, both points return EXPIRED_CLEAN with null output; the same encoder
then emits the next P frame and the requested IDR. The resulting IDR/P/IDR
access units are continuously decoded with expected frame count, color/VUI
and keyframe checks. This proves the native/C ABI cleanup-and-reference-chain
recovery branches under controlled expiry, not real-time latency performance.

All six tests pass with `VIEWFLOW_TEST_GPU_EXPIRY=ON` in
`/tmp/viewflow-nvenc-error-check.e6qlJj`; hardware integration took 0.78 seconds.
The flag defaults off and requires BUILD_TESTING plus the GPU encoder. Cargo
explicitly forces it off. Symbol inspection finds the injection entry point
in the test executable and not in the release sender, whose hash is
`04b37e31a2083ef40b579fb8154ae6141f101565f3ad6e9365892b2f36e39f90`.
Release operation has no runtime expiry-injection setting. Rust lease/input
mapping behavior and sustained live interaction still need end-to-end proof;
the presenter release-route failure is a separate open issue.

## First recovery-enabled live run did not exercise clean expiry

`ro1yLlnativeclock7` used sender `da4b5bd5...09f35c`, plugin
`fec0ad52...90d87b`, and the unchanged Windows binaries. It sent and received
213 frame acknowledgements with `clean_encode_expired=0`; this is not evidence
that the recovery branch works. The eighth drag release failed in the native
Windows presenter: `button has no ordered route or published frame`, followed
by native preview owner disappearance and peer closure. The receiver confirmed
eight downs/seven ups; native Linux cleanup released the held button at
171221222 ms and ended with held=0. Native command records end at successful
move sequence 30, not an acknowledged normal release.

Receiver/presenter/probe PIDs: 4764/23076/1020610. Evidence is in the
`nativeclock7` files under `/tmp/viewflow-button-live.ro1yLl`. All test processes,
VM task/port, temporary plugins and private socket directory were cleaned;
Deskflow and managed capture were restored. A controlled native hardware
expiry-plus-next-frame test is still required, alongside investigation of
the presenter release-route failure. Random live runs with zero expiries
must not be used as recovery acceptance.

## Clean expiry wired through adapter and steady-state sender

The adapter's opt-in submit returns explicit Encoded/ExpiredClean outcomes.
Clean expiry consumes source sequence/timestamp but preserves pending IDR and
the alpha cache; it does not pass through output adaptation. A regression test
executes this production completion branch with both pending-IDR states and
checks cache/lineage retention. Generic failures still retire the adapter.

The diagnostic's steady-state GPU sender now opts in, releases the exact
completed-read capture lease, removes its abandoned input snapshot, increments
`clean_encode_expired`, and skips transmission without changing IDR recovery
state. CPU submission and warmup retain the legacy path. Null/empty coded
output is not used as a generic recovery signal: only the typed clean-expiry
outcome reaches this branch.

Six adapter tests and 50 native-feature coded-peer tests pass. Library/example
Clippy passes with warnings denied, and release sender hash is
`da4b5bd5a200fd472116c728e57ad56f5e88ab544abdc4b7d3d860ff3b09f35c`.
Recovery is now implemented but not accepted: a real clean-expiry outcome
followed by a valid next frame, preserved reference chain and input operation
still requires hardware/live verification. The prior input scheduling delay
and other full-plan integration gates remain open.

## Rust native wrapper exposes explicit clean-expiry outcome

`GpuEncoder::encode_recoverable` now returns Encoded or ExpiredClean. Only
explicit opt-in, C status 8 and null output admit the latter; any other native
error poisons the wrapper. The legacy `encode` method still uses the legacy
C entry point and cannot return a recoverable result. Neither the compatible
adapter nor sender has switched to the new method yet.

Three GPU runtime tests pass (ABI layout, pre-init resource rejection and the
44-case expiry status/opt-in/output matrix). Native-feature library Clippy
passes with warnings denied. The release sender rebuilt with hash
`82e57c01bb406c367fe7d39313345b20f6c4c60346830fef90cbbe1954591568`.
This is type/status-boundary proof, not a real expired-frame recovery test.

## Opt-in C ABI expiry extension added

`vf_gpu_dmabuf_encoder_encode_recoverable` adds status 8 (EXPIRED_CLEAN),
returned only for the explicit native ExpiredBeforeSubmission disposition.
It returns null output without marking the encoder terminally failed. The
legacy encode entry point still terminally fails on the same expiry, and all
other failures retain the existing retirement path. Struct layouts and old
status numbers are unchanged. Rust still calls the legacy entry point.

All six native tests pass, including null-argument checks for the new symbol
and an alternating legacy/new entry-point hardware GOP test (0.87 seconds).
These verify successful-path compatibility, not the new expiry recovery
branch. Sender rebuilt as
`c3cd7fe71880d26addffef14c904b2fd09db22974c882905d1f7de8e02f04a3b`.
Rust ownership/lineage integration and deterministic safe-expiry-plus-next-frame
tests remain required before recovery can be accepted.

## Native disposition introduced; end-to-end recovery not yet enabled

The C++ encoder has an optional typed disposition, initialized to Failed on
every call. Only the two post-synchronization, pre-NVENC deadline branches
may report ExpiredBeforeSubmission, and only after checked import cleanup
succeeds. Encoded is reported only after final cleanup succeeds. Output is
cleared at call entry, so rejection cannot leave a previous coded frame.
The boolean return remains false for expiry. Existing C ABI callers do not
opt in and continue to terminally retire on all false returns.

Six native tests pass, including hardware checks of successful disposition
and rejection resetting a stale disposition/output. The narrow completed-read
expiry branch is not yet deterministically exercised. Release sender hash:
`cf83c248383498e75f60e917c012bf869eae6b22bcc39d4b70a9cf41edb1c8be`.
Remaining recovery work: opt-in C ABI, Rust typed outcome and adapter lineage,
exact source-lease release, removal of abandoned input-frame mappings, and
fault/expiry-plus-next-frame tests before a new sustained live trial.

## Cleanup decision fault matrix verified

The production cleanup sequence now calls `cleanupImportedImage`, whose
unmap/unregister/image-destruction callbacks are fault-injected in a standalone
test. The matrix covers all eight resource-state combinations, all eight
failure combinations, with and without an error sink (128 cases), plus empty
error formatting. It verifies order, skipped nonexistent resources, attempts
after earlier failures, preserved original errors and failure return values.
These are callback-level tests, not injected NVIDIA driver failures.

All six native CTests pass, including the real DMA-BUF encoding integration
test (0.81 seconds). Native-GPU sender rebuilt with hash
`939201a0dbefc6d2be65d12ce77293ca4fd9edfda2105254f8c5d8e367f0e520`.
The new header is tracked by Cargo's native rebuild dependency list. Recovery
still requires a distinct verified-safe expired outcome; generic encode
failure remains terminal and cannot be reused as a dropped-frame signal.

## Successful encode now also requires successful import cleanup

Inspection of the recovery boundary found that final CUDA unmap/unregister
and EGL image destruction results were ignored, even on the success path.
Cleanup now records these failures, attempts the remaining cleanup operations,
and poisons the encoder on failure. If cleanup fails after coding output,
the output is cleared and encode returns false, preserving C ABI terminal
retirement instead of allowing source-buffer reuse through success. Existing
failure details are retained with cleanup failure information appended.

No retry or recoverable-drop outcome was added. This is a prerequisite safety
fix, not completion of recovery. All five native tests passed, including
hardware DMA-BUF integration (0.78 seconds); they do not inject driver cleanup
failures. Release sender rebuilt with hash
`c1dfe0dcbd9208e5f3c793fb03454dc25fde43d6622f6249cb657bfe238592b2`.

## Profiled trial: genuine preparation expiry, no input-timeout reproduction

`ro1yLlnativeclock6` used sender `47461bf...ece75f` and plugin
`fec0ad52...90d87b`. GPU preparation again exceeded the deadline after 63
acknowledged frames. With the separated error branches this message now
identifies a real deadline check failure, not a CUDA error overwritten by the
deadline text. One down was confirmed; source teardown caused native cleanup
release, independently observed at 170355785 ms with final held=0. The source
did not acknowledge the matching normal up. Native sequence 4 (the down) was
successfully applied via readiness origin=1. This run does not reproduce the
earlier native ACK timeout or pass even one complete normal gesture.

Concurrent bounded perf recording used `cpu-clock:u`, 199 Hz, monotonic sample
timestamps and 8192-byte DWARF callchains against only compositor PID 2913544.
`/tmp/viewflow-compositor-profile.r5NzcA/nativeclock6.data` contains 349 samples
over the 44-second recording with zero lost samples. The 170355.700–170355.810
second window contains one CPU sample (170355.740296449), inside NVIDIA EGL
under Hyprland texture/blur rendering and monitor-frame dispatch. One on-CPU
sample cannot establish a stall, GPU dependency, or the root cause. Sampling
overhead is an additional trial condition; off-CPU waits were not measured.

Logs/query/probe evidence are the `nativeclock6` files in
`/tmp/viewflow-button-live.ro1yLl`. Receiver/presenter/probe PIDs were
27620/27988/945111. All processes and the profiler completed; VM Deskflow,
managed capture and temporary plugin/socket/task cleanup were verified.
The encoder C++/C ABI explicitly requires retiring the capture path on any
failed encode. Safe recovery needs an explicit completed-cleanup outcome or
full session retirement/recreation, not an unchecked retry of status 3.

## Control-timeout wording corrected; bounded compositor profiling available

The control reader is bounded by the lesser of remaining session time and
one second. Its old timeout text always claimed the sender session ended,
and the caller labeled every read/drain failure a timeout. These messages now
say `receiver control response deadline elapsed` and `receiver control response
failed`, respectively. Deadline and error propagation behavior are unchanged.
The previous nested message is therefore not evidence that the full 40-second
session expired. All 46 coded-peer example tests pass; native-GPU release
sender hash is now
`47461bf048e0d3ba3f56321df54493c2e984db0feae804da30e2b84191ece75f`.

A one-second, read-only perf capability check against compositor PID 2913544
succeeded. The idle baseline at
`/tmp/viewflow-compositor-profile.r5NzcA/baseline.data` contains only one
CPU-clock sample and cannot establish the failure cause. Its userspace stack
is readable through DRM commit/render/frame dispatch into the Wayland event
loop. Future failed live trials can use bounded sampling with timestamps;
CPU samples alone do not measure off-CPU waits or establish missed readiness.
Offline report generation requires `DEBUGINFOD_URLS=''` here to avoid a slow
external symbol lookup; the initial report process was terminated, not the
compositor. No desktop settings were changed by this capability check.

## Dispatch provenance live; latest trial ended on control response timeout

The input timing ring now includes `dispatch_origin`: 0=ordinary tick,
1=socket readiness callback, 2=watchdog. The enum is diagnostic-only and does
not confer authority. All five plugin tests pass, including serialization of
all three origins. Plugin hash:
`fec0ad5262b13a47ff58a9329847936fca285dc3db9ac7afc259ad0eea90d87b`.

`ro1yLlnativeclock5` used this plugin and sender `73ccc267...75bece` (full hash
below). All 32 retained native records (ending at sequence 112) had origin=1,
result success and sent=true. This proves the readiness path operated in this
run; it does not prove how the earlier delayed commands were dispatched.

This run ended after 31 gestures, with the harness reporting a confirmation
mismatch; final collection subsequently saw 31 confirmed downs and ups. The
source instead reported `receiver control response timed out`, and receiver
frame 656 was rejected late with source-age upper bound 1,006,681,979 ns.
No native ACK timeout or GPU preparation error was recorded in this run.
The eventual matching counts do not retroactively pass the harness's timing
gate or the intended 40-gesture run. Investigate this control/media pause
alongside the pre-input-tick delay without assuming a shared cause.

Evidence under `/tmp/viewflow-button-live.ro1yLl`: `native-clock5.json`,
`sender-nativeclock5.stderr`, `receiver-nativeclock5.stderr`,
`probe-nativeclock5.jsonl`. Receiver/presenter/probe PIDs were
23928/13944/921047. Native final held=0; VM task/process/port cleanup,
Deskflow restoration and temporary plugin/capture restoration all passed.

## GPU error provenance preserved; recovery still pending

The native GPU encoder now keeps CUDA unmap/synchronization, NV12 kernel,
and alpha-download errors instead of replacing them with deadline-expiry text.
Both preparation stages check the deadline separately, only after successful
GPU operations. Cleanup, failure return, admission and retry behavior are
unchanged. Thus the earlier trial's generic preparation message cannot be
retroactively classified as a genuine deadline miss or a CUDA failure.

The release sender rebuilt successfully with hash
`73ccc2671e485a15753a41153e594ef981eebb1df68d1a91af84aa35cf75bece`.
An independent native build at `/tmp/viewflow-nvenc-error-check.e6qlJj` passed
all five CTests, including the hardware DMA-BUF encoder integration test
(0.86 seconds). These tests exercise normal encoding and existing rejection
cases; they do not inject CUDA errors at each newly separated branch. A new
live trial is still needed to classify the intermittent preparation failure.
This correction does not resolve the separate pre-input-tick delay.

## Tick-entry correlation: delay precedes input tick, release cleanup verified

Native plugin `b42c4048e10bb15792842528611a633cc209b881a0581a295099092afede71c1`
adds diagnostic-only `tick_ns` and `read_ns` (CLOCK_MONOTONIC; zero unavailable),
without changing admission or dispatch ordering. Build and five CTests pass.

`ro1yLlnativeclock4` failed during the 22nd gesture's release: 22 confirmed
downs and 21 confirmed ups. Sequence 82 / generation 3 local send began at
169745529985085 ns and completed at 169745529989103 ns. Its input tick began
at 169745609239324 ns, **79,250,221 ns after send completion**. Read began
at 169745609260693 ns, and handler entry was 169745609266280 ns: tick setup
took 21,369 ns and read-to-handler 5,587 ns. The command deadline was
169745558660234 ns. Source wait expired after 24,488 us with 12 polls,
zero metadata and maximum poll gap 2,734 us. Result=0/sent=false is rejection,
not an applied-release acknowledgement. The independent client nevertheless
observed cleanup release at time 169745609 and final held=0.

This excludes device reconciliation and packet receive as the dominant delay
in this trial. It does not yet establish whether the compositor was stalled,
the readiness callback was delayed/missed, or the watchdog/tick serviced the
command. Next inspect event-source dispatch provenance or bounded compositor
profiling; do not infer the answer from the near-100-ms interval alone.

Preceding `ro1yLlnativeclock3` proved live read-back of the new fields, but was
interrupted after five confirmed gestures by GPU encoder status 3:
`frame deadline expired after GPU preparation`. This is a separate outstanding
media-path failure, not native-input acceptance. Inspect typed deadline/error
handling before deciding whether recovery is safe; the current native error
branch also overwrites some CUDA preparation failures with the deadline text.

Evidence: `sender-nativeclock{3,4}.stderr`, `receiver-nativeclock{3,4}.stderr`,
`native-clock{3,4}.json`, `probe-nativeclock{3,4}.jsonl` under
`/tmp/viewflow-button-live.ro1yLl`. Trial 3 receiver/presenter/probe PIDs:
25404/21284/886896; trial 4: 25816/25084/893210. Both trials restored VM
Deskflow and managed capture, removed temporary plugins/tasks/ports/processes,
and left no held button or private input socket directory.

## Sender/native correlation: 46.7 ms before handler entry

`ro1yLlnativeclock2` confirmed 26 click/short-drag down/up pairs before the
27th press failed (generation 3, native sequence 97). The source recorded
CLOCK_MONOTONIC send-start 169485583731835 ns and send-end 169485583736176 ns:
the local send took 4,341 ns. Native handler entry was 169485630428337 ns,
46,692,161 ns after send completion and 19,042,170 ns after the original
169485611386167 ns deadline. Handler apply/reply took 1,095/29,499 ns, rejected
the expired command, and could not send after source closure. Source ACK wait
was 24,718 us, 12 polls, zero metadata, maximum poll gap 2,120 us.

This rules out a slow source send for this failure; it does not yet distinguish
event-loop scheduling from work before handler entry. The FD callback invokes
`InputCapture::tick`, which polls authority and reconciles devices before
receiving commands. Callback/tick-entry timestamps are the next diagnostic
boundary; do not relax deadlines based on these measurements.

Evidence under `/tmp/viewflow-button-live.ro1yLl`: `sender-nativeclock2.stderr`,
`receiver-nativeclock2.stderr`, `native-clock2.json`, `probe-nativeclock2.jsonl`.
Receiver/presenter PIDs were 27536/24368; dedicated native probe was 870462.
Probe ended with held=0; VM process/port/task cleanup, Deskflow restoration,
temporary plugin removal and managed capture restoration passed.
Linux sender hash: `4f2c09e4021dd6e97987b5dad977f3c6f1510d01f8ee7081f246a8b144f8827f`.
Native plugin hash: `4c2421a2303af554eee61f3a6043639636a9be36eab1efa5cc4ddca85d8f3e69`.
The plugin includes locale-independent timing JSON and a ring regression test
covering overflow, chronological retention, maximum uint64 and repeat reads;
build and all five CTests passed. Sustained native input remains unaccepted.

## Native timing query verified: failed command entered after its deadline

`ro1yLlnativeclock` reproduced a third-gesture press timeout. Native sequence 11
entered the handler at 169065744634490 ns, after its 169065742842668 ns deadline
by 1,791,822 ns. Apply completed 1,336 ns later, reply attempt 28,882 ns after
that, with result=0 and sent=false (the source had closed). Source wait reports
25,079 us elapsed, 12 polls, zero metadata and max poll gap 2,143 us. The first
ten native commands have valid sent results; the independent client saw only
two normal down/up pairs and final held=0. This places the failed command's
delay before native handler entry, not inside button injection. Kernel arrival
and source send time were not recorded in that trial, so compositor event-loop
stall versus local delivery/queueing remains to be distinguished.

`native-clock.json` was successfully read via the new Lua query before plugin
unload. Other evidence: `sender-nativeclock.stderr`, `receiver-nativeclock.stderr`,
`probe-nativeclock.jsonl` under `/tmp/viewflow-button-live.ro1yLl`; receiver 28488,
presenter 16804, probe 835155. Cleanup/restoration passed. Native plugin hash
was `9acb33d7306713c99b63d339f0d3fbc00e95e1564e8e1cc992840940d55bde17`.

The sender now records native CLOCK_MONOTONIC send-start/send-end/deadline with
the sequence in timeout diagnostics (zero means diagnostic clock unavailable).
This does not change admission or the wire. Seventeen runtime tests and Clippy
pass; the native-GPU sender was rebuilt for the next correlation trial.

## Native handler timing ring built, live query pending

The plugin now retains the last 32 native pointer command stage records in a
fixed-size ring: handler-entry monotonic time, apply completion, reply completion,
original native deadline, generation/sequence/type/result and send success.
No file or console I/O occurs when recording a command. A read-only
`hl.plugin.viewflow.pointer_timings()` query serializes the ring on demand; it
must be collected after a trial and before unloading the temporary plugin.
Handler-entry time is not a kernel socket-arrival timestamp, so an absent or
late record must not be mislabeled as a measured kernel delivery delay.

Plugin compilation and the existing four CTests pass. The query and timing
records are not yet verified live. No deadline, reply outcome, or input policy
was changed, and the new plugin has not been loaded into the running compositor.

## Forty-gesture extension failed on the fifth native press ACK

`ro1yLllong` used the same hash-guarded binaries as the ten-gesture pass and
attempted 40 alternating gestures. Four gestures completed; the fifth press
failed at source with `command=Pressing generation=1 sequence=18 elapsed_us=24100
overdue_us=100 polls=12 metadata_packets=0 max_poll_gap_us=2127 final_state=Pressing`.
This establishes that source polling continued without a large scheduling gap
or metadata backlog, but no matching native result was consumed before 24 ms.
It does not by itself locate the delay inside the compositor/socket path.
The source client independently saw only four downs/four ups, final held=0;
the controller's fifth SendInput pair was not accepted remotely.

Evidence: `/tmp/viewflow-button-live.ro1yLl/{sender-long.stderr,receiver-long.stderr,probe-long.jsonl}`;
Windows `button-live-ro1yLllong.json`, receiver 24284/presenter 19348, probe 808444.
Cleanup/restoration verified on both hosts. The successful ten-gesture case
remains valid but sustained reliability is explicitly contradicted by this run.
Native source inspection confirms a Wayland readable-FD callback and bounded
64-command drain; next diagnosis must instrument native receive/apply/reply
timing rather than assume the source polling timer caused the failure.

## Ten live gestures passed once with history and receipt waiting

`ro1yLlhistory4` completed five clicks and five short same-surface drags on the
dedicated Wayland probe. Controller and validated native counters both report
down=10/up=10 with errors=[]. The source client independently recorded 10 downs,
10 ups, 24 held motions and final held=0. The tenth gesture used generation 2,
so this run also crossed one source lease renewal. The final up was confirmed
normally, not inferred from terminal cleanup (serial 11536, leave 11537).

Receiver SHA256 `3BED94C3CA2186FF9FB6076A6971555560E7C214D00181B43617F9CD061AAF9E`,
native `3BD892E4C9AC76BDDB88451D9C0DCFF01F6FB1AED1098DB2876D10C37BE742E5`,
Linux sender `08449c8457ab91fb5c5b558307a91858678bb352d3924e2a2bbc702373290cc8`.
Evidence: `/tmp/viewflow-button-live.ro1yLl/{receiver-history4.stderr,sender-history4.stderr,probe-history4.jsonl}`;
Windows `button-live-ro1yLlhistory4.json` records receiver 19796/presenter 11496
and completion 2026-09-05T22:43:23.4580097Z. Source video sent 269/ACKed 268;
terminal output includes clock probe 20 timeout/connection loss. The runner
intentionally terminates the receiver after all gestures, so this trial is input
acceptance for the completed gestures, not proof of indefinite video/clock
stability or a clean protocol shutdown.

Cleanup verified Deskflow Running, no diagnostic task/process/port, original
capture restored, no input plugin/socket and empty config errors. Probe 790039
was terminated after exact executable checking. Longer/repeated runs, the
separate intermittent native ACK timeout, and remaining full-plan gates are open.

## Single-event receipt wait implemented; live deployment pending

The ordered preview path now retains at most one dequeued event when its exact
presentation receipt is still ahead of the current source authorization. It
requires matching visual/window/epoch, valid current clock/lease evidence,
coordinates and the unchanged original event deadline before waiting. Subsequent
polls revisit that event before dequeuing another, while the shared dispatcher
can continue reading authorizations. It sends only after an exact receipt match.
Renewal while waiting is rejected; expiry, owner loss and overflow remain fatal
for buttons. No deadline is reset or enlarged and no new wire sequence is spent
until the event is ready for transmission.

Twelve preview tests pass, including delayed authorization with ordered down/up,
preserved deadline, expiry and renewal rejection. All 17 source runtime tests
and library Clippy pass. This change has not yet been built/deployed to Windows
or exercised in the live cross-host path.

## Confirmed receiver race: event precedes its authorization receipt

`ro1yLlhistory3` used receiver
`7D2E74C4BD37F41416BD3DA161E4029BF92F11F5B1E3D874C2CE1E6DD635C415`
and the hash-guarded native history binary. Its rejected up had visual=121,
sample=121, latest authorization=120, same window/epoch, verified=false,
now_ns=2435012260 and deadline_ns=2466889240 (31,876,980 ns left).
Thus the missing exact receipt was still in flight; the event was neither
expired nor associated with a stale visual. Current code consumes the ordered
event and fails immediately instead of awaiting that receipt under its original
deadline. The next fix must retain at most one pending ordered sample, continue
reading authorizations, preserve FIFO and generation ownership, and reject on
expiry/owner loss/renewal rather than inventing authorization or extending time.

Normal confirmations ended down=2/up=1, with cleanup up serial 11497 and leave
11498 held=0. Video ACKed 113/113. Evidence is in
`/tmp/viewflow-button-live.ro1yLl/{receiver-history3.stderr,sender-history3.stderr,probe-history3.jsonl}`;
receiver 8812/presenter 5048, probe 763814. Cleanup/restoration verified; no
diagnostic task/process/port/socket remains. Ten preview tests passed before
this run, but they did not cover delayed receipt delivery; live failure remains.

## Clean history binary live run: receiver context rejection remains

`ro1yLlhistory2` hash-guarded the current native 3BD892E4 and receiver 1425085F
binaries. Two gestures completed normally (down=2/up=2); the third button at
frame 128 reached Rust but was rejected by `button has stale or invalid
presentation context`. No native timing-retirement error appeared in this run.
The generic context message cannot establish which subcondition failed.
All 117 video frames ACKed. Probe ended held=0; all processes/tasks/ports and
temporary plugins were cleaned, with Deskflow and original capture restored.
Evidence: `/tmp/viewflow-button-live.ro1yLl/{receiver-history2.stderr,sender-history2.stderr,probe-history2.jsonl}`;
Windows receiver 19168/presenter 24332, source probe 740911.

Inspection identified an unnecessary equality between current visual frame and
latest source authorization frame. The candidate now allows their independent
advance only within the same window/epoch, while still requiring the event's
exact verified receipt and that the visual is not older than the event. A new
test covers this condition; wrong-epoch, unknown-receipt, expiry and replay gates
remain tested. Ten preview tests pass. Failure logging now includes all context
identities and deadline values to distinguish remaining subconditions. This
latest candidate is not yet built/deployed and is not a proven live fix.

## Native incremental build was stale; clean rebuild verified

Trial `ro1yLlhistory` failed before any button input with presenter disposition
timeout; controller counts are 0/0 and no button acceptance can be inferred.
The launch manifest exposed that the native EXE still had the old AEE4DB82 hash
and 18:15:45 timestamp although its changed header matched local SHA256 and was
written at 18:29:24. CMake's source root was correct; MSBuild warns MSB8029 about
incremental builds under Temp. The earlier claim that both candidate binaries
were current is withdrawn: only the Rust receiver was updated in that trial.

A clean native rebuild completed, 12/12 CTests passed, and direct execution of
the pointer test printed `PASS bounded event-time presentation history`.
Current native presenter SHA256 is
`3BD892E4C9AC76BDDB88451D9C0DCFF01F6FB1AED1098DB2876D10C37BE742E5`;
receiver is `1425085F86982ED4F13F506AEBCFBD046D38D4AC07178005744EF01B9B8DDD96`.
The temporary build harness now uses `--clean-first`. No live run of this clean
native binary yet. Trial logs are `receiver-history.stderr`, `sender-history.stderr`
and `probe-history.jsonl` under `/tmp/viewflow-button-live.ro1yLl`; receiver 7176,
presenter 16952, probe 725699. All trial processes/tasks/ports were cleaned and
Deskflow/original capture restored before rebuilding.

## History boundary tests and both-host builds passed; live retest pending

Preview tests now exercise historical ordered down/up confirmation, 32-receipt
eviction and generation renewal without replay (9/9 pass). Recorder tests also
exercise eviction and epoch replacement; all eight pointer tests pass on Windows.
The Windows presenter and receiver rebuilt successfully and all 12 CTests pass.
Linux native-GPU sender rebuilt as SHA256
`08449c8457ab91fb5c5b558307a91858678bb352d3924e2a2bbc702373290cc8`.
Library Clippy passes. Both hosts' diagnostic binaries now contain the history
candidate, but no live test of these binaries has yet been performed. This is
build/test evidence only, not sustained-input acceptance.

## Receiver history wiring candidate

The recorder retains up to 32 fully validated native presentation tags and
preserves a matched event's historical tag while publishing the current visual
separately. Context changes clear history, regression is rejected, and an
unvalidated current visual still cannot admit an older event. Preview forwarding
retains exact source authorization receipts, clears them on generation renewal,
and requires an exact sample identity match rather than a numeric frame range.
Current visual/authorization agreement and original deadline checks remain.

Seven preview tests, eight recorder/pointer tests (including the new historical
identity test), all 17 source runtime tests and library Clippy pass. Missing
receipt gaps remain rejected. These are local candidates, not deployed fixes;
boundary/renewal coverage and live Windows button verification are still needed.

## Source verified-receipt history candidate

`WindowPointerGrant` now retains at most 32 exact source-verified presentation
geometries within the same window/epoch/generation. Admission looks up the exact
identity and maps against that retained geometry, never the newest crop. Missing
receipt gaps, eviction, owner/generation mismatch, revocation, replay and timing
failure remain denied. Grant renewal creates fresh history and revocation clears
it. Seven core tests and all 17 source runtime tests pass, including real QUIC
and Unix-socket confirmation of retained frame 5 after frame 6 advances, followed
by rejection of never-verified frame 4. Clippy passes for both library crates.

Native and source candidates remain undeployed. The receiver-side recorder and
preview authorization are the remaining history wiring before end-to-end tests.

## Native event-time history candidate, not deployed

`PointerMotionState` now keeps at most 32 monotonic committed frame/QPC pairs
and selects the latest commit at or before the OS event timestamp. A queued
release crossing a newer commit retains its original frame identity. Unknown
or evicted history, future/expired events, invalid coordinates and timeline
regression remain rejected; regression retires instead of rebinding a session.
Coordinate deduplication includes the selected frame identity. Portable C++
tests pass for queued release, exact boundaries, eviction, clear and regression.

This is only the native portion of the fix and is deliberately not deployed:
`record_presenter_pointer_event`, preview authorization and source grants still
require the latest frame. Verified identity/geometry history must be connected
through those layers before end-to-end testing. No stale epoch or unverified
frame may be accepted merely because its numeric identity precedes the latest.

## Confirmed retirement cause: queued release crossed a newer visual commit

Trial `ro1yLlgap` reproduced `button-state-or-timing-rejected` on the third
gesture's up, with held=1 and valid client coordinates (836,522) in 1644x1044.
The Windows QPC evidence is event=35404274694415,
latest-commit=35404274845653, dispatch=35404274910474, frequency=100000000.
The event was only 2.16059 ms old, but preceded the newest commit by 1.51238 ms.
`PointerMotionState::timed_client_move` rejects `event_qpc < committed_qpc_`;
`timed_client_button` returns no event and its caller retires the input stream.
Thus this instance is the latest-only visual identity race, not a 33 ms event
expiry, focus loss or out-of-bounds coordinate. Simply retagging the event to
the newest frame would violate event-time visual identity and is not a fix.
Bounded event-time presentation history must preserve receiver/source geometry
authorization checks; both downstream layers currently enforce current identity.

Normal ACK counts were down=3/up=2. Source cleanup emitted up serial 11428 and
leave 11429 with held=0; this is not a normal third up. Sender video ACKed 119/119.
Evidence: `/tmp/viewflow-button-live.ro1yLl/{receiver-gap.stderr,sender-gap.stderr,probe-gap.jsonl}`;
Windows receiver 26856/presenter 20708 and `button-live-ro1yLlgap.json`.
Restoration/cleanup passed on both hosts; probe 663576 was terminated after
exact executable checking. The separate native motion ACK timeout from the
previous run remains unresolved. No event identity/deadline policy was changed.

## Source ACK wait diagnostics ready for the next live run

The 24 ms native ACK wait now reports elapsed/overdue time, polling count,
metadata packet count, maximum gap between polls and final state on failure.
This distinguishes a receiver still waiting from a reply consumed after the
deadline and highlights scheduler gaps without accepting late ACKs. Existing
absolute-deadline admission and the 33.333334 ms event budget are unchanged.
All 17 window-input runtime tests pass, including assertions that an already
expired wait performs zero polls. The native-GPU release sender rebuilt as
SHA256 `976c8e75432d0740d524b72dd8e146fd637b13dc43271a6e970a958bd6a36cee`.
This binary has not yet run live; the previous timeout cause remains unresolved.

## Detailed diagnostics deployed; fourth gesture hit native motion ACK timeout

Windows diagnostic build passed seven Rust pointer tests and all 12 CTests.
Trial `ro1yLlreason` used receiver SHA256
`E6DFFD7F86C84A2EB5C1A2975435046DB80B662AEA7E30456CFF8EF3141DEC2D`
and presenter `AEE4DB82F9E8A840433AFDDDBB70511670296A6741D6D85DC453E4A005ECE303`.
Three gestures received normal down/up confirmations; the fourth drag failed
with source `native window acknowledgement timed out: command=Moving generation=1 sequence=15`.
Counters ended down=4/up=3; the source client received cleanup up serial 11403
and leave 11404 with held=0. This is not a successful fourth normal release.
The receiver's later channel-closed error is a consequence of source teardown,
not evidence that the earlier native pointer retirement cause was fixed.
Video sent/ACKed 143/143 with zero receiver video rejection counters.

Evidence: `/tmp/viewflow-button-live.ro1yLl/{sender-reason.stderr,receiver-reason.stderr,probe-reason.jsonl}`;
Windows `button-live-ro1yLlreason.json` (receiver 13176/presenter 16656).
Restoration and task/process/port cleanup passed, and probe 641080 was terminated
after exact executable checking. The detailed retirement diagnostics are now
deployed, but this run instead exposed the native motion ACK timeout path.

## Repeated gesture run failed at the first click: native input retirement

`ro1yLlrepeat` attempted ten alternating clicks/short drags but stopped on its
first confirmation mismatch. Receiver 25696/presenter 22724 recorded down=0/up=0;
the source probe recorded no buttons. The first failure is now visible:
`native pointer input retired`, followed by preview-owner loss. Frame 100 failed
after 4,469 us with 28,368 us budget at write, and all video reject counters were
zero. This narrows the failure to the native pointer retirement path; it does
not yet distinguish focus/capture loss from event validation or timing rejection.
Evidence: `/tmp/viewflow-button-live.ro1yLl/{receiver-repeat.stderr,probe-repeat.jsonl,sender-repeat.stderr}`.
Cleanup verified VM service restoration, absent processes/port/task, original
managed capture, no native input socket and empty config errors; probe 622134
was terminated after executable verification.

Candidate diagnostics now tag every retirement call site and log rejected button
event/commit/current QPC, client coordinates and held state. The Rust reader
retains a bounded reason token. Seven Rust pointer tests and the portable C++
pointer tests pass; the changed Windows presenter was subsequently built and
deployed in the trial recorded above.
No timing, geometry, input-authority or retirement policy was relaxed.

## Live held-button receiver termination released the source once

Trial `ro1yLlheld` intentionally killed WindowsVM receiver PID 22932 only after
the native down ACK (`frame=86 sequence=3 ButtonSent`). No network up was sent:
the receiver was waited to exit before the controller released its own VM button
300 ms later. Final confirmed counters were down=1/up=0, errors=[]. The dedicated
Wayland client recorded down serial 11358 at time 166556279, then cleanup up
11359 at 166556601 (322 ms after down), and leave 11360 with held=0.
This proves eventual release for abrupt receiver process termination in this
run, not a bounded disconnect-detection SLA or arbitrary network partitions.

Evidence: `/tmp/viewflow-button-live.ro1yLl/{probe-held.jsonl,receiver-held.stderr,sender-held.stderr}`;
Windows `button-live-ro1yLlheld.json` records disconnect UTC
2026-09-05T22:10:38.0351356Z, presenter PID 4584 and no controller errors.
Cleanup verified original managed capture restored, input plugin/socket absent,
empty config errors, VM Deskflow Running, no diagnostic process/port/task.
The source probe PID 610468 was then terminated after exact executable checking.
The earlier intermittent preview-close cause and repeated/longer operation
remain unresolved; this is one successful held-disconnect case, not full-plan
acceptance. The hyprland-lua workflow was used for live state and restoration
checks; no persistent configuration was edited.

## Confirmed-press transport-loss regression

`mtls_disconnect_after_confirmed_press_closes_native_route` now exercises real
mTLS QUIC dispatch plus the native Unix socket: after a native-confirmed button
down, the peer disconnects without an up or another motion. The dispatch exits
with an error and the native socket reaches EOF, triggering its cleanup boundary.
All 17 `window_input_runtime::tests` pass serially. This proves route teardown,
not compositor delivery of the synthetic release; the live held-disconnect gate
below remains pending. Production behavior and deadlines are unchanged.

## Live click and same-surface short drag passed once; robustness still pending

Run `ro1yLld` completed a real click and short same-surface drag from WindowsVM
to the dedicated Wayland probe. Windows reports two downs/two ups with no runner
errors. The preview's new cumulative **validated native ACK** counters report
down=2/up=2 (not a count of coalescing watch log lines). The source client records
BTN_LEFT down/up serials 11335/11336, then down 11337, held motion from (404,250)
to (408,250), and up 11338 at (410,250), followed by leave with held=0.
These prove normal confirmed releases, not just terminal cleanup. Source video
ACKed 126 frames before the runner intentionally closed it; that planned teardown
produces a source connection-lost diagnostic, not an additional failed gesture.

Evidence: `/tmp/viewflow-button-live.ro1yLl/{probe-d.jsonl,receiver-d.stderr,sender-d.stderr}`;
Windows `button-live-ro1yLld.json` under the A3vq0y build directory records
receiver 20844/presenter 6556, confirmedDown=2/confirmedUp=2, errors=[]. Cleanup
verified original capture plugin, no Viewflow input plugin/socket, VM Deskflow
Running, no diagnostic processes/port/task; the dedicated probe was terminated.

This does **not** prove sustained reliability or arbitrary drag/drop. Run `c`
closed its native preview before a disposition (0.464 ms, not a video timeout),
with zero button confirmations; the original cause was hidden by the waiter
error. First-failure reporting now runs after cleanup notification. Additional
failure-only phase measurements distinguish write→stdout, stdout→notification,
and notification→waiter resume; they never affect deadlines. Run `d` had no such
failure, so the intermittent cause remains unproven. Both `c` and `d` waited one
second after initial motion confirmation and disabled optional diagnostic flags.
Next gates: repeated/longer operation (held-disconnect passed once above), and
cross-surface/outside-window/native-file-DnD behavior. Full plan remains open.

## Live button probe: real press and terminal release, interaction not accepted

Two bounded WindowsVM→Hyprland runs used the dedicated
`tools/wayland_pointer_probe.c` surface, not a file manager or business window.
The first run (`/tmp/viewflow-button-live.ro1yLl/sender.stderr`) stopped before
button injection with `capture has no window input binding`: the managed
HyprCapture still has the older wire format. Windows reported zero down/up.

The second run temporarily isolated the current capture build
`/tmp/viewflow-source-input.7rB2ma/capture-build/libhyprcapture.so` and Viewflow
input plugin. The native Wayland client log `probe-b.jsonl` records an own-surface
enter, motion to (401,250), BTN_LEFT down serial 11283, up serial 11284, and leave
with held=0. This is application-side evidence, not merely a sender ACK.
However, Windows frame 26 failed `coded frame became late after presenter ACK`
(26,897 µs remaining before write versus 27,714 µs total presenter wait).
The input route closed and the runner could not perform the second gesture.
Normal up acknowledgement versus terminal cleanup is not established by that
client up alone. **Click/drag acceptance remains failed/unproven.**

Logs are `/tmp/viewflow-button-live.ro1yLl/{sender-b.stderr,receiver-b.stderr,probe-b.jsonl}`;
Windows runner reports are in
`C:\Users\wilf\AppData\Local\Temp\viewflow-pointer-buttons-A3vq0y\button-live-ro1yLl[b].json`.
Both runners exited, diagnostic processes/UDP port were cleared, their scheduled
tasks removed, and Windows Deskflow restored to Running. The Viewflow input
plugin was unloaded, the original managed HyprCapture restored, temporary native
socket removed, and configerrors empty. The probe ended with held=0.

Next: establish the post-submit deadline failure's cause and repeat the exact
application-side down/move/up and disconnect-cleanup gates. No deadline was
relaxed and no gesture was counted as complete from this partial run.

## Windows button producer and ordered preview route (built, not live accepted)

The native preview now has explicit `--emit-pointer-buttons` (requires motion).
`WM_POINTERDOWN/UPDATE/UP` samples `POINTER_INFO.ButtonChangeType` and the original
QPC timestamp; right/middle are mapped to the protocol's right/middle values,
not Windows ordinal order ([Microsoft pointer flags](https://learn.microsoft.com/en-us/windows/win32/inputmsg/pointer-flags-contants)). Duplicate down and orphan up are rejected; unchanged
coordinates do not deduplicate transitions. Held state survives a visual commit.
Failed button sampling, cancellation, focus/capture loss, and leaving while held
retire input and emit `pointer-input-ended`; frame commits cannot reactivate it.
Outside-window grabs and native file DnD remain incomplete.

The Rust receiver's `--forward-pointer-buttons` requires the existing explicit
motion forwarding/native opt-in and enables the native button flag. Strict stdout
parsing preserves native deadlines and exact validated video identity. A 64-entry
FIFO carries **both motion and transitions** in button mode, so a newer motion
cannot overwrite or jump past a button. Overflow, producer loss, stale buttons,
and wrong ACK kinds close the shared route. Default motion-only behavior remains.
The native stdout path is still synchronous diagnostic I/O, not a production
nonblocking transport; real interaction under load has not been accepted.

Tests include the complete preview→mTLS→source→native-socket down/motion/up path,
FIFO overflow during an outstanding ACK, stale release, and native frame renewal.
Windows-native compilation and all 12 CTests passed in
`C:\Users\wilf\AppData\Local\Temp\viewflow-pointer-buttons-A3vq0y`.
The implementation initially had build/test evidence only; the newer bounded
live attempts and their still-failing acceptance gate are recorded above.
Linux GPU-feature library tests pass 228 with 6 hardware/diagnostic tests ignored;
the shared window runtime subset passes 16/16. Windows example tests pass 47/47
and preview-input tests 6/6. Linux GPU library and example Clippy pass with
warnings denied; Windows builds retain existing platform-unused-code warnings.

## Source button session and reliable network dispatch

`WindowInputSession::begin_buttons` is an explicit local policy factory; the
existing `begin` remains motion-only. The private mode is retained during
renewal. Button requests use the same identity, presentation, sequence and clock
validation as motion, encode native tag 55, and become ready only after matching
native `ButtonSent` confirmation. Every button failure closes the native session
to trigger cleanup, including stale releases and attempts under motion-only grants.
Real Unix socket tests cover both begin modes, renewal mode retention, button
encoding/confirmation and stale-release retirement. The Linux shared dispatcher
now routes button messages to the locally constructed session; motion-only
sessions reject and retire on button attempts. The diagnostic source opts in via
`--authorize-pointer-buttons`, which requires `--authorize-pointer-motion` and
its existing GPU/native peer policy. No existing invocation gains button access.

Network `WindowPointerAck` result 3 is ButtonSent (distinct from native result 4).
A real mTLS + Unix socket test proves no ACK before native confirmation and that
a replayed release retires the route. Motion preview ACK handling rejects a
ButtonSent result rather than allowing it to complete motion. The Windows
ordered transition producer is now connected as described above; no live button trial or
pressed-resource cleanup proof has been performed.

Verification: runtime tests 15/15 (including explicit denial over mTLS), protocol
tests 28/28, motion-preview tests 3/3 and source-policy example tests 3/3 pass.
GPU-feature daemon library Clippy passes with warnings denied.

## Native button lifecycle implemented, not yet activated by the peer

Native tag 55 and matching Rust codec now carry bounded canonical button
transitions, with a distinct ButtonSent result (4). Explicit BEGIN_BUTTONS (56)
is required; ordinary BEGIN remains motion-only and renewal cannot change mode.
The native session records exact weak pointer recipients, rejects duplicate down
and orphan up, caps recipient traversal/storage, and releases its records on end,
disconnect, expiry or revocation. Local takeover now invokes cleanup before the
physical event continues; pre-existing physical held buttons reject binding.
Targets are move-only to keep the cleanup callback single-owner. Focus-change
callbacks are checked before any subsequent native motion is sent.

Presses cannot silently migrate across subsurfaces. Native file DnD is not yet
implemented: it causes button-session retirement, with cancellation limited to
an exact matching owned origin plus owned pressed records. It must not be
reported as completed drag/drop support. Connections without a local source
route still reject window-button messages; real press/release/cleanup trials
remain to do.

Native build and 4/4 CTests pass, including canonical button/truncation and
explicit-grant parsing. Rust Hyprland tests pass 17 with one live-query ignored;
the codec checks exact result correlation and rejects ButtonSent for motion.
GPU daemon library Clippy passes with warnings denied. These are codec/build
checks, not live proof of pressed-resource cleanup. No plugin load, desktop
input, service change or VM trial was performed for this native implementation.

## Button protocol boundary and in-place native renewal (not enabled end to end)

`WindowPointerButton` now has its own control-envelope tag 32. It requires the
complete validated `WindowPointerMotion` position/context plus an explicit
five-button pressed/released transition; absent fields, unknown enums, stale
identity shape and out-of-viewport coordinates are rejected. This does not reuse
device-wide input. Legacy device-input decoding cannot interpret the new tag,
and the coordinator returns `WindowInputRuntimeRequired`. Until the native
pressed-button lifecycle and Windows producer are connected, generic daemon paths
without a source route explicitly reject button messages. The source shared
dispatcher is now connected under explicit local button policy as described above.
Protocol tests pass 28/28, coordinator tests 7/7, and GPU-feature daemon library
Clippy passes with warnings denied.

Native renewal now retains the same session, focused surface and previous-focus
snapshot rather than destroying/recreating them each generation. It requires
the same live window, main surface, PID and extent, an active unrevoked session,
and strictly later expiry; invalid renewal revokes the authority. Native command
tests still pass 4/4. This is necessary for uninterrupted future button ownership
but is not itself a button or drag implementation.

r14 added enter/leave recording to the owned probe and attempted live renewal
verification with the new plugin. The VM cursor did not reach the first requested
point, so the runner stopped during warmup: zero input/video ACKs and no probe
enter/leave evidence. Thus in-place renewal is build-checked, not yet live-proven.
Windows cleanup and managed-plugin restoration passed; the owned probe exited
normally. No Deskflow/Sunshine service or persistent Lua setting was changed.

## Application-side coordinate witness: r13

Added `platform/linux-pointer-probe`, an owned Qt/Wayland test widget with no
input injection, grabs or keyboard logging. It requests no activation, has a
fixed 791x598 client area, writes a new-only owner-readable log, and exits after
90 seconds (or the 4096-record cap). Its live PID/address were verified before
capture; the Dolphin fixture was not changed.

r13 used the rebuilt batch-drain sender, a limited Windows runner and the
already-running Deskflow service. All 24 VM cursor positions arrived; 21 native
motion ACKs and 736 video ACKs were recorded. The owned application received
19 spontaneous motion records at the exact mapped points: preview `(120,220)`
and `(200,220)` in a 1626x1240 viewport map through the 813x620 capture and its
11-pixel content inset to widget `(49,99)` and `(89,99)`. Other local motion was
also present in the widget log and is not counted as remote proof. This is
application-side spatial evidence for these points, not a one-to-one guarantee
for every ACK; Qt can coalesce moves or generate enter events separately.

The user additionally reported that clicking/landing accuracy was essentially
correct. Preserve this mapping. The current dedicated window-scoped wire/native
path still implements motion only, so button-down/up and drag ownership require
separate implementation/verification; do not infer those from this motion log.

The run ended on `generation=4 reason=LocalMotion`, not an ACK timeout. Windows
collector cleanup passed; Linux restored the original managed capture plugin
with empty configerrors. The owned witness exited normally on its timer. No
Deskflow/Sunshine service was changed in r13. Evidence is `probe-r13.jsonl`,
`live-r13.json`, `live-r13.json.stderr`, and `sender-live-r13.stderr` under
`/tmp/viewflow-source-input.7rB2ma`. The batch-drain fix has now run live, but this
single trial does not establish that all native ACK timeout causes are solved.

## Queued-metadata ACK starvation fixed (live causation not yet established)

A real seqpacket/mTLS regression queued metadata followed by an already-readable
BEGIN ACK. The old runtime slept 1 ms after every metadata packet and failed the
unchanged 24 ms ACK budget with only 32 queued metadata records. It now drains
ready metadata in batches of at most 32 before yielding; every packet still
checks the absolute deadline, presentation owner and peer connection. An empty
socket retains the bounded idle wait. The regression now covers 64 metadata
records plus ACK, and a separate deliberately slow metadata callback must time
out without consuming the following ACK. This fixes a demonstrated queue-drain
defect, not proof that it caused all earlier live timeouts.
All 12 window-input runtime tests and GPU-feature library Clippy with warnings
denied pass after the change.

r11, before this batching change, failed the VM cursor-position check again
(one attempted move, zero delivered); no live frames/input ACKs were admitted.
r12 temporarily isolated the explicitly authorized VM Deskflow service and
restored it in `finally`: two delivered VM positions, 30 video ACKs, then native
`generation=1 reason=LocalMotion` revocation. No native input ACK was recorded.
These trials did not reproduce the target native ACK timeout. Both collectors
confirmed complete trial cleanup and Linux restored its managed capture plugin.
Deskflow is restored Running/Auto, service PID 20844, client PID 20708 with the
same settings path. No Linux/physical-Windows service or Sunshine was changed.

The batch-drain change was subsequently rebuilt and exercised in r13 above.
Full input and product acceptance remain open.

## First real native motion delivery: r8 isolated VM trial

The user explicitly approved temporary WindowsVM Deskflow isolation. The r8
interactive runner verified the original service/core identity, stopped only the
VM Deskflow service, and restored it in `finally`. Linux and physical-Windows
input services and Sunshine were not changed. The restored Deskflow service is
Running/Auto (PID 12856), with a fresh client core PID 23992 and the same settings
path. Collector checks confirmed no test process, UDP listener or trial task;
Linux restored the original managed capture plugin and empty configerrors.

With the VM Deskflow core absent, all 24 requested native `SendInput` movements
were verified at the requested preview points using `GetCursorPos`. The Windows
preview received real `WM_POINTERUPDATE` messages with matching HWND, PT_MOUSE
and nonzero native event QPC. The receiver recorded 22 `MotionSent` native ACKs
across generations 1 through 4, preserving the original event deadlines. Source
video sent and ACKed 1655 frames. The bounded session ended at the receiver
timeout and closed the route; no authorization/takeover fence was disabled.

This establishes the first real Windows-preview-to-Hyprland window-scoped native
motion command path, including renewal. It does not establish every sample was
admitted (24 cursor positions versus 22 native ACKs), application-side spatial
acceptance, click/drag/key delivery, or the full plan. The isolation result makes
the existing VM input environment relevant, but r8 also ran elevated for service
control, so it is not a single-variable proof that Deskflow alone caused the
earlier stationary cursor. A future controlled test should retain a limited
receiver token while isolating the service separately. Evidence: `live-r8.json`,
`live-r8.json.stderr`, and `sender-live-r8.stderr` under
`/tmp/viewflow-source-input.7rB2ma`.

r9 kept the restored Deskflow service running and retained the elevated runner:
7/7 requested VM positions arrived, 5 native motion ACKs, 179 video ACKs. r10
returned to the original limited runner with Deskflow still running: 9/9 VM
positions arrived, 5 native motion ACKs, 238 video ACKs. Both ended with a native
ACK timeout, not the old stationary VM cursor failure. Thus motion delivery does
not require leaving Deskflow stopped or running Viewflow elevated; the earlier
failure's exact cause remains unproven after the service restart. No service was
changed during r9/r10. Both collectors and Linux restoration checks passed.
The runtime timeout error now retains the awaited command state, generation and
sequence, including when a readable ACK is rejected after its deadline; no input
coordinates or key values are added and no timing boundary changes. The existing
already-expired-BEGIN regression test now checks this exact diagnostic context.

## Typed native revocation and VM cursor delivery diagnostics

Native tag 54 now reports the first irreversible window-pointer revocation cause
with its generation, without key/button values. Window/surface lifetime changes,
resize, lock, local takeover, expiry, focus loss and route loss are distinguished.
The strict seqpacket decoder rejects malformed reasons, lengths, reserved fields
and zero generations. The shared runtime consumes unsolicited revocation while
idle and closes both native and network input routes immediately. Renewal cannot
clear a revocation. This does not weaken any authorization or deadline fence.

Validation: Hyprland socket tests 16 passed / 1 live-query ignored; daemon
window-input runtime tests 10/10; GPU coded example tests 46/46; native CTests
4/4; GPU library/example Clippy with warnings denied passed. Release sender and
native plugin rebuilt for the trials below.

- r4: receiver launch was delayed by the shell execution-policy invocation;
  sender timed out with zero frames. The corrected runner confirmed thread and
  input desktop names both `Default`; no input was sent. No delivery conclusion.
- r5/r6: receiver readiness was checked before source launch. The first native
  `SendInput` call returned success, but `GetCursorPos` did not reach the preview
  point, so the runner stopped immediately. r6 requested `(200,300)`, observed
  `(1920,1200)`, with clip rectangle `(0,0)-(3840,2400)` and matching `Default`
  desktops. Each trial attempted one move, confirmed zero delivered positions,
  and ended during video warmup. Earlier move counts are NOT delivery evidence.
  The VM has Deskflow client and Sunshine processes; their presence does not
  prove causation, and neither service was stopped or reconfigured.

r4-r6 collectors confirmed diagnostic process/listener/task cleanup. Each Linux
trial restored the same managed HyprCapture hash recorded below, unloaded the
temporary plugins, and left empty configerrors. No persistent Lua configuration
changed. End-to-end input acceptance and the full plan remain incomplete.

r7 disabled all VM input probes to isolate source authorization. It sent and
ACKed 261 video frames, successfully reached generation 2, then immediately
reported `native window authorization revoked: generation=2 reason=LocalMotion`.
This proves renewal can succeed and local-motion revocation reaches the live
source; it does not retroactively identify r3's unknown rejection. The Linux
cleanup restored the managed capture plugin and empty configerrors; the Windows
collector confirmed zero moves and diagnostic process/listener/task cleanup.
No takeover guard was disabled. Further input-isolation experiments must avoid
interrupting the user's existing Deskflow/Sunshine session without permission.

Read-only follow-up: the preview source has no `SetCursorPos`, `ClipCursor`,
`BlockInput`, or `SetCapture` calls; its mouse-in-pointer opt-in alone does not
explain the stationary cursor. The locally available Deskflow source has no
`BlockInput` call in its MSWindows platform files and lets injected events pass
through the secondary-client low-level mouse hook. This source is not proof of
the installed Windows binary's behavior. Current VM inspection confirms Deskflow
core PID 8868 remains owned by the running automatic Deskflow service PID 3084.
No diagnostic process/listener remains. Service isolation still requires the
requested user approval; no existing service was changed by this follow-up.

## First real source-route trials: input acceptance still failing

Three bounded trials used the current Linux GPU sender, a fresh Windows-native
release receiver/presenter, the retained Dolphin fixture, and explicit source
authorization. The Windows harness used native `SendInput` mouse movement only
on the exact preview HWND/PID in WindowsVM Session 1, not PostMessage. It did not
move the Linux cursor or issue clicks. Source and receiver evidence is under
`/tmp/viewflow-source-input.7rB2ma` and the corresponding Windows temp directory.

- r1: 242 video ACKs and 9 VM moves; source input closed around first renewal.
- r2: 2 video ACKs; added source error logging identified native BEGIN ACK timeout.
- r3: 241 video ACKs after the FD-readiness fix below; native command returned
  `Rejected` around renewal. Nine VM moves still yielded no pointer-motion or
  native-motion-ACK evidence. The rejection cause remains to be isolated; do not
  weaken takeover/expiry checks to hide it.

Hyprland's animation manager emits `tick` only while animations need ticks.
`InputCapture` previously read IPC only there, so static-desktop commands could
miss the unchanged 24 ms ACK deadline. `MetadataBridge` now registers its socket
with the Wayland loop's readable callback, tracks FD plus connection generation,
unregisters on disconnect/unload, and has a 100 ms reconnect/idle watchdog.
Commands are still drained in bounded batches; HUP/error immediately disconnects.
The post-read maintenance pass revokes native state on discovered disconnect.

Separately, higher-generation renewal can no longer undo an already revoked
native session on the same connection. `WindowPointerAuthority` retains the
revocation until reconnect; `WindowPointerSession::active` synchronously checks
expiry, target revocation and existing pointer-focus ownership before renewal,
instead of waiting for a future animation tick. The native command test covers
generation monotonicity, irreversible revocation, and fresh-connection reset.

Native plugin rebuild and 4/4 CTests pass. Fresh HyprCapture build passes 16/16;
Windows native preview builds and its CTests pass. Linux Clippy still passes with
warnings denied. These checks do not establish functional mouse delivery.

All three trials restored the original managed HyprCapture (SHA256
`668c4cdb59da87c777e9c86d1f86b7efad94f0d73d6f2f84219dd84974c96c27`), unloaded the
temporary input/capture plugins, and left empty configerrors. The temporary
native socket directory was removed when empty. Windows collectors verified no
diagnostic process or UDP listener and removed each trial task. The Linux active
window remained ChatGPT during the checked r1 boundary. No persistent compositor
configuration or managed plugin artifact was modified.

## Source CLI activation and bounded renewal (current)

The GPU sender now installs the native route behind explicit
`--authorize-pointer-motion`, `--pointer-native-socket`, and matching owner/source
IDs. The local socket enforces the configured compositor PID and same UID.
Captured input snapshots are retained before GPU release in a bounded map and
consumed by the exact encoder output; only its fresh video ACK can publish
authorization. No incoming motion can manufacture capture evidence.

`WindowInputSession::serve_authorizations` integrates source updates into the
shared dispatcher. Renewals require a higher generation, newer presented frame,
later expiry, and unchanged native/window/geometry binding. Native BEGIN must
confirm every renewal before advertisement or motion. The five-second native
deadline limit remains unchanged. The sender renews from fresh ACK evidence in
the last second of a grant and joins input teardown before stopping capture.
Socket cleanup checks the inode; target WINDOW_REMOVE metadata revokes the route.

Linux library tests pass 199/199; GPU-feature coded example tests pass 46/46,
including source CLI opt-in, native socket timeout/non-overwrite cleanup, and
exact target removal. The library real-seqpacket test checks renewal BEGIN and
rejection of stale/changed/excessive grants; the shared-mTLS test checks the
authorization watch, frame advance, old-frame rejection, and owner-loss teardown.
Windows-native example check and 45/45 example tests plus all three preview-input
tests pass in `C:\Users\wilf\AppData\Local\Temp\viewflow-source-input-7rB2ma`.
Linux GPU-feature library/example Clippy passes with warnings denied. The native
Hyprland plugin rebuild and 4/4 CTests pass in
`/tmp/viewflow-source-input.7rB2ma/plugin-build`; it has not been loaded.
These are not live compositor or cross-host input acceptance. Real source
activation and interaction testing remain outstanding. This supersedes older statements below that the source CLI
has no input installation or that explicit renewed generations are rejected.

## Native preview event bridge and receiver activation

The coded Windows receiver now bridges timed native pointer output into
`PreviewPointerState`. Raw Submitted first clears the old input context; only
the video writer's successful matching submission/deadline validation publishes
the full authenticated window/epoch/frame tag. Pre-validation motion is not
replayed. Later samples retain the native-derived absolute deadline and a
monotonic sample sequence. Expired/decode-only records do not replace a visible
input target. Presenter failure/drop closes the watch owner.

`--forward-pointer-motion` is separate from diagnostics and requires explicit,
distinct nonzero 128-bit owner/source IDs plus `--emit-pointer-motion`. It starts
`WindowPreviewInput` after the first fresh video ACK, on the same QUIC connection
as video. Video's existing bi-stream and control uni-stream acceptance cannot
consume each other's records. Task teardown synchronously closes the connection
and aborts its worker. Default diagnostic-only invocation does not forward input.

Linux example tests 41/41 and GPU-feature example check pass. Windows-native
example check and 44/44 tests pass from
`C:\Users\wilf\AppData\Local\Temp\viewflow-pointer-bridge-pSlmzB`.
Bridge tests cover full identity, no pre-validation replay, cutover invalidation,
old-frame rejection, retained native deadlines, and watch shutdown. No preview
was launched and no actual mouse message or remote input was exercised.

The normal Linux sender still lacks source native-route installation; forwarding
against it will fail the input probe and close video. Source capture/receipt
activation and live interaction acceptance remain incomplete.

## Preview network producer

`WindowPreviewInput` now enters the same shared control dispatcher and writer
on Linux/Windows. It accepts a bounded latest native-presentation/motion watch,
validates source authorization against locally selected device/window IDs, and
requires exact agreement between authorization, actual presented identity, and
sample identity. Unadmitted samples are consumed rather than replayed when a
grant or clock arrives later. Native deadlines are never refreshed.

One motion can await confirmation at a time. Queueing and QUIC writes use the
existing absolute-deadline/cancellation gate; ACKs must match the entire event
identity and arrive before its deadline. Source lease expiry is mapped with the
same clock-quality/drift checks, separately from the event's 33.333334 ms horizon.
Authorization cannot retarget, regress, or renew its expiry within this route.
Missing native/ACK owners, timeout, disconnect, and cancellation close it.

A real local mTLS test runs BOTH source and preview dispatchers, their periodic
clock probes, source authorization, the preview writer, and a Unix seqpacket
native fixture. A preview watch sample reaches the native peer; no successful
preview ACK appears before native confirmation; removing the sample owner
closes both routes. This does not use a handwritten remote motion message.
The native samples and native backend are still simulated, not Windows mouse
events or live Hyprland injection.

Linux daemon tests 197/197 and protocol tests 27/27 pass. Windows VM check and
protocol/daemon tests pass (daemon 124/124), source bundle at
`C:\Users\wilf\AppData\Local\Temp\viewflow-preview-input-EpZMRM`.
Library Clippy, GPU-enabled coded-example check, and formatting pass.
The coded preview's existing pointer stdout slot is not yet bridged into this
watch, and the regular capture/CLI workflow still does not install these routes.
Those integration steps and actual pointer/click/drag acceptance remain required.

## Source authorization announcements

Control tag 31 is `WindowPointerAuthorization`: lease generation, full 128-bit
owner/device/window identities, geometry epoch, presented frame, and the
unchanged absolute expiry in the source connection clock. The parser rejects
missing/zero identities. It is an announcement to the preview peer, never a
device-wide injection grant; the general coordinator rejects it as input.
Peers must support this new control before using the authorized-window entry.

The source route publishes through the shared confirmed writer only after
native BEGIN confirmation and an initial validated clock exchange. A verified
source presentation update produces a new announcement, without renewing the
lease expiry. Duplicate unchanged announcements are suppressed. Disconnect
invalidates the connection-local authorization; the receiving producer must
not retain it across reconnects.

Real mTLS/seqpacket tests inspect the complete announced identity, advance the
source presentation, observe the new frame announcement, and verify the old
frame event is rejected without native motion. Protocol tests 26/26, core
tests 48/48, and Linux daemon tests 192/192 pass; library Clippy passes. Windows
VM library check and protocol/core/daemon tests pass (daemon 120/120), using
`C:\Users\wilf\AppData\Local\Temp\viewflow-window-authorization-uR50Sj`.
This is source-session network publication, not normal-CLI capture activation
or preview event sending. Neither a live plugin nor real input was exercised.

## Connection-owned periodic clock evidence

The authorized source entry now runs the existing clock-probe loop on its own
shared control reader/writer. It sends an initial probe, refreshes 250 ms after
each accepted reply, and allows 250 ms for a reply. Only validated exchanges
publish the clock snapshot, before the receiver processes the next control.
`WindowInputSession::serve` no longer accepts an external clock watch. Missing
initial evidence rejects motion; probe failure, disconnect, cancellation, and
source presentation loss tear down both native and network routes. The scoped
guard now owns both writer and probe tasks.

Real mTLS/Unix-seqpacket tests verify pre-sync rejection, immediate motion after
a valid initial reply, a second measured exchange followed by native-confirmed
motion, and a deliberately unanswered second probe revoking before native lease
expiry. Six runtime tests and all 192 Linux library tests pass. The simulated
native peer remains a test boundary, not actual compositor input acceptance.
The normal CLI's source activation and preview event producer remain unwired.

## Shared reliable dispatcher for an authorized source route

Both daemon receive loops now use `receive_shared_peer_payload`. With a locally
installed window route it retains one partially consumed reliable receive
future across native maintenance ticks, dispatches window motion through
`WindowInputSession::deliver`, and sends its exact ACK through the existing
shared control writer/sequencer. Other control families return to the normal
daemon handler. Without a route, window motion remains rejected.

`WindowInputSession::serve` now enters that same server dispatcher rather than
the old window-only reader/writer. Source-owned presentation receipts remain
explicit inputs; clock ownership is now internal as described above. Closing
the source presentation/clock owner fails the route. Cancellation drops the native session,
aborts the writer, and closes the QUIC connection via a scoped guard.

Real local mTLS/Unix-seqpacket tests exercise native-confirmed motion followed
by a clock probe on the same connection, one shared outgoing sequence, a probe
split across multiple native-maintenance ticks, missing-clock rejection, source
presentation loss, and cancellation closing both native and network paths.
Linux runtime tests 4/4, library tests 190/190, and coded preview tests 39/39 pass.
Windows VM library check and 120/120 library tests pass using the source bundle
at `C:\Users\wilf\AppData\Local\Temp\viewflow-shared-window-H35Lxu` (the final
additional cancellation test is Linux-only). Native source used by the Windows
build matches the changed shared dispatcher. Existing Windows cfg-unused
warnings remain. Linux cross-GNU checking was unavailable because MinGW GCC
is missing; the native Windows run is the platform evidence.

The normal CLI still supplies no source window route. Production authorization
activation and the preview's real network producer
remain unwired. No compositor plugin was loaded and no desktop input injected;
these tests use a simulated native peer and are not interactive acceptance.

## Native acknowledgement wait race

`WindowInputSession` now checks an absolute 24 ms wait deadline both before
native polling and after polling/metadata dispatch. A buffered reply cannot
override an elapsed timer when the executor resumes late. Before accepting a
native completion it also checks presentation-owner liveness/updates and QUIC
disconnect state; these checks no longer depend on a select branch winning.
The caller still revokes on errors and must revoke/drop on cancellation.

The real mTLS + Unix seqpacket regression now queues a native BEGIN reply and
verifies that an already elapsed wait rejects it without consuming it. The
three runtime tests and formatting check pass. This fixes the confirmation
boundary; it does not connect the preview's latest-motion slot to network
dispatch, construct production source grants, or prove live native input.

## Preview event-time preservation

The Windows preview's opt-in pointer path now enables mouse-in-pointer and reads
`WM_POINTERUPDATE` / `POINTER_INFO.PerformanceCount`, not a fresh timestamp taken
after a queued `WM_MOUSEMOVE` is dispatched. Microsoft documents PerformanceCount
as the high-resolution counter at pointer-message reception; mouse-in-pointer is
process-local. [Pointer timestamp contract](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-pointer_info),
[mouse-in-pointer contract](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enablemouseinpointer).

Both live presentation-commit paths record QPC. Pointer events older than that
commit, future-dated events, and events beyond the original 33.333334 ms deadline
are dropped. The exact stdout grammar now has eight fields, appending
`not_after_qpc` and `qpc_frequency`. The Rust reader samples process time before
QPC, maps the unchanged native deadline conservatively, drops expired backlog,
and stores one latest `(motion, sender_not_after_ns)` pair. Receipt time never
creates a fresh event budget. Old six-field native output is rejected; update
preview and receiver together. The old PostMessage(WM_MOUSEMOVE) probe no longer
exercises this path and must not be reused as acceptance evidence.

Windows VM native MSVC build and 12 CTests passed. Output:
`C:\Users\wilf\AppData\Local\Temp\viewflow-pointer-timed-pocAlx\build\Release\viewflow_windows_composition_preview.exe`,
SHA256 `75f42a9a2c022d1ae380c2e5554e60f6c2610517f032fa659ad85aae76f05c44`.
Windows-native Rust example check and two pointer tests passed; Linux example
tests 39/39 passed, including a delayed-receipt assertion preserving the same
deadline. Native portable pointer tests also pass with warnings denied.
These are build/unit tests, not real pointer-message or remote-injection acceptance.
No preview or input injection was launched. Synchronous diagnostic stdout can
still stall the UI and is not the final production input transport. The actual
network pointer producer remains to be connected.

## Captured snapshot to native binding

`AuthorizedWindow::from_gpu_frame` now constructs the input geometry directly
from the authenticated retained GPU frame/HCGI snapshot. It requires the exact
capture sequence and geometry epoch in the source-verified presentation receipt,
rejects missing HCGI and invalid content/full-frame containment, excludes decoration
pixels, and derives native surface scale from the frozen rendered content size.
The source capture must remain alive through native binding and input must revoke
on capture retirement; a copied token is not an independent lifetime guarantee.

Native BEGIN now requires a nonzero captured surface token at payload offset 48:
payload size is 56 bytes (76 including VFHY header). The controller compares that
token to the selected window's current main surface before binding. Old 48-byte
BEGIN packets are rejected. Rust encoding and native parsing tests were updated
together. Runtime motion now applies both the frozen scale and content offset.
HyprCapture also advances geometry epoch when the rendered content rectangle
changes, preventing a same-epoch update from silently changing this scale.

Tests cover actual HCGF/HCGI socket receive -> source authorization construction,
decoration exclusion, fractional/global coordinate mapping, stale receipt rejection,
and scaled native motion bytes. Rust GPU tests 14/14, runtime tests 3/3, Hyprland
crate 15 passed/1 live ignored, native plugin CTests 4/4, and library Clippy passed.
Native controller surface comparison itself still needs live lifecycle validation.
No live plugin update or actual desktop input was performed.

## Frozen content/surface geometry transport

HyprCapture now appends an optional 88-byte HCGI geometry record to the same
HCGF seqpacket and image/fence descriptors. Wayland capture freezes window and
surface tokens, PID, desktop-space rendered content rectangle and native surface
extent before rendering. It checks identity, extent and rendered content geometry
again after renderer re-entry. No shadow-derived or later desktop-query geometry
is substituted. XWayland currently has no extension.

The Rust GPU receiver accepts legacy 232-byte frames or 320-byte extended frames,
strictly decodes HCGI, and retains it on `GpuFrame::input_geometry()`. Both C++ and
Rust pin the same 88-byte golden fixture. C++ sender tests cover two-FD transmission
of an extended packet; Rust socket tests cover retention and malformed-extension
retirement. Rust GPU tests 14/14 and daemon library Clippy passed. Plugin builds
successfully; live loading/deployment has not occurred.

Snapshot construction, surface scaling and captured-surface native binding are
implemented in the section above. The actual preview producer and shared network
dispatcher remain unwired. This is not input acceptance.

## Captured target identity lifetime

Source audit found HyprCapture's stream session retained only a window address
and looked it up on every capture tick. The HyprCapture working tree now retains
the original window and main surface objects, revokes irreversibly on window or
surface unmap/destroy, and stops capture/drain on revocation or surface replacement.
The GPU path rechecks identity and frozen surface size after renderer re-entry;
surface size changes also advance the stream geometry epoch. CPU submission
checks revocation. Retaining the original objects prevents address reuse from
silently selecting another window while the stream exists.

This change is in `hyprcapture/src/plugin/artifact_capture.cpp`, not deployed to
the running compositor. Build succeeded and the existing 16 CTests passed;
those tests do not exercise live window/surface lifecycle signals.

Coordinate audit also confirmed that HCGF v1's logical rectangle is the full
rendered artifact in desktop coordinates, not the main surface content rectangle.
It cannot by itself supply an input mapping: a source-frozen main-surface rectangle
and native surface extent/identity are still required. Do not infer this from
shadow cutout geometry or use a later desktop query as capture-time evidence.
No HCGF wire extension or real preview input forwarding was enabled in this step.

## Network window-input execution and confirmation

Protocol tag 30 is now `WindowPointerAck`, distinct from device-wide input ACKs.
It repeats the exact lease/device/window/epoch/frame/event identity and validates
only native-motion-confirmed or rejected outcomes. Full 128-bit IDs and malformed
ACK identity/result cases have dedicated protocol tests.

`WindowInputSession::deliver` is the asynchronous dispatch boundary for the
future shared connection reader: it reads no network streams, applies the source
grant and current source presentation/clock context, waits at most 24 ms for the
native result, and returns a window ACK only after confirmation. Native failure
revokes the session. Cancellation requires the owner to revoke/drop it.
An isolated `serve` integration harness owns a QUIC control reader, preserves
partially consumed receive futures across native polling, applies control
sequencing, dispatches metadata, and returns typed window ACKs. This harness is
not a change to the target one-shared-connection-per-device architecture.

A real local mTLS QUIC + Unix seqpacket test verifies that native motion reaches
the peer, no successful network ACK arrives before the native confirmation,
missing clock evidence returns rejection without a native send, and disappearing
source presentation ownership closes the native connection. The native peer is
simulated: no actual Hyprland input was injected. Runtime tests 3/3, protocol
tests 25/25, core tests 47/47 passed; daemon library Clippy passed.

The normal daemon control loops and coded preview are not yet wired to construct
this source authorization/session or to feed actual presented-frame receipts and
pointer events. Their existing rejection behavior remains. Production integration
and compositor/Windows live acceptance are still required.

## Source window-input runtime

`viewflowd::window_input_runtime::WindowInputSession` now owns a native connection
and a source-created `WindowPointerGrant`. Begin sends the exact native target;
motion applies the authenticated-owner/geometry/sequence grant checks and shared
clock-offset, uncertainty, drift and freshness checks, adds the source-supplied
content-to-surface offset, validates surface bounds, and sends the native motion.
Process-relative deadlines are converted conservatively to CLOCK_MONOTONIC by
sampling native time before process time. Native command acknowledgements drive
Beginning/Ready/Moving state; errors, expiry during polling, explicit revoke and
drop close the connection. Native lease timer remains the independent expiry
backstop. Callers must poll regularly and dispatch returned metadata.

Real Unix listener/connection tests exercise begin, timing rejection without a
send, spent-event replay rejection, admitted coordinate mapping to (50,20), native
ACK, and EOF on revoke. A separate test rejects a same-user wrong-PID connection
and invalid deadlines. This is a simulated native peer, not a live compositor
test. The normal network receive loops still reject window input: they do not yet
construct this session from source policy/presentation receipts. No live plugin
was loaded and no desktop input was injected in this step.

## Native socket transport

Linux `window_pointer_socket` now binds a nonblocking Unix seqpacket listener
in a pre-existing private owned directory, without unlinking existing paths.
Accept checks SO_PEERCRED for the same effective UID and exact expected compositor
PID. Each connection permits one outstanding pointer command, rejects outgoing
sequence replay, checks incoming framing/size/sequence, preserves non-result
packets for metadata dispatch, and correlates result packets through the wire
codec. Protocol and send failures shut down the connection rather than leaving a
possibly active session attached. Caller owns socket pathname cleanup.

Two real kernel socketpair tests exercise command transmission, interleaved
metadata, matching acknowledgement, replay, and oversized-packet rejection.
Crate tests: 15 passed, 1 live test ignored; library Clippy with warnings denied
passes. Listener peer rejection still needs direct tests. No daemon instantiates
this listener yet; source grant/deadline integration and live compositor
end-to-end input remain unfinished. This does not enable remote input.

## Native IPC command parsing

Rust `viewflow_hyprland::window_pointer_wire::Request` now encodes begin/move/end
and consumes itself on result parsing. It validates exact reply framing, reserved
bytes, nonzero envelope sequence, echoed generation/request sequence, and the
specific expected operation result (e.g. move success cannot acknowledge begin).
Native envelope sequence is returned separately for connection-level ordering.
It performs no socket I/O or authorization. Layout/boundary tests pass; the crate
has 13 passed/1 live-test ignored and library Clippy passes. No cross-language
roundtrip or daemon socket integration has been exercised yet.

Capture ownership follow-up: window routing is denied in CAPTURE_PENDING and
REMOTE_CAPTURED phases. Entering either path cancels the native window session
without restoring old focus; tick and every command recheck phase. Rejected
begin generations remain spent so capture release cannot reactivate a replay.
All four phase-policy cases have compile-time assertions; plugin build and
4 CTests pass. Native focus transition behavior remains unverified live.

Commands now route from InputCapture's single receive loop into
WindowPointerController. Begin binds matching address/PID/main-surface extent
and a bounded (<=5s) native monotonic deadline; move requires the retained
generation; end is idempotent for that generation. Failed/ended generations
remain tombstoned until the checked IPC connection changes. A result payload
contains generation u64, request sequence u64, result u32 (0 rejected, 1 begun,
2 motion sent, 3 ended), reserved u32=0. Disconnect/reconnect or failed reply
ends the native session; replies cannot reconnect themselves into another
connection. SocketSink now verifies SO_PEERCRED uid matches effective uid and
PID is positive before accepting a local server. Command draining is bounded
to 64 per tick. Build and 4 existing CTests pass, not live native input proof.
No updated plugin was loaded. Rust-side encoding/auth wiring and conflicts with
device-level capture ownership still need verification before live input tests.

Reserved distinct native tags 50/51/52/53 for begin/move/end/result. Added
strict little-endian parser for begin (now 56 bytes including captured surface), move (32) and end (8).
Generation/target/PID/deadline/extent constraints are checked; truncated or
wrong-length messages, nonfinite/negative coordinates and device-input tags
are rejected. Native deadlines are explicitly CLOCK_MONOTONIC nanoseconds,
not the network peer's process-clock epoch. New command-parser test and the
3 prior CTests pass (4 total), and plugin builds. Dispatch to native session,
result serialization, Rust-side native IPC encoding and connection-generation
binding are still pending; no input command is consumed or injected yet.

## Native motion session candidate

Session expiry is now backed by a compositor event-loop timer, independent of
incoming events and output redraw. A tick listener ends revoked/invalid active
targets; end cancels/removes the timer and listener before focus cleanup. Missing
event-loop manager or an already-expired grant produces an ended session.
This compiled against installed 0.56.2; existing 3 CTests pass but do not exercise
the new timer/listener behavior. IPC ownership/disconnect integration and live
native session tests remain pending.

Added `window_pointer_session.{hpp,cpp}` to the Viewflow plugin build. This
compositor-thread-only object resolves the bound target, checks local event and
lease deadlines, sends seat pointer focus/motion/frame without global cursor
warping, and stops when focus is no longer its owned surface. End/destruction
restores prior mapped surface focus only if ownership and target safety still
hold; revocation/takeover never restores over another actor. No pressed buttons
or keys are owned yet. Prior local-coordinate snapshot uses the 0.56.2 private
SeatManager field, isolated in this implementation under the existing plugin
ABI-hash guard. Build and 3 existing CTests pass, but they do not exercise this
native class. There is no IPC call site or live instance yet. The caller must
add expiry polling and disconnect cleanup before enabling it; force-lock and
non-mouse/keyboard takeover coverage also remain incomplete.

## r53 native target binding candidate

Additional lifecycle hooks revoke on main-surface unmap/destroy and on any
committed extent differing from the grant's bound extent, even if a later commit
restores that size. The session-lock `newLock` event revokes existing targets;
binding while already locked fails. Both compile against installed 0.56.2.
`forceLock()` does not emit newLock in this Hyprland source: transient forced
lock/unlock between resolves still needs a lock-notify integration before this
can be accepted as a complete lock lifecycle. No live injection is enabled.

Follow-up adds move-safe shared lifetime state with weak callback captures.
The exact source window's unmap event irreversibly revokes the target, including
same-object remap. Compositor mouse move/button/axis and keyboard events revoke
without cancelling local input. Explicit revoke is available for disconnect.
Observed identity/extent mismatch and lock/grab/exclusive-layer denial also
revoke, rather than allowing reuse after the condition clears. This does not
yet observe transient lock/resize changes entirely between resolve calls; those
lifecycle hooks remain needed. Build and 3 existing CTests pass, but the native
listeners have not been exercised live and no injection is enabled.

`platform/hyprland-plugin/src/window_input_target.{hpp,cpp}` now compiles into
the Viewflow plugin against installed Hyprland 0.56.2. It retains weak references
to the exact window/main surface, checks PID, current mapped/hidden state and
unchanged surface extent, resolves input-region-aware subsurfaces, and rejects
lock/seat-grab/exclusive-layer states. It performs no input sends and is not yet
instantiated. XWayland is explicitly unsupported at this boundary pending its
activation/scaling/related-window implementation. The owning session must revoke
on unmap/close (including same-object remap), human takeover and disconnect;
this resolver does not implement those lifecycle listeners. Coordinates are
surface-local; the native caller still needs the verified content-to-surface
offset. Build: `/tmp/viewflow-window-input-r53-build`. No live plugin load or
input injection was performed. Existing CTests do not exercise this native class.

## Window motion wire boundary (2026-09-05)

Replay follow-up: after peer/target/geometry and point validation, the grant
now consumes the sequence before checking clock availability/expiry. An event
rejected with no clock or at its deadline cannot be replayed after clock
correction; a genuinely new sequence remains eligible. All 5 window-input tests
and core library Clippy pass. This aligns with existing device-input timing
rejection semantics; it does not enable a producer or backend.

Core now also has a connection-local `WindowPointerGrant`: source-created
owner/device/generation/presentation binding, local lease expiry, irreversible
revocation, and consume-before-injection sequence validation. It requires an
externally authenticated owner and conservative clock-mapped event deadline;
neither comes from trusting the event. Only the same window/epoch can advance
to a newer verified presentation; resize requires new authorization. Pointer
mapping uses PresentedInputGeometry. Core 46/46 tests and library Clippy pass.
This grant is not yet installed by a daemon/backend; native injection remains
disabled. A native target-lifetime binding and clock mapping must be wired next.

Runtime deadline validation is now factored as `conservative_input_deadline`,
returning the actual safe local timestamp after offset, uncertainty, sample-age
and drift checks. Existing device input calls it; its ReleaseAll exception stays
outside the shared function so window motion cannot inherit a zero-deadline
bypass. All 11 input-runtime tests pass, including exact returned deadlines for
positive/negative clock offsets with aged samples. The window grant call site
and native target binding are still pending; this refactor alone enables no input.

Added distinct protobuf envelope tag 29 `WindowPointerMotion`, carrying target
device/window, lease generation, geometry epoch, presented frame, event sequence,
sender deadline, and integer client viewport coordinates. Domain parsing rejects
missing/zero identities, zero deadlines, empty viewports and half-open outside
points. A protobuf legacy-device-input decoder test confirms this cannot decode
as tag 25 global InputEvent. No protocol capability is advertised and no producer
sends this message yet. A window-scoped lease and native backend must be bound
before enabling a producer; the existing device lease is not sufficient.

Coordinator and both daemon receive loops explicitly reject this message until
the window runtime is implemented. This is a protocol boundary, not completed
input forwarding. Protocol 24/24 and core 43/43 tests pass, protocol library
Clippy passes with warnings denied, workspace/all-target check passes with the
existing cfg-dependent coded-peer warnings. Native injection was not enabled.

The decorated real-time Windows preview currently displays frames but its
WndProc only handles destruction. Device-level HID is not a window input
implementation: existing input events bind a target device, not the captured
window and its committed geometry epoch. The old window-addressed Deskflow
messages are rejected by the current runtime. Do not enable global injection
as a substitute for addressing the captured window.

## Implemented geometry foundation

`CaptureGeometry::slice_pixel_to_content` maps a pointer in the actually
rendered destination pixel rectangle through a cropped capture slice into
source content logical coordinates. It handles different capture/destination
DPI and half-window clipping. Source decorations, outside/half-open viewport
edges, malformed crop bounds and nonfinite coordinates are rejected. The
caller must first remove destination letterboxing and must separately bind
window identity, committed geometry epoch and input lease.

Core tests: 41/41 passed, including clipped 2x capture to 1.5x presentation,
decoration exclusion and invalid bounds. Library Clippy with warnings denied
passed. All-target Clippy remains failing on five pre-existing exact floating
point assertions in the split-window decoration test; no lint was suppressed.

`PresentedInputGeometry` now keeps window ID, committed geometry epoch, frame
identity and crop geometry together. Its mapping rejects a mismatched window,
epoch or frame; zero identities cannot construct a context. This is a geometry
binding, not an authorization/lease grant. Core tests now pass 42/42 and library
Clippy still passes. Native/peer pointer acquisition is being wired separately;
none of these helpers by themselves inject input.

## Remaining runtime wiring

- Collect native preview input only for the displayed frame's identity/epoch.
- Carry a window-scoped identity and geometry version through authenticated
  control, not just target device.
- Resolve the same source window/surface without injecting into another
  focused application. Reject stale handles, epochs and lost authorization.
- Maintain pressed-state ownership and release on focus/lease loss or closure.
- Route decoration actions separately from client content input.
- Exercise real pointer, keyboard, drag, scaling and resize behavior. Unit
  coordinate mapping alone does not establish that any input reaches Dolphin.

The local Hypr-ComputerUse-MCP plugin contains direct seat/surface input code;
it is a candidate for source-level reference, not yet an installed Viewflow
input backend. No plugin reload or live input was performed for this change.

Source review found target selectors bound to Hyprland address, PID and process
start time, with mapped/surface checks and subsurface-local coordinate
resolution. These are useful binding requirements. Its timed focus restoration
and one-shot click/drag dispatchers are not suitable as a per-event transport
for continuous remote drag: Viewflow needs one cancellable, lease-owned target
transaction, explicit release and restoration on abort/human takeover, and
session-lock/seat-grab checks. The compositor-private API is a native backend
boundary; Rust control must not directly substitute public agent dispatchers
or global input injection for authenticated window routing.

## Diagnostic acquisition implementation

Native `--emit-pointer-motion` is opt-in and requires compressed stdin plus
v4 deadline enforcement. It reads signed WM_MOUSEMOVE client coordinates and
the actual client viewport. Only a successfully committed frame, after its
Submitted record has been flushed, becomes the current pointer identity.
Warmup/expiry do not replace it. Zero identities and invalid/outside points
produce no event. HWND state is detached before destruction. De-duplication
includes viewport size, so resizing does not silently reuse old coordinates.

The receiver has the same explicit option and parses a distinct typed record:
`pointer-motion frame_identity=N x_pixels=X y_pixels=Y viewport_width=W viewport_height=H`.
It validates canonical values and bounds, and requires the most recently
observed Presented identity. Pointer records never enter the ACK slot. Only
one latest motion is retained; a new Presented clears it. Diagnostic output
has a saturating limit of 32 records. Unexpected events while disabled fail.

Portable C++ tests pass; peer tests 40/40 and Clippy pass for source SHA256
`6443de0d72227169118c3bd699ee167aa91b12e087f21481e918b6b16e06c5db`.
Windows candidate builds passed as recorded below. No live pointer acquisition
or Linux injection has been verified. The synchronous native stdout path can block
the UI if its consumer stalls; it is diagnostic-only, not the final real-time
input transport. No button, keyboard, focus capture, or cross-host forwarding
is enabled by this option.

## r25 Windows build evidence

- Native Release and CTest 12/12 passed. Staging
  `C:\Users\wilf\AppData\Local\Temp\viewflow-r25-pointer-motion-20260905-7KQ2`;
  executable `native-build\viewflow_windows_composition_preview.exe` SHA256
  `f5ed82836f04ffdd6a4b59ed6850c569ec43c2722af64bd98218428be68c8f0b`.
  Archive `6943a0f105eb8f60ddb3e2f7fcac98d4d3d91b5b19ae4ccee196557c447c6320`;
  main source `f1ffe1f6b2c87bc0e2aa22deb68ecb69063110ef012ce2ca6da8bd470ad93f18`.
- Rust offline/locked Release and Windows example tests 41/41 passed. Staging
  `C:\Users\wilf\AppData\Local\Temp\viewflow-pointer-motion-r25-20260905-7C4F`;
  executable `rust-source\target\release\examples\coded_window_peer.exe` SHA256
  `5f909e042cd61359970ac2bcb69565907db99dfc913cbe92bc11dddf2d669777`.
  Archive `8efb8eaedbb9453bcca1b4729f2e2e2aaa2a6ccbc8b743fc0123786050256634`.

Builds used two jobs, with no GUI launch, injected input or persistent service
change. Workers exited. These are build/test candidates, not deployed interactive
window support. Next runtime check must exercise actual preview window messages
and confirm the typed event carries the displayed identity and viewport.

The first r25 runtime probe failed in its PowerShell harness before sending
any messages (0 pairs, 0 messages, no presenter selected). The typed parameter
`[string]$Presenter` collided with lower-case `$presenter` state: PowerShell is
case-insensitive, so null/object assignments were coerced to strings and `.PID`
failed. Receiver PID 28016 was stopped by the harness; collector verified no
diagnostic processes/UDP 44339 endpoint and removed the r25 task. This is not a
pointer-acquisition PASS. Preserve the failed terminal evidence at
`/tmp/viewflow-warmup-three.7ETt2i/terminal-r25.json`; fix in a fresh r25b runner.

r25b fixed the parameter collision and passed a PS5.1 object/null selection
fixture (the original runner is rejected by the same check). Live receiver
PID 4860, presenter PID 12348, HWND 0x310012: 8 synthetic WM_MOUSEMOVE messages
posted in 4 pairs, no probe errors. Six typed events arrived, associated with
presented frames 115, 175 and 213. The stream delivered 237 fresh ACKs and 49
recoverable rejections before its configured sender timeout. Collector verified
all diagnostic processes and UDP endpoint gone and removed r25b's task.

Coordinate precision did NOT pass: requested (40,40)/(80,80) arrived as
(80,80)/(160,160), with physical viewport 1626x1240. Cross-thread DPI
virtualization in the synthetic sender is a hypothesis to test with an explicit
Per-Monitor V2 thread context. This proves the running native-to-receiver event
path, not real hardware input, accurate mapping, or Linux window injection.
Raw evidence: `/tmp/viewflow-warmup-three.7ETt2i/terminal-r25b.json`.

The r25c probe adds a thread-only Per-Monitor V2 DPI context around each
PostMessage and restores the previous context in finally. Its PS5.1 parser and
object/null fixture passed. However, both r25c and a fresh r25d retry failed
before any pointer messages or video frames: native initialization stopped at
`compressed-gpu-compositor`. r25c reported the presenter's five-second readiness
timeout; r25d required the harness's 35-second process-tree watchdog. Both
collectors verified no diagnostic process/UDP 44339 endpoint and removed their
tasks. No DPI accuracy PASS is claimed. Video-controller readback reported
Intel Graphics status OK/error code 0 and Session 1 DWM responding; this does
not prove GPU device initialization is healthy.

Raw terminal hashes:
- r25c `2f395891bcc2cb4474a0425692c484e010e1b15480e2ea3a83fa36219029aa55`.
- r25d `dcd332b165ffb98234367dc8b60c213f9fa38fa7f00dbd3e4e5c6d5ff9729564`.

To diagnose without more blind retries, native compositor source now has
opt-in `VIEWFLOW_GPU_INIT_TIMINGS=1` stage tracing around device/manager,
decoder, media types, shader and streaming initialization. It adds no
per-frame work and does not change timeouts. Current compositor source SHA256
`17fefd9f17b58974f6e4b401c6132945f9cce747eaa2c0c29feaefed844bfd43`;
Windows build and execution of this new trace source are pending. Existing
r25 binaries do not contain it. No driver reset, VM restart, or NIC change
was performed.

## r26 initialization trace result

Fresh Windows native Release build and CTest 12/12 passed, using source archive
`3c32b3db9c9adb5349ac5468f52d7a8f235e221b4c75036236fd3455c32857dc`.
EXE SHA256 `bf000ca6d50a79dcb862b5cd7b59d58611dbc53d145603d766cc280884816d85`,
at `C:\Users\wilf\AppData\Local\Temp\viewflow-init-r26-m1ogxA\build\Release\viewflow_windows_composition_preview.exe`.
Build log: `/tmp/viewflow-init-r26.m1ogxA/build.log`.

The bounded r26 run reached `begin-streaming` at 199,239 us, but never logged
`start-stream` before presenter readiness timed out. Hardware-device creation,
DXGI manager, decoder creation/device attachment, input/output media types,
shader compilation/creation and video context setup all completed first. This
localizes the observed stall to the call bracket around
`decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)`; it does not
prove the driver-level cause or justify a GPU/VM reset. No video frame or
pointer message was sent. Receiver PID 21500 and presenter PID 21384 exited;
collector confirmed no diagnostic processes or UDP endpoint and removed r26's
task. Outer watchdog did not fire for r26. Raw evidence:
`/tmp/viewflow-warmup-three.7ETt2i/terminal-r26.json`.

Next diagnostic should isolate decoder begin-streaming rather than repeating
the whole pointer probe or extending the frame deadline. DPI precision and
source-window input injection remain unverified.

Source review after r26 found no D3D multithread protection on the device
shared with the decoder. [Microsoft's D3D11 decoding guidance](https://learn.microsoft.com/en-us/windows/win32/medfound/supporting-direct3d-11-video-decoding-in-media-foundation)
recommends enabling it to avoid some decoder-buffer deadlocks. This is a
specific missing safeguard, not proof of the observed begin-streaming cause.
The r27 candidate now queries ID3D10Multithread, enables protection and requires
GetMultithreadProtected to read back true before creating/publishing the DXGI
manager. The setter's return is correctly treated as previous state, not HRESULT.
No timeouts, media deadlines or decoding fallback changed.

r27 native Release and CTest 12/12 passed. Source SHA256
`01b15f09c0839e13edb54b9c8ec832b758ed5bb44ad58488b20c365500e1458f`;
archive `8897af9bbd0c119aa938a512efc7ccd147bbb575133d4af7b97bed15114f8a71`;
EXE `5cbb6453ead8a3311420bf87c2bcc16c18163f033cbfee28953e619736ec1c87`
under `C:\Users\wilf\AppData\Local\Temp\viewflow-mt-r27-DnBLUx\build\Release`.

The bounded live trial did not establish recovery: sender startup timed out,
and no terminal JSON was produced. A readback observed presenter PID 22208
remaining after the receiver disappeared; a later readback confirmed it gone
without a manual kill. Final task state was Ready, LastTaskResult 267014,
with zero diagnostic processes and UDP endpoints. Only then was the exact r27
task removed. Evidence is `/tmp/viewflow-mt-r27.DnBLUx/cleanup.log`.

This exposes a harness limitation: ReadToEndAsync completion can remain pending
when a descendant retains a redirected pipe after the receiver exits, beyond
the WaitForExit watchdog. The outer scheduled-task limit can then remove the
runner before final JSON is written. Do not claim an exact r27 native blocking
stage from missing output. Before another live attempt, bound descendant/pipe
cleanup and persist diagnostic streams during execution rather than only in
the final receipt. The multithread fix remains a validated source/build safeguard,
not a demonstrated fix for the live stall.

## Bounded persistent capture harness

Fresh `run-coded-persistent-probe-r28.ps1` continuously copies the redirected
byte streams to create-new WriteThrough log files. Completion now waits at
most 500 ms per pipe, reports stdoutComplete/stderrComplete, and snapshots
at most 8 MiB per file rather than waiting indefinitely for descendant EOF.
Snapshots explicitly allow the active writer; the first fixture exposed that
File.ReadAllText's default sharing mode was incompatible, and that was fixed.

A Windows PS5.1 delayed-EOF Stream fixture passed: bytes were readable from
disk while EOF was withheld, the 500 ms wait returned, and the pump completed
after EOF was released. This exercises the .NET persistence/wait mechanism,
not the full process-tree cleanup path. Runner SHA256:
`f6a6758adafdebb19bbb81984af20ad37b3257b8306b4b46d54e3bb2105d2879`.
The r28 live run completed with exit 1, no outer timeout, both pipe completion
flags true, and zero pointer messages. The native trace still stopped at
BEGIN_STREAMING (148975 us). Collector verified no diagnostic process or UDP
listener and removed the exact task. Native startup is not fixed.

## r29 apartment initialization contrast

Added a standalone `windows-video-compositor/init_probe.cpp`, accepting only
`sta` or `mta`, with a 10-second self-process watchdog covering initialization
and teardown. It does not display a window or alter the presentation deadline.
Fresh Windows Release build succeeded (standalone project has no CTest cases).
Binary SHA256: `99338a29408c0734435b3ae50db15f88fc69405870cd826ea2dcc863d64b0155`.
Archive SHA256: `a854f6755e20ed8f791c804a0b7955ccf496273ee2c8857c504e0bab75059fa4`.

Both probes ran in interactive Session 1, STA then MTA. STA reached
BEGIN_STREAMING at 208612 us and hit the watchdog. MTA reached that stage at
188266 us, START_OF_STREAM at 3571730 us, and finished at 3572788 us with
Create HRESULT S_OK. The PowerShell receipt exit fields were null, so they are
not exit-code evidence; stdout/stderr provide the observed outcomes.
Evidence directory: `/tmp/viewflow-apartment-r29.fHFGfJ`.

This supports investigating an MTA-owned decoding worker rather than changing
UI apartment settings blindly. It is one ordered contrast, not proof of a
general driver fix, continuous video correctness, or latency acceptance.

## r30 MTA-owned decoder candidate

`mta_video_compositor.h` now owns decoder creation, Submit, Finish and destruction
on one COM MTA worker. The UI stays STA. Synchronous single-caller handoff keeps
input spans alive and preserves existing absolute deadline checks; no extra
frame queue or deadline renewal was added. D3D device access is serialized by
the handoff and the existing multithread protection. Startup and shutdown waits
remain unbounded inside this diagnostic process (external trial watchdog still
required); this is not a production cancellation solution.

Fresh Windows Release build and all 12 existing CTests passed. Those tests
cover existing parsers/admission/pointer helpers, not the MTA worker runtime.
Native candidate: `C:\Users\wilf\AppData\Local\Temp\viewflow-mta-r30-lM2TCG\build\Release\viewflow_windows_composition_preview.exe`.
Binary SHA256: `794934e15721c27fda370cc3e51a6f2cd96394fc80a22c11df66dd9ab44f3214`.
Source archive: `/tmp/viewflow-mta-r30.lM2TCG/native-source.tar.gz`, SHA256
`35c9745b64cef6bffb0986f259b696df12716f644f9ba5fb9f2141414295ef72`.
Continuous Dolphin preview, DPI pointer probe and physical latency acceptance
remain pending.

r30 live launch subsequently failed before any capture/frame ACK. Native reached
BEGIN_STREAMING at 161144 us but did not log START_OF_STREAM before startup
timeout. Thus the standalone r29 MTA success did not reproduce in the preview.
The runner produced terminal evidence with both pipe-completion flags false;
the first collector found a remaining diagnostic process. A path/session-checked
attempt to kill presenter PID 22900 returned access denied, not success. A later
fresh collector verified zero diagnostic processes/UDP listener and removed the
task (`/tmp/viewflow-mta-r30.lM2TCG/cleanup-recheck.out`). No live process remains
according to that boundary check.

The next source candidate moves MFStartup/MFShutdown themselves from the UI STA
onto the decoder MTA, matching the successful probe's lifecycle more closely.
This change is not yet rebuilt or runtime-tested; the r30 binary above predates
it. Do not infer a fix from the source change.

## r31/r32 startup contrasts

r31 moved MF startup/shutdown to the MTA. Windows build and 12 existing tests
passed; binary SHA256 `d208f8202e30e0bdf9ee270b57c51be19dd122b442a698cd614ccc9187dca139`.
Live startup still stopped at BEGIN_STREAMING (168194 us), zero frames/ACKs.
Both log pumps completed; collector verified zero diagnostic processes/port
and removed the task. Evidence: `/tmp/viewflow-mta-r31.IesqfE/collect.out`.

r32 additionally initializes the decoder before creating the UI STA/Dispatcher.
Windows build and 12 tests passed; binary SHA256
`89125d2c1d2fc420de56033bf780ab2dc78285cf867a420891a496986af573c1`.
Live startup again stopped at BEGIN_STREAMING (163843 us), zero frames/ACKs.
Thus neither contrast establishes a fix. Recheck standalone MTA initialization
repeatability before attributing the failure to apartment choice.
Evidence: `/tmp/viewflow-mta-r32.ZErSWc/collect.out`; first collector found a
remaining presenter, so its terminal receipt is not cleanup proof.
The exact PID/path/session/start-time checked Kill attempt returned access
denied. A subsequent collector succeeded and verified no processes/port and
task removal (`cleanup-recheck.out`); do not attribute exit to that failed Kill.

## r33 standalone MTA repeatability and cold-start allowance

Two sequential fresh processes using the frozen r29 probe both returned exit 0
and Create S_OK in Session 1. Initialization finished at 7993310 us and 887932 us
respectively, with most time in BEGIN_STREAMING. Evidence:
`/tmp/viewflow-apartment-r29.fHFGfJ/repeat-mta-1.json` and `repeat-mta-2.json`.
The collector confirmed no probe process and removed the exact r33 task.
This shows cold startup can exceed the previous 5-second readiness allowance;
it does not prove that every preview timeout had this cause.

The Rust example now has a separate 15-second PRESENTER_COLD_START_WAIT for
READY only. Decode-only warmup retains its old 5-second allowance; live frame
freshness remains 33333333 ns. The enclosing session timeout still applies.
Local default-feature example tests: 39 passed (feature-disabled warnings remain).
The new invariant test checks the constants, not a real cold-start interaction.
Windows receiver rebuild and live validation are still pending. The next sender
trial must allow a 30-second session startup window; that is not a frame budget.

## r34 cold-start allowance live result

Fresh Windows receiver build succeeded and 42 Windows example tests passed.
Receiver SHA256 `4319435fd790d83b6141cf142728fb68238d9075d96bc85116d0b3235d7d5f93`.
Source snapshot was assembled from `rust-source.tar.gz` (SHA256
`885c10bf0d1682ebcb097222c0fd39ea2d9edf7f1d8e2fbeb34d2aa18b825ef7`)
plus `protocol-source.tar.gz` (SHA256
`95e1c9d6ed8b1b64db086ffee5884834b1a98183fbdef24428aeba78a368e94a`).
Both archives and build log are under `/tmp/viewflow-cold-r34.lwkzaH`.

Using unchanged r32 native preview and 30-second sender/session allowance,
the 15-second READY wait still timed out at BEGIN_STREAMING (183726 us).
Zero frames/ACKs. Collector succeeded, both pipes completed, no diagnostic
processes/port remained and task was removed. Evidence: `collect.out` in that
directory. Cold startup duration alone is not a sufficient explanation.
Next useful contrast: the standalone successful probe uses the main MTA thread,
whereas the preview initializes on a worker MTA. Test that difference in the
bounded probe before another production-path architecture change.

## r35 worker/main probe

The standalone probe now accepts `worker-mta`; the same initialization and
teardown execute on a joined worker, under the unchanged self watchdog.
Fresh Windows build succeeded (standalone project has no CTest cases).
Binary SHA256 `d61dc6adf55dd45949f94049037fb28a2694207354e44893fc9feb5009187b27`;
archive SHA256 `cdf3d9eacf4bb5c8da6bc17005d0ad4c2f967f0cc3f87edc71615a6f7de8f860`.

Worker MTA run returned exit 0/Create S_OK, initialization finished at 7033471 us.
The following main-MTA run did not produce its JSON receipt; task returned 1.
The harness does not persist streams before its timeout branches, so no specific
failure phase or exit code can be assigned to that second run. Do not report a
completed two-case comparison. Evidence: `/tmp/viewflow-worker-r35.b7H2Ax`.
Fresh process check found no remaining probe; exact task removed (`cleanup.out`).
Worker MTA is demonstrably capable of initializing, but startup reliability
remains unresolved. Persist timeout-path evidence before more probe repetitions.

## r36 persistent timeout evidence

Added `platform/windows-video-compositor/run-init-probe.ps1`: create-new
WriteThrough stdout/stderr, bounded process/pipe waits, and a receipt even when
the process fails to exit. It stops without launching another probe in that case.
It does not claim to forcibly terminate an unresponsive driver call.

Real Session 1 run of the unchanged r35 binary in main-MTA mode produced:
PID 21236, exited=false after 15 seconds, both pipe completion flags false.
Persisted stderr reached BEGIN_STREAMING at 174888 us and then recorded the
10-second self-watchdog timeout. Thus standalone main MTA is not reliably
successful either; the apartment hypothesis is insufficient. The self-termination
request was not observed complete within the outer wait.

Evidence: `/tmp/viewflow-worker-r35.b7H2Ax/r36.json`, `.stdout`, `.stderr`.
A subsequent fresh check found no probe process and removed the exact task
(`check-r36.out`). A limited query of the most recent 30 System warning/error
events within 20 minutes printed no selected graphics-provider events; this
is not exhaustive proof of driver health. No GPU reset/reboot was performed.

## Minimal H.264 input metadata candidate

Removed hardcoded 256x256, 30 fps, High/Level 2.1 input metadata from compositor
initialization: these fixture values are not the live window's stream metadata.
The [Microsoft H.264 decoder contract](https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-decoder)
allows major type and H.264 subtype alone, followed by output format change once
the bitstream supplies details. Existing Drain handles STREAM_CHANGE and updates
the output type. This is a correctness change, not proof of the startup fix.

Opt-in initialization logging now records actual selected adapter vendor/device,
LUID and D3D feature level. GetDesc1 failure is checked. No adapter preference,
software fallback, driver reset or frame deadline change was introduced.

The r37 minimal-input probe was built and run in Session 1. Binary SHA256
`b25c09292d7ec23c06d07f8e5a5f683311a37db581e31c834a3e0d62af9c4028`.
Selected DXGI adapter index 0, vendor 8086/device 7d67, LUID 00000000:00005e98,
feature level b000. It still reached BEGIN_STREAMING at 190223 us and hit the
10-second watchdog. Receipt reports exited=true, exit=124, both pumps complete.
Thus correcting input metadata does not establish a startup fix. Collector
verified no remaining probe and removed the exact task. Evidence directory:
`/tmp/viewflow-minimal-r37.HmHcae` (`r37.json`, `.stderr`, `check.out`).

Next diagnostic boundary is direct D3D11 hardware decoder creation, bypassing
the Media Foundation transform, to distinguish that wrapper from driver-level
decoder allocation. Do not reset the physical host GPU to test this hypothesis.

## r38 direct D3D11 decoder allocation

Added direct-d3d probe mode (no MFStartup or MF transform), using adapter 0,
H264_VLD_NOFGT, 256x256 NV12 and the first reported raw-bitstream-2 config.
Configuration enumeration follows the [D3D11 API contract](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11videodevice-getvideodecoderconfig).
The initial link needed dxguid; corrected Windows build succeeded.
Binary SHA256 `0bfd8301a90b804abad9c45e02c44e815cdf3ac7f0129cc27ff5cb8dcc8ba9c4`.
Final archive SHA256 `16761af66490bc93e68834729fc83325866bb3d953d1a7e2c9ffb16a1b291bb5`.

Real Session 1 run selected Intel 8086:7d67, configuration 0/raw 2, and
CreateVideoDecoder returned S_OK. Process exit 0, both pipes complete. Collector
verified no probe and removed task. Evidence: `/tmp/viewflow-direct-r38.qcA1Ir`.
This proves one direct decoder allocation works, not bitstream decoding or
driver health under streaming. The MF startup path remains suspect but a driver
interaction specific to its configuration is not excluded.

## r39 MFTrace startup evidence

Used installed x64 SDK MFTrace, child tracing disabled and only IMFTransform,
MFPlatExport and Ole32Export hooks, against the frozen minimal-input r37 probe.
The trace identifies inbox msmpeg2vdec.dll and shows its placeholder output is
1920x1080 NV12, 30000/1001 fps. BEGIN_STREAMING at 15:54:47.40344 UTC returned
before START_OF_STREAM at 15:54:55.05207 (approximately 7.65 seconds), followed
by END_OF_STREAM and MFShutdown. Tracer exited within 20 seconds, no remaining
probe in the receipt. Evidence: `/tmp/viewflow-minimal-r37.HmHcae/r39-mf.log` and
`r39.json`. Trace timing is instrumented, not performance acceptance.

This successful trace does not explain intermittent hangs. It exposes a mismatch
in the previous allocation contrast: direct D3D used 256x256, while minimal-input
MF negotiated 1920x1080. Align dimensions before inferring an MF-only fault.

## r40 aligned 1080p direct allocation

Added explicit direct-d3d-1080 mode and a host duration measurement around
CreateVideoDecoder only. Windows build succeeded, binary SHA256
`0196a2b32a4fc2889bd25a19e46cfa15af352deab31e6d962a89a547b17a7cea`.
Session 1, same Intel 8086:7d67, config 0/raw 2, 1920x1080 NV12: S_OK in
12930 us. Exit 0; both pipes complete; no remaining probe and task removed.
Evidence: `/tmp/viewflow-1080-r40.Yq16KC/r40.json`, `.stderr`, `check.out`.
Dimensions alone do not reproduce the long MF startup. Surface allocation,
device-manager interactions and MF-specific configuration remain untested.

## r41 stack capture attempt (not valid stack evidence)

Installed CDB was invoked against the exact independently launched probe, but
returned `Invalid switch 'n'` and usage, not stacks. The original harness only
checked debugger process completion, so its debuggerCompleted=true is not
success evidence. Probe exited; fresh cleanup confirmed neither probe nor CDB
remained and removed the task. Artifacts: `/tmp/viewflow-minimal-r37.HmHcae/r41*`.

The local capture harness was corrected to use nonsuspending noninvasive `-pvr`,
ignore symbol environment and select an explicit local symbol path, and require
zero debugger exit plus stack-header evidence. That corrected harness has not
yet run; next execution needs fresh output/task names.

## r42/r43 stack evidence

r42 nonsuspending attach did not reach stack output before the debugger budget.
After interruption, fresh inspection confirmed no probe/debugger; task removed.
r43 used noninvasive suspending attach for the independent probe and a 15-second
debugger allowance. Actual thread stacks were captured and the log reaches qd.
The harness flag remains false because its header regex expected Child-SP,
whereas this CDB emitted RetAddr/Call Site; do not use that flag as stack absence.

Thread 0 snapshot: ntdll!NtSetInformationThread ->
KERNEL32!SetThreadAffinityMask -> msmpeg2vdec offsets -> probe. Intel driver
workers mostly show condition-variable waits. Private MF symbols are absent;
export-nearest labels such as DllUnregisterServer are not actual function names.
This single snapshot motivates a decoder-worker-count/CPU-affinity contrast,
not a conclusion of GPU allocation deadlock or proven root cause.
Evidence: `/tmp/viewflow-minimal-r37.HmHcae/r43-stacks.log` lines 54 onward.
Probe exited; fresh cleanup confirmed no probe/CDB and removed the r43 task.

## r44 explicit decoder-worker contrast

Added optional diagnostic_workers=2 to compositor Create; default zero leaves
the decoder setting untouched. The probe exposes mta-two-workers only; the
preview still uses the default. SetUINT32 and readback are checked. The
[documented property](https://learn.microsoft.com/en-us/windows/win32/medfound/codecapi-avdecnumworkerthreads)
describes value 1 as decoder-selected, so this is not called a single-thread test.

Windows build passed, binary SHA256
`6174812b1322b3b76568286ff1688923d65648a237684d29a13e5dc32d581b0d`.
Session 1 trial read back decoder_workers=2, reached BEGIN_STREAMING at 159846 us,
START_OF_STREAM at 2776640 us and finished at 2776660 us. Exit 0, both pipes
complete; collector confirmed no probe and removed task. Evidence directory:
`/tmp/viewflow-workers-r44.b4stam`. One success does not establish reliability or
continuous decode throughput. Do not enable this setting globally on this alone.

r45 repeated the identical probe/configuration in a fresh process: exit 0,
START_OF_STREAM at 1128213 us, finished at 1128237 us; both pumps complete and
cleanup verified. Evidence: r45 files in `/tmp/viewflow-workers-r44.b4stam`.

The r46 preview candidate adds explicit diagnostic environment opt-in
VIEWFLOW_DIAGNOSTIC_DECODER_WORKERS=2; unset preserves default and nonempty
invalid values fail initialization. This does not change live frame deadlines.
Windows Release and 12 existing CTests passed, but these do not exercise the
new worker setting's continuous decode path. Binary SHA256
`3535031e15ef84415bc5f82dcb1ee0316f61651c1ce30fa7b48e31e9aa9ffcc5` at
`C:\Users\wilf\AppData\Local\Temp\viewflow-preview-r46-WqdfAd\build\Release\viewflow_windows_composition_preview.exe`.
Source archive SHA256 `3262aedbdea8cf98278866d2dce001d50466468a517317e136ca89a151e77517`,
under `/tmp/viewflow-preview-r46.WqdfAd`. No r46 live launch yet; next harness
must explicitly set the opt-in in the child's inherited environment.

r46 live trial explicitly inherited decoder-workers=2. Native initialization
finished at 722092 us, then created the window/Composition objects and emitted
READY. Thus this trial passed the previously failing Windows startup boundary.
No frame was captured: Linux rejected the HyprCapture eval request (exit 7).
Fresh hyprctl inspection showed Lua provider, v0.56.2, **no plugins loaded** and
no Dolphin client. Old capture window/plugin identities must no longer be reused.
Windows collector verified no diagnostic processes/UDP listener and removed task.
Evidence: `/tmp/viewflow-preview-r46.WqdfAd/collect.out` and
`/tmp/viewflow-warmup-three.7ETt2i/sender-r46.stderr`. Next step is re-establishing
the current Linux capture fixture, preserving the user's HyprCapture repair,
before testing video throughput or pointer mapping. No live frame claim yet.

## r47 current Linux capture fixture

Current compositor PID 2913544, same v0.56.2 ABI, Lua provider. Rebuilt existing
HyprCapture source (user repair HEAD 2bb6f57 and dirty capture additions preserved)
in `/tmp/viewflow-capture-r47.DFALkc/build`; all 16 CTests passed. Loaded only the
new libhyprcapture.so, SHA256
`4b3264cb324e5fb6126173fb711c276b1ee1633a83ed53b8da0ab9b7db6ac09e`.
Plugin list reports HyprCapture 0.2.7; window_stream_start is a Lua function;
configerrors empty. No persistent config edit or compositor reload performed.

Opened a dedicated Dolphin fixture via `viewflow-dolphin-r47.service`:
PID 3061728, address 0x562206f96020, workspace 5, logical client size 2585x1579.
Monitor DP-4 is 6144x3456 at scale 2. These fresh dimensions differ from the old
813x620 decorated test; remeasure/resize this fixture before reuse of video args.
Plugin and Dolphin intentionally remain available for the next live trial;
no capture stream started in this step.

## r48 orientation failure and r49 candidate

r48 reached live video (536 acknowledged frames), but the user observed the
image upside down. This is a failed visual acceptance, not a successful video
gate. Collector `/tmp/viewflow-preview-r46.WqdfAd/collect-r48.out` verified
diagnostic process/listener cleanup. The sender ended on geometry change.

Source comparison found HCGF always requested `flipY=true`, whereas the existing
RGBA screenshot path reads the same framebuffer row interval and preserves row
order for transform 0. The r49 candidate changes only that GPU metadata flag to
false in HyprCapture `src/plugin/artifact_capture.cpp`; crop coordinates remain
unchanged. Rebuilt successfully in `/tmp/viewflow-capture-r47.DFALkc/build`, and
all 16 CTests passed. These tests do not prove live orientation. The loaded plugin
has NOT been replaced with the candidate yet; Windows visual orientation and
pointer alignment remain unverified. Rotated-output orientation is also not
proven by this normal-output candidate.

r49 live preflight found **two** HyprCapture instances in compositor PID 2913544:
the task-owned `/tmp/viewflow-capture-r47.DFALkc/build/libhyprcapture.so` old
mapping and `/var/cache/hyprpm/wilf/HyprCapture/hyprcapture.so`. The latter was
not part of the previously established r47 fixture. Both register the same Lua
namespace and named overlay rule; PLUGIN_EXIT unregisters that rule. No unload,
load, or config reload was attempted after discovering this overlapping state.
Ask the user before temporarily unloading the hyprpm-managed copy for an
isolated trial, then restore it after the trial. Current Dolphin identity and
791x598 dimensions remain unchanged. Orientation candidate remains untested live.

User authorized isolation, then explicitly authorized updating the HyprCapture
repository through `hyprpm update`. Both previous copies were unloaded and the
r49 candidate loaded alone; configerrors empty. r49 sent/ACKed 400 frames before
a GPU output-transfer deadline failure (105581661 ns late). The screenshot
trigger at pointer-probe pair 8 was not reached (7 pairs); visual orientation
therefore remains unverified. Windows collector verified process/port cleanup.

Hyprpm sources HyprCapture from the local checkout, not GitHub. Scoped window
streaming changes and orientation candidate were committed as `189020b` (29
files); checkout clean. `hyprpm update --job 4` is building this revision;
other repositories were reported up to date. No GitHub push or sudo use.

Update follow-up: non-PTY hyprpm failed at privileged cache replacement twice.
An initial ownership diagnosis was incorrect: this Hyprpm intentionally uses
root-owned `/var/cache/hyprpm` storage and sudo helpers. The narrowly changed
ownership was restored to root:root. User-authorized sudo authentication in a
PTY enabled `hyprpm update --experimental-cache --job 20` (user's preferred
flags) to exit 0. Cache state now records full revision
`189020b7f6ea1a597883f066dab5e96f298b3f9e`. Removed the task-owned temporary
instance and reloaded only the managed copy to restore its shared overlay rule;
one HyprCapture instance and empty configerrors verified. No GitHub push.

r50 managed-build live run received 1341 frames, ending at the existing 30s
session deadline. Windows startup took 6162516 us, exceeding the diagnostic
6s window-discovery deadline, so no screenshot or pointer messages were captured.
Collector verified diagnostic processes/port cleaned and task removed.
r51 extends only diagnostic window discovery to 20s and captures at pair 3;
video deadlines/configuration remain unchanged.

r51 captured `/tmp/viewflow-warmup-three.7ETt2i/terminal-r51.json.png` from the
Windows receiver: Dolphin menu, breadcrumb, sidebar text and folder labels are
visibly upright. This directly verifies normal-output orientation after the
flip flag correction. The diagnostic screenshot is DPI-cropped, so it does not
prove full-frame bounds or pointer spatial alignment. Probe posted 54 mouse-move
messages (27 pairs), no probe errors; this is not a click/drag acceptance test.
Collector `collect-r51.out` verified no diagnostic processes/listener and removed
the task. The managed HyprCapture remains installed/loaded at revision 189020b,
temporary copy unloaded, local source clean. Full Viewflow plan remains incomplete.

r52 fixes the diagnostic screenshot by applying/restoring per-monitor-v2 DPI
awareness around GetWindowRect and CopyFromScreen. Viewed the resulting
`/tmp/viewflow-warmup-three.7ETt2i/terminal-r52.json.png`: full 1626x1240 preview
bounds, all four outer edges/corners, upright menu/breadcrumb and folder labels.
This resolves the screenshot-harness cropping seen in r51; it does not establish
pixel-perfect source matching, every output transform, or click/drag behavior.
Windows `collect-r52.out` confirms diagnostic process/port cleanup and task
removal. No production frame deadline or presenter code changed in this trial.

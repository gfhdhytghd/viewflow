# Windows GPU composition pipe smoke, 2026-09-04

An actual NVENC-generated three-frame 256x256 fixture travelled through the
VFGP parser, MF High H.264 GPU decode, GPU color conversion plus independent
Gray8 alpha, and the same-device Composition drawing-surface copy.

The noninteractive SSH attempt failed at host-backdrop enable with
`0x80070005`; it did not reach rendering. A subsequent limited-privilege
interactive-token task for `windowsvm\wilf` succeeded, exit 0, empty stderr,
no write error or timeout. Its stdout acknowledged exact identities 1, 2, 3
with dimensions 256x256. The temporary task
`ViewflowGPUCompositionSmoke-20260904-2207` was removed and absence verified.

Preview executable SHA256:
`40c5401964a841d0d4f5853e2b96da99ec83295e94bf37eeea08026db673f398`.
Remote terminal log:
`C:\Users\wilf\AppData\Local\Temp\viewflow-gpu-smoke-20260904-terminal.json`.

This establishes successful native API execution and submission, not physical
scanout, user visual acceptance, live Dolphin input, or network latency.
No UAC/firewall/Deskflow settings were changed.

## Real Dolphin coded stream trial

The prepared limited interactive task `ViewflowCodedReceiverPrepared-20260904`
was started immediately before the Linux sender. Real 1936x1732 decorated
Dolphin capture reached the authenticated receiver. Sender statistics:
114 captures, 4 pre-encode stale, 109 post-encode stale, 1 sent, 0 ACKed;
encode host time P50 11644 us, P95 12832 us. A preceding 179-frame source
probe measured capture-to-import P50 25365912 ns, P95 29228711 ns,
maximum 38273274 ns.

The receiver presenter became ready but submitted zero frames. Receiver
terminated with `media reassembly error: Late`; sender reported ACK timeout.
This is a failed latency acceptance trial, not live rendering success.
The 33.333 ms deadline was not relaxed. Receiver PID 5672 exited, port 44339
was no longer listening, and the dedicated prepared task was removed.

Two HyprCapture instances were initially loaded. The duplicate instances
were unloaded and only the existing build-codex plugin loaded for the trial;
configerrors was empty and the source probe succeeded. No plugin source,
cached production binary, or persistent Hyprland configuration was changed.

After independent early-drain and native opaque-alpha preprocessing changes,
a second real trial (`ViewflowCodedReceiverPrepared-20260904-r2`) failed before
media capture: receiver reported `compressed presenter readiness timed out`,
sender captured/sent zero frames. Fresh terminal evidence identified receiver
PID 22524; child/proxy exited, port 44339 was clear, and r2 task was removed.
Therefore the improved capture/encoding paths have no new cross-host rendering
acceptance result from this trial.

Further startup diagnosis: r3 with a 5-second pre-READY startup allowance
also timed out before capture. r4 used native stage-logging binary SHA256
`229e83ff6561fdef7e4954ca429bbe5ae5fdbe0834383fe62ceccf482378cb9d`
and reached every initialization stage through show-window and READY.
It then failed media admission with `Late`: 8 captures, 2 pre-encode stale,
5 post-encode stale, 1 sent, 0 ACKed; only 6 encode samples (P50 11575 us,
P95 12810 us), insufficient for steady-state comparison. Both dedicated
r3/r4 tasks were removed and their receiver/proxy processes exited.
The earlier startup timeout cause remains unproven; it is distinct from
the reproduced post-READY media-lateness failure.

## In-session rejection recovery trial (r5)

Windows example tests passed 11/11; receiver EXE SHA256
`29CC9ADF87AE5221E251AF50E9AAF13D2FED8C3587D123182C50B2344D737557`.
Native with explicit MF lifetime SHA256
`5305a641e349bbc601061cce3fff7f41af44788f1999c37ca85dfcdf922268ba`
reached READY. Sender recovered from six exact pre-presentation REJECTs in
the same session: 22 captures, 3 pre-encode stale, 12 post-encode stale,
6 sent, 0 ACKed, 712980 payload bytes. Sent source age P50 32.483969 ms,
P95 33.235046 ms; encode P50 11.355 ms, P95 11.917 ms (19 samples).
The run ended with sender `datagram too large`; receiver observed peer close.
This proves rejection recovery, not successful fresh presentation. The
sender's cached datagram budget requires correction for changing path MTU.
Dedicated r5 task was deleted, receiver PID 13476 exited, port 44339 clear.

## Dynamic datagram budget trial (r6)

Windows example tests 12/12 passed; EXE SHA256
`397ADAAF5310BF09BEDB415FD083D3735ABF5CBE93D9DFA4D2171AD1E0DB46BD`.
Per-plane live datagram budgeting (no in-plane refragmentation) ran to the
sender session deadline: 706 captures, 5 pre-encode stale, 436 post-encode
stale, 264 sent and exact-rejected, 0 ACKed, 0 TooLarge drops. Payload total
31218705 bytes; send source age P50 32.414381 ms, P95 33.220694 ms;
encode P50 11.183 ms, P95 12.404 ms (701 samples). Native READY succeeded;
receiver ended on peer close. No fresh presentation is proven. Dedicated
r6 task removed; receiver PID 25444 exited and port 44339 clear.

## Read-only capture and external-alpha encoding (r7)

Sealed read-only mmap import plus explicit native color-only/external-alpha
input reduced sent source age to P50 29.448582 ms, P95 32.119841 ms.
139 captures, 3 pre-encode stale, 12 post-encode stale, 124 sends,
123 exact rejects, 0 ACK; encode P50 10.565 ms, P95 12.591 ms (136 samples).
Native became ready; the admitted frame failed with `coded frame became
late during VFGP write`. Sender subsequently hit bounded control timeout.
This identifies another remaining cost: v1 expands VFAR to a full raw alpha
plane before the local pipe. It does not establish fresh presentation.
r7 task removed; receiver PID 5964 exited and port 44339 clear.

## Compressed local alpha pipe (r8)

VFGP v2 forwards fully validated VFAR without receiver-side expansion; native
decodes it under encoded and decoded resource limits. Rust tests: 6 alpha,
4 pipe, 12 example; Windows parser tests 2/2 and real Rust-generated v2 fixture
matched all 196608 alpha bytes. Native SHA256
`aea54c82884b274c974ffb13fab8dad87d8b1c579e6c83767c67d2a1661fdd37`;
receiver EXE SHA256
`1764C4C8276E68CB2DA873A3CCF2831BEDAB60929D8EAC8AC34BAB9B8C4B763C`.
Real r8 sent one 119717-byte frame at source age 26.820409 ms, but still
failed `coded frame became late during VFGP write`; no submission ACK.
This single sample is not a steady-state performance comparison. The local
pipe buffering/scheduling remains under investigation. r8 task removed,
receiver PID 22692 exited and port 44339 clear.

## Explicit pipe buffer and corrected diagnostic runner (r9)

Windows example build and all 13 tests passed, including pipe handle
inheritance and EOF. The requested stdin buffer is bounded to 1 MiB; actual
kernel allocation is not assumed. The new runner drains stdout/stderr
concurrently and records `$receiverProcessId`, not PowerShell's reserved
`$PID`. Consequently **r1-r8 recorded childPID numbers above are not reliable
receiver identity evidence**; their task/port checks are separate observations.

r9: 13 captures, 9 sends, 8 exact rejects, 0 ACK; send source age P50
28.496984 ms, P95 30.532376 ms; encode P50 9.838 ms, P95 11.379 ms
(10 samples). Failure advanced past writing to `compressed presenter ACK
timed out`. No native submission line was observed. Corrected receiver PID
7332, start 2026-09-05T03:19:19.7297096Z, exited normally with status 1.
Dedicated r9 task removed; fresh checks found zero preview processes,
zero matching scheduled tasks and zero UDP 44339 listeners.

## Decode-only startup warmup (pending live validation)

The diagnostic now transfers a single real-size IDR plus lossless alpha over
bounded reliable startup records. VFGP v3 marks this record decode-only; native
completion discards it without updating the composition tree or incrementing
presentation counters. A distinct completion/ACK unlocks READY. Live media
requires a newly captured frame and actual new IDR; its 33,333,333 ns budget is
unchanged. This does not preallocate the drawing surface, so first presentation
cost remains unverified.

Root review caught and corrected an eight-byte metadata tail offset error
before live use. Exact serialized-offset regression is included in 13 passing
native-feature example tests; five presenter-pipe tests and strict clippy also
pass. These are build/protocol checks, not evidence of continuous fresh output.

r10 native clean-build SHA256
`956baee10894382efe4d3bacef5f966ac2172118baa7a7660360e009437343bf`;
Windows example tests 14/14, native parser 2/2. Actual decode-only frame 8
completed (receiver warmup 114 ms; sender startup 3096 ms), with zero live
submissions. The sender then failed `stale HCSF frame`: warmup supplied absolute
monotonic time to the encoder lineage guard while live supplied session time.
This is a clock-domain bug, not evidence of fresh presentation. Receiver PID
16656 started 2026-09-05T03:45:45.8151015Z and exited status 1; its dedicated
task was removed after exit.

The clock-domain correction maps both warmup and live original capture times
into session time before encoder submission (no restamping). Linux example
tests now pass 14/14 including warmup-to-live lineage. Windows receiver SHA256
is `4305835aa972470c395aae0319af50d7d3e5685bbb1f29c90aa00fadc412b307`.
r11 failed at native device initialization readiness (five-second startup
allowance), before warmup or live output; receiver PID 23700 exited.

r12 warmup succeeded again: frame 8, receiver 139 ms / sender 1208 ms.
265 captures, 96 post-encode stale, 166 sends, 165 exact rejects, zero ACK.
Send-age P50 31.252762 ms / P95 33.154996 ms; encode P50 11.920 ms /
P95 13.871 ms (262 samples). Receiver PID 9876 started
2026-09-05T03:48:43.9334911Z and exited status 1 with
`coded frame became late during VFGP write`; no live submission was logged.
The steady capture/encode/transport path still leaves insufficient budget;
successful startup warmup alone does not solve it. r11/r12 dedicated tasks
were removed after exit, and each final check found zero native preview
processes and zero UDP 44339 listeners. Historical logs remain preserved.

## Unbound surface preallocation

Native warmup now allocates the correct-size drawing surface and surface brush
without attaching that brush to the visual or copying warmup pixels. Live
`update_gpu` binds it only after successful copy/EndDraw/Flush. First BeginDraw
may still have cold cost; no scanout deadline claim follows from preallocation.
Windows clean rebuild and parser CTest 2/2 passed. Presenter SHA256:
`f70442c5b6e0e90cec1cc673cbf9585be16906e06a18efa9ad267fdb9e672f4e`.

r13 isolated surface-preallocation trial: warmup succeeded (101 ms receiver),
one live send at source age 27.394154 ms, zero ACK; native ACK timeout.
Receiver PID 19936 exited status 1. This does not prove a performance gain.

## Fused RGBA-to-VFAR alpha (r14)

Direct strided RGBA alpha encoding removes the intermediate alpha allocation.
The tight-layout path has no per-pixel division; row padding is excluded.
Differential tests require exact byte equivalence to the old alpha extraction
plus VFAR encoding, including random data, run boundaries and padded rows.
Release synthetic 1936x1732, 12 iterations: old 3089 us / fused 1684 us mean;
repeat 3501 / 1867 us. These measure the alpha stage only, not end-to-end.
Transport full tests and native-feature encoder tests/clippy passed.

r14 combined trial: 15 captures, 2 post-encode stale, 11 sends, 10 exact
rejects, zero ACK. Encode P50 7.768 ms / P95 9.029 ms (13 samples); send-age
P50 28.548654 ms / P95 30.112972 ms. Receiver PID 19724 started
2026-09-05T03:54:47.6570355Z, warmup completed in 92 ms, then failed
`compressed presenter ACK timed out`. No native live submission logged.
Small, non-controlled live samples do not quantify improvement, and the
steady two-frame/scanout requirement remains unmet. Both r13/r14 tasks were
removed after exit; final process/UDP 44339 checks were zero. Logs retained.

## Failure-stage timing and bounded datagram batching

Receiver diagnostic SHA256
`2320bc46fa10579c739dea835f63bbeaa5a826f840721fbce639cf224e66585b`
adds failure-only writer timing (Windows build/tests 15/15). r15: 3 sends,
2 rejects, zero ACK. Failed frame 312 had only 831 us source budget at writer
entry; pipe write took 48 us, total writer wait 13633 us. This rules out a
large pipe write cost for that sample, not for every frame. Receiver PID
27472 exited status 1; its task was removed and final process/port counts zero.

The sender previously yielded the executor after every ~1 KiB datagram.
It now yields after bounded bursts of 16; Quinn's backpressure await remains.
Wire layout, exact rejection/IDR recovery and source deadline are unchanged.
This is a scheduling optimization awaiting live comparison, not a latency
claim. Native event-driven pipe work is tracked separately.

r16 did not reach media: native device readiness timed out (receiver PID
17756, status 1). It is not a batching performance sample. Task removed after
exit, preview/UDP listener counts zero.

The native compressed reader now uses a bounded single 64 KiB slot and a
blocking-read worker, waking the UI with an event plus message wait rather
than `Sleep(1)` polling. Parser/decoder/composition remain UI-thread-owned.
Review identified the cancel-before-ReadFile shutdown race; join now repeats
cancellation while waiting, and behavioral tests explicitly exercise pending
I/O, a forced pre-read cancellation gap, full-slot shutdown and partial EOF.
Test barriers retain only captured handles across object destruction. Windows
build/runtime validation remains required for this new reader.

Final Windows clean build and bounded CTest passed 3/3; presenter SHA256
`8494ac6e5cfd6e8f6f9c36be9f74c50eab931375afd9219754ce9eb0ee52fec5`.
r17 combined event-reader/batched-send run: clock RTT 1201 us, uncertainty
600 us; warmup completed. 174 captures, 21 post-encode stale, 149 sends,
149 exact rejects, one MTU-abandoned frame, zero ACK. Send-age P50 28.457800 ms
/ P95 32.030905 ms; encode P50 7.939 / P95 8.680 ms (171 samples).

Native frame 301 parsed in 2037 us and decode pipeline completed in 11868 us;
writer entered with only 617 us source budget, wrote in 85 us and failed its
ACK wait after 15421 us. No live submission logged. The startup frame 8 had
parser 1717 us / cold decode 117575 us and was correctly discarded.
These measurements locate remaining costs without proving physical scanout
or a bounded successful live frame. Receiver PID 27804 started
2026-09-05T04:05:35.3225485Z and exited status 1. Dedicated task removed;
final native process and UDP 44339 counts zero. Logs preserved.

## Native resource breakdown and alpha-buffer reuse (r18)

Parser retains at most one bounded alpha allocation only after synchronous
GPU upload consumes it. Tests verify allocation reuse across shrinking and
growing raw/RLE frames with exact new contents; decoder-owned GPU resources
never borrow that recycled CPU storage. Windows clean build/CTest 4/4 passed;
presenter SHA256
`10fb7acc2a1f1eebe2925a2d296c61e6892bd8c6f515dbd1e6ee9ee40d128651`.
MF ProcessOutput output sample/events cleanup now covers all result paths.

r18 live frame 417: parser 362 us; alpha texture upload 791 us; MF sample
copy 4 us, input 14 us, output 5671 us; GPU resources 6837 us; shader API
submission 18 us; total Submit 13464 us. These are host API durations, not
GPU completion/scanout. Writer had 5660 us budget, write 45 us and total
failure wait 19177 us. No live ACK/submission. Warmup frame 8 was discarded.
3 live sends, 2 rejects; send-age P50 23.518763 ms (3 samples); encode P50
6.740 ms (4 samples), not a controlled performance comparison. Receiver PID
7348 started 2026-09-05T04:12:09.8759959Z and exited status 1. Task removed;
final process/UDP counts zero. Internal scratch texture allocation is the
next optimization target; externally delivered output textures must retain
independent ownership and cannot simply be overwritten on the next frame.

## Internal NV12 cache and parallel encode (r19/r20)

One internal shader-NV12 texture and Y/UV views are now cached by exact device,
source format/size/sample description, aperture and output geometry. Each frame
still copies its newest pixels before Draw on the same immediate context.
Externally delivered BGRA targets remain independent. Windows clean build and
CTest 4/4 passed; presenter SHA256
`9ce944ea1d1548c54d73995a592eb1fa3d95e2ebd0649c7fa2b1b6018f257862`.
Headless 256: three exact alpha frames, EXIT=0. Headless 1936x1732: three
exact alpha frames and PASS stdout, but wrapper lost its numeric exit code;
do not present it as a captured exit-zero receipt.

r19 (serial encoder) sent 196 / rejected 195 / ACK 0; receiver frame 452
had only 356 us budget before its 65 us pipe write. It failed ACK wait before
a native completion was logged. Receiver PID 4676 exited and task removed.

VFAR and native color encoding now overlap in a single fallible scoped worker,
borrowing immutable RGBA and joining before pending insertion/adaptation.
Errors retain generation cleanup. Controlled local synthetic 1936x1732 x160:
serial P50/P95 6742/7886 us, parallel 4670/5360 us; earlier repeat agreed.
Only tests have a serial comparison switch. Root encoder tests/clippy passed.

r20 combined live: 5 sends, 4 rejects, zero ACK; encode P50/P95 5407/5626 us
(6 samples); send-age P50/P95 25.003050/25.823895 ms. Receiver frame 213 had
901 us budget, wrote in 59 us, timed out after 1776 us. No native live
completion/submission. Receiver PID 26280 started
2026-09-05T04:19:52.4892381Z and exited status 1. r19/r20 tasks were removed
after exit and each final preview/UDP 44339 count was zero. Logs retained.
Continuous fresh display and two-frame scanout remain unproven/unmet.

## Transport-stage timing (r21/r22)

Windows diagnostic build/tests 15/15 passed; receiver SHA256
`9e9b14e2362da5bb0656a9ad590bba38f123f6a43987dfb8ad7e4fb27c403cb0`.
r21 failed device readiness before media (PID 17888), not a transport sample.
r22: dispatch P50/P95 218/258 us (37 samples); 37 sends/37 rejects, one
MTU-abandoned frame, zero ACK. Send-age P50/P95 23.871075/26.054143 ms,
encode 5495/6311 us (40 samples), clock uncertainty 1206 us.

Failed frame 477: first matching packet 204 us after metadata processing;
complete assembly 5028 us; remaining budget then 2870 us; validation/queue
357 us. Writer had 2491 us, write 106 us, failed wait after 9764 us. The
timestamp mapping audit found no double uncertainty deduction. These values
do not include a physical scanout measurement. They motivate avoiding the
large CPU capture readback rather than claiming small dispatch savings suffice.
PID 5708 started 2026-09-05T04:24:58.8722894Z and exited status 1. Both tasks
removed after exit; final native process/UDP 44339 counts zero. Logs retained.

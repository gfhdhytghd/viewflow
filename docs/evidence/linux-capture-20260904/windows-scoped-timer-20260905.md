# Scoped Windows timer candidate — 2026-09-05

This extends the GPU trial evidence in `gpu-live-20260905.md`. It is not
proof of a live presented frame or the two-frame deadline.

## Implementation

The Rust coded peer and the separate native presenter each acquire a 1 ms
WinMM request for their own process lifetime and pair successful acquisition
with release on scope exit. Failure to acquire is reported before runtime
initialization. No registry, service, persistent timer policy, UAC or firewall
setting is modified. The original frame deadline remains 33,333,333 ns.

Rust uses the verified windows-sys 0.61.2 `Win32::Media` bindings and confines
the scalar FFI calls to one audited function. Fake callbacks test success,
failed acquisition and early return. Native mock checks use explicit failures
instead of `assert`, so Release/NDEBUG cannot disable them; early return and
exception unwinding are covered.

Windows also exposed a pre-existing flaky test: 1 and 3 ms waits may coalesce,
so an operation could legitimately finish before the drain-error branch.
The test now holds that operation pending to exercise the real branch.
Production completion admission independently checks the absolute deadline
after a ready operation, covering late/coalesced wakeups without restamping.
Linux GPU example tests: 25/25; GPU-feature clippy and fmt passed.

## Isolated build provenance

Local build root: `/tmp/viewflow-timer-r6.vPqXqu`.
Windows build root:
`C:\Users\wilf\AppData\Local\Temp\viewflow-timer-r6-vPqXqu` (private ACL).
Fresh build uses cached dependencies with `cargo --offline --locked` and a
separate native build directory. Original Deskflow and previous diagnostic
executables are not replaced.

Initial source archive SHA-256:
`6a436d789a8af74d83052bb4b9aca220d73cd036bd042406e48e5359b164ad6b`.
The example was subsequently amended after Windows compile/test feedback;
the archive alone does not represent the final candidate. Final example
source SHA-256 is
`2cc8c3bd831ab04ac905fb3ac68d98fcfd6fbd75e5a0d45c68f60ca7be685eed`.
Windows final rebuild completed: 25/25 Rust example tests and 5/5 native
Release CTests passed. Build log:
`/tmp/viewflow-timer-r6.vPqXqu/final-build.log`. Existing Windows unused-code
warnings remain; this is not a Windows clippy-clean claim.

- Windows receiver SHA-256:
  `16d36f15740d0e199ebbbdb26aa6334082380110e126e64c2baf7bb1ff43bbe9`.
- Windows presenter SHA-256:
  `c6105fd68e1457232a1c17553685a96ae9bcf24697842f33338a30538da7879c`.
- Linux GPU sender SHA-256:
  `4cf00f7fd161e23a3fcbcc46a67117098836a7d4cb9dd2e55dbb8423079ed9a0`.

These candidates include the earlier GOP and absolute-dispatch changes, so a
combined live result cannot isolate timer resolution as the sole cause.

## r6 live result: still no fresh presentation

Logs: `/tmp/viewflow-gpu-coded-live.zOVNnL/sender-r6.stderr` and
`C:\Users\wilf\AppData\Local\Temp\viewflow-gpu-coded-zOVNnL\terminal-r6.json`.
The final source hash above was read back from Windows and matched.

- Clock exchange RTT 1559 us, uncertainty 779 us; decode-only warmup ACK 801 ms.
- 142 captures, 2 pre-encode stale; 139 complete enqueue operations, 139 exact
  rejects, **zero ACKs**, zero partial-dispatch timeout. Sender exited on its
  bounded session timeout rather than completing acceptance.
- Dispatch P50/P95: 797/1292 us. This measures enqueue, not network delivery.
- Source age at enqueue P50/P95: 17.459/20.046 ms; encoding 15.383/18.244 ms.
- Color/alpha bytes: 43,687,839 / 30,007,181. Recovery after every reject still
  requests IDR, so this trial cannot demonstrate steady-state P-frame savings.
- Last sampled QUIC path: RTT 2.068 ms, cwnd 59,847 bytes, 641 lost packets,
  117 congestion events. These counters are not direct proof of UDP drop
  location or complete-frame loss. Further receive-phase timing is needed.
- Receiver PID 13832 started 06:46:10 UTC and exited 06:46:21 UTC, exit 1 on
  peer close, runner `timedOut: false`. Native timer initialization succeeded;
  only decode-only warmup output was logged, not fresh composition submission.
- Subsequent query found the task Ready, no diagnostic process, UDP 44339
  absent. The exact r6 task was then unregistered after rechecking its action,
  terminal state and absence of processes/port; task absence was verified.
  Logs and candidate binaries were retained. Hyprland configerrors remained empty.

The phase boundary now suggests inspecting frame assembly, missing fragments
and payload size. Do not claim the scoped timer alone fixed the pipeline or
relax freshness to make the diagnostic pass.

## r7: socket buffer and receive-phase evidence

Windows OS UDP buffer readback confirmed 65,536 bytes initially, and 4,194,304
after the receiver-local setting; send buffer remained 65,536. This is distinct
from the existing 16 MiB Quinn application datagram receive queue. No host-wide
network settings changed. The new Windows socket readback test passed with
27/27 example tests; Linux GPU example tests passed 26/26. Native optional
timing CTest passed 5/5 and introduces no new GPU synchronization/readback.

- Receiver `coded_window_peer-r7.exe` SHA-256:
  `254ef5ab4d47831fbe835e8062a84c8250fc5bffcdeb5b9e2ed3ffa9872aae5c`.
- Sender SHA-256 `b33064886a5de37bf2181da0bef01953e167db295bd40eb7d779f81f02e509ea`.
- Receiver source SHA-256
  `cec71378dd799b7fe79a13c4f80c792e5303c0e119c8f93f5c1dc11162332418`;
  lock SHA-256 `80b02cea5a7829bdf6dc39ae2ee669103d32647f8b767303d8b4a7b185ec273c`.
- r6 executable and example source were preserved under distinct `-r6` leaves
  before rebuilding; native presenter remains the r6 candidate.
- Logs: `sender-r7.stderr` / `terminal-r7.json` in the existing local/Windows
  diagnostic roots. Build log `/tmp/viewflow-timer-r6.vPqXqu/build-r7.log`.

145 complete enqueues, zero ACKs, 144 rejects observed by sender before its
session timeout; receiver counted 145 rejected frames (141 Late, 4 timeout).
There were zero after-assembly/after-validation rejects. A source timeout can
prevent reading the final exact reject; these counts are not contradictory.
Last sampled Quinn loss fell to 3 with one congestion event, versus r6's 641;
this is a sequential, non-controlled comparison, not proof all loss was local.

First sampled rejected frame: first packet after 80 us, source age 20.036 ms;
27 color packets seen of 231 declared, no alpha packets, then Late after
13.437 ms. Subsequent sampled frames already had source age 42–47 ms at their
first matching packet, 20–25 ms after metadata. Seen counts are explicitly not
unique-chunk counts. Estimated rejection ages are diagnostics only.

Warm native encode host times were 7.797–8.189 ms across four samples, whereas
adapter encode P50/P95 was 15.060/16.215 ms. Existing waits are included; these
are not GPU timestamp measurements. This motivates avoiding repeated lossless
alpha encoding when the entire alpha input is identical, and bounding the
sender's unsent queue. The old 1 MiB default can retain rejected frame tails.

Receiver PID 7112 exited 06:58:13 UTC on peer close (`timedOut: false`), with
zero native live submissions. Neither scope-level tests nor reduced loss prove
the end-to-end deadline.

## r8/r9: alpha cache, bounded queue, and retained warmup reference

r8 sender SHA `7d4c0a9b49feccddc44a5843e0cb8641ae867b8c1b2dd9a8a40565c1326511f5`.
Exact alpha cache and 64 KiB sender queue: 205 complete enqueues, zero ACKs,
204 sender-observed rejects; encode P50/P95 9.036/9.960 ms, source age
11.007/12.721 ms. Receiver rejected 199 Late and 6 timeout, none after
assembly/validation. These are sequential diagnostic measurements, not an A/B
causal proof. r8 task was removed after no receiver/presenter process and no
UDP 44339 endpoint were observed; logs were preserved.

r9 retains the exact acknowledged decode-only warmup as a decoder reference.
The encoder and presenter are persistent; waiting drains only unencoded captures.
Live capture must still be newer than READY, carry its own identity/timestamp,
and satisfy the unchanged 33,333,333 ns budget. Any discarded encoded reference
still requests a new IDR. Warmup itself is never presented or counted as live.
Sender SHA `efd07d2984ea6f29f2c45579ced204bea15cbcc54f785d89bfe49b1295da5cff`;
Windows receiver/presenter remain the exact r7/r6 candidates above.
Example tests 26/26, fmt, and GPU-feature Clippy passed. Existing native GPU
integration was rerun: actual IDR/P/P/forced-IDR decoded through one software
decoder with frame type and pixel checks (AU sizes 1006/117/4184/1006).

r9 first live color required 66 chunks instead of the following recovery IDR's
235. First two frames still expired during assembly. Third frame reached the
presenter: assembly 18.486 ms, budget after assembly 1.733 ms, budget before
presenter 0.944 ms; presenter ACK timed out after 2.205 ms. Thus there remains
**zero successful fresh native presentation ACK**, not a passed latency test.
Sender completed three enqueues, observed two rejects, then failed on receiver
control timeout. Receiver PID 13136 exited at 07:13:15 UTC, timedOut=false.
Logs are `sender-r9.stderr` and remote `terminal-r9.json` in the diagnostic roots.

User authorized VM NIC experiments. Read-only inspection found standalone
root-owned QEMU PID 1507, e1000 on tap-windows, root-owned QMP socket; Windows
reported Intel PRO/1000 MT and no matching installed VirtIO/Red Hat PnP driver.
`sudo -n true` requires a password. No VM hardware, physical bridge, or driver
was changed. This does not establish e1000 as the sole latency cause.

## r10: resize boundary (no media result)

Sender SHA `9b5a2fd2370d9f0dca6ca8df1b6fa64410ac1411ffc4f708a300f12d54e84196`
adds warmup-only validated VFAR profile logging. The real Dolphin client had
changed to 791 x 598 logical while the invocation still requested the previous
968 x 866 decorated extent. Startup correctly failed with a logical-geometry
mismatch before encoding/sending media (all sender media counters zero).
No profile was emitted, so this run does not classify today's alpha payload.
Windows child 28016 exited at 07:17:51 UTC on peer close, no submissions;
the exact r10 diagnostic task was removed after process and port checks.
This is a safe diagnostic rejection, **not implemented dynamic resize**.

## r11: current alpha sample and native-stage timeout

Updated explicit geometry to 813 x 620 decorated logical (1626 x 1240 pixels),
with client blur rectangle 11,11,791,598. Sender SHA
`54cc1b7f6db431f60b6b84dd2b3e074b7bf3fe86d2ef482fa1b7bea7766973c1`.
Warmup profile proved RLE: decoded 2,016,240 bytes, encoded 138,721 bytes.
Exact alpha-only fixture was create-new exported to the private diagnostic
root's `alpha-r11.vfar`; mode 0600 was read back. No RGB was exported.

First fresh P-frame: color 843 bytes, alpha 138,721; sender source age
10.123 ms, encoder host 7.177 ms. Receiver assembled in 6.382 ms with 12.793 ms
remaining; validation/queue took 0.656 ms. Presenter began with 11.936 ms and
timed out at 12.187 ms. No Late/assembly rejects, no successful live ACK.
Thus the native presentation path now matters directly; this is not evidence
that transport or physical scanout meets the final deadline at arbitrary size.
Receiver PID 18636 exited at 07:20:00 UTC, timedOut=false. Exact r11 task was
removed after no diagnostic process/UDP endpoint remained. Logs preserved.

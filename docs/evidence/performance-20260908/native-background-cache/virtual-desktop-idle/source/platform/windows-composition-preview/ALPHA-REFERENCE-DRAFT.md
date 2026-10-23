# Immutable warmup-alpha reference (opt-in diagnostic)

Motivation: r19 transmitted 138,721 alpha bytes with only 155 color bytes;
assembly consumed about 10 ms of a 33,333,333 ns live budget. This experiment
avoids retransmitting an exactly unchanged alpha plane. It does not relax that
budget, omit alpha, approximate transparency, or reuse a color frame.

Both peers explicitly select `--alpha-reuse-warmup`. Before any warmup capture,
control kind 18 carries the exact one-byte plan `[1]`, acknowledged by kind 19
with the same byte. This exchange precedes the optional three-picture plan.
Default mode retains its existing wire sequence. A mismatch fails startup.

Each connection installs one immutable VFAR baseline only after its final
warmup completes and is acknowledged. No live frame replaces the baseline.
Sender reuse admission compares the entire independently encoded alpha payload
from the current capture, not just a digest. Window, geometry epoch, codec
generation and dimensions must match; current frame identity must be later
than the baseline. A changed alpha uses the ordinary full-plane path.

Reference metadata is one atomic reliable record, kind 20: the complete normal
FRAME_META body followed by exactly 80 bytes. There is no separate dangling
reference record. The suffix is:

| Offset | Length | Value |
| --- | --- | --- |
| 0 | 40 | Baseline FrameIdentity: window 16, frame/epoch/config u64 BE |
| 40 | 4 | Physical width, u32 BE |
| 44 | 4 | Physical height, u32 BE |
| 48 | 32 | SHA-256 of the complete baseline VFAR |

The receiver requires an enabled, acknowledged cache and an exact suffix match.
It assembles the current color only, then constructs the current alpha plane
using that color's identity and genuine source timestamp plus the verified
cached bytes. The cache API stores no timestamp. Existing pair/codec validation,
freshness checks, native v4 QPC deadline and exact live ACK admission still run.
Matching alpha datagrams must not enter the active reference-frame assembly.
No fallback to a different alpha representation is allowed after a reference
metadata commitment; transport/recovery errors retain their existing behavior.

The standalone cache tests mutate every reference byte and lineage field,
exercise malformed/bounded VFAR, changed alpha and stale frame IDs, and lock a
known VFAR digest. Integration and Windows/runtime evidence remain separate
gates; these tests alone do not establish working live reference transport.

## r20 implementation and cross-host evidence

The cache and peer integration passed independent source review. The cache also
rejects zero epoch/config as required by codec lineage. Linux cache tests 3/3,
peer tests 35/35, formatting and Clippy (warnings denied) passed. A Windows-only
helper type mismatch was caught during compilation and corrected by explicitly
passing the current assembled color's identity/time fields. The corrected
Windows candidate passed peer tests 36/36, cache tests 3/3 and Release build.

Frozen peer SHA256:
`d419771cff9fdcdb9b0b939275a52a8e03515d26e275db1b7b360a87896e008a`.
Cache source SHA256:
`db74c4ef0679b5f3e852682c29fddf5bd375e87919a5115a5146bbb894f3171e`.
Linux sender SHA256:
`eed0ff8e5a697be8ad2c59cc1c859f50fb0cec297379e22270790e012ef0e0db`.
Windows source archive SHA256:
`b5036b6b16b56498a35fe98022ca78fc499b4630db15b55e674d55b461489470`.
Windows receiver SHA256:
`5a381768fc4aa514a1729e052fec9d9b76d68b8cef13b25e19ae2b987e77d3cf`
at `C:\Users\wilf\AppData\Local\Temp\viewflow-alpha-reuse-r20-20260905-6A31\rust-source-c\target\release\examples\coded_window_peer.exe`.
Native presenter remained r17b SHA256
`f0bf051d3f6a6d116bf06a5c1abec5c7adba51216d856a7f432534c7382ae10d`.

At 2026-09-05 08:45 UTC, all three warmups (34/57/60) completed and were
acknowledged. Seven live pictures then used alpha references. Frames
62/63/65/66/68/69 received exact live ACKs accepted by the unchanged source-time
admission. Frame 70 timed out awaiting native presentation acknowledgment.
Thus this is the first successful fresh native-ACK evidence in this diagnostic
series, but not a stable stream, physical scanout measurement, or two-frame
end-to-end acceptance.

Actual media payload totaled 1,073 color bytes and zero alpha bytes; seven
references avoided 971,047 alpha bytes (control overhead is not in these media
payload counters). Dispatch p50/p95 was 34/36 microseconds. Sender capture age
at dispatch p50/p95 was 7.764/7.948 ms. The first live native Submit took 3.092 ms
and composition submission took 1.514 ms; the next logged composition times
were 2.046/2.424/2.360 ms. For failed frame 70, assembly took 0.127 ms, leaving
23.659 ms; validation/queue took 0.404 ms. The presenter writer had 23.152 ms
before work and timed out after 25.066 ms. The failing native stage is not
known: native Submit timing logs are currently limited to the first four
submissions, including warmups.

Receiver PID 18728 exited without the runner's outer timeout. The r20 task was
removed; diagnostic processes and UDP port 44339 were confirmed absent. No
persistent service or physical machine configuration was changed. Evidence:
`/tmp/viewflow-warmup-three.7ETt2i/terminal-r20.json` and `sender-r20.stderr`.
Next work must address remaining native latency/jitter and safe expiry handling,
without admitting an expired frame or treating a late ACK as a fresh one.

## r21 trace repeat

Only the native timing-log bound changed (first 4 to first 32 submissions, plus
composition-stage entry); the alpha-reference Rust candidates remained r20c.
Trace source archive SHA256:
`4232ad6857fa8891479376742c5e1ed2dad374a553b38d44bd2f8a2e0bdc12e9`.
Native EXE SHA256:
`1117001740803c1301e5e8d2f63a7cb906d89c258e18ef1c015f5be5fe8e5af8`
at `C:\Users\wilf\AppData\Local\Temp\viewflow-trace32-r21-20260905-Q5D7\native-build\Release\viewflow_windows_composition_preview.exe`.
Windows Release and CTest 10/10 passed before the repeat.

At 2026-09-05 08:51 UTC, the sender received 237 fresh ACKs out of 238 sent
pictures, all using alpha references. Media payload was 450,442 color bytes,
zero alpha bytes; 33,015,598 alpha bytes were avoided. Two pre-encode stale
captures were dropped. Dispatch p50/p95 was 35/57 microseconds; capture age at
dispatch p50/p95 was 6.932/8.176 ms.

Frame 375 then spent 14.896 ms in assembly, leaving 7.966 ms; validation/queue
cost 1.118 ms and the presenter writer had 6.810 ms. Its ACK wait timed out after
7.236 ms. This explains insufficient remaining budget, but the precise final
native stage is still unknown because failure occurred beyond the 32-frame
trace bound. Trace logging can also affect scheduling; this is not a controlled
performance comparison proving an optimization beyond r20.

Receiver PID 15784 ran from 08:51:32.714 to 08:51:40.522 UTC and exited 1 without
the runner's outer timeout. The task was removed; diagnostic processes and UDP
44339 were absent. Evidence: `/tmp/viewflow-warmup-three.7ETt2i/terminal-r21.json`
and `sender-r21.stderr`. Stable indefinite playback and physical latency remain
unproven; explicit safe expiry recovery is the next correctness step.

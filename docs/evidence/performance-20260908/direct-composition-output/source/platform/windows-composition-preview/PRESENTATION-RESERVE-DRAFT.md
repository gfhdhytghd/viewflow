# Early presentation cutoff experiment

The r23 stream survived recoverable rejections but still stopped when frame 161
was submitted and its ACK was observed after the original freshness deadline.
That outcome cannot truthfully become an Expired/never-presented rejection.

The next opt-in experiment reserves time for the native submission ACK by
subtracting a configurable interval from the native QPC admission budget.
`--presentation-reserve-us` defaults to zero and is bounded to 10,000 us.
A nonzero reserve requires compressed stdin, v4 deadline enforcement, and
explicit expired-frame recovery. It never extends source freshness, native
admission, or the fixed disposition grace. If no positive presentation budget
remains, reject before writing any pipe bytes and recover through the existing
IDR path. Never manufacture a new capture timestamp.

An initial 5,000 us trial value is an experiment, not a latency guarantee or an
automatically tuned default. It can trade more discarded frames for fewer
late acknowledgments. Late Presented remains terminal even with this option.

Native diagnostic logging now labels up to 32 expiry dispositions with
`before-decode`, `before-copy`, or `after-copy`. The exact stdout control record
is unchanged and flushed before diagnostic stderr. These labels distinguish
the paths; they do not establish physical scanout timing or visual readback.

## Source verification

Peer source `cc2df9383092434df4f66cc647f42f269a3e4ca565d02094a1905cb70afdf2a2`
passed 38 local example tests and Clippy with warnings denied. Tests cover
canonical bounds, default/explicit zero, prerequisites, subtraction, exact
budget exhaustion and underflow. Source review confirmed the exhausted-budget
REJECT occurs before pipe publication, and the original freshness/disposition
deadlines remain unchanged. Candidate Windows builds and live verification
are pending, as is a deterministic post-copy rejection/unchanged-visual oracle.

An additional full library regression initially passed 183/184 tests in default
parallel mode. `sidecar_runtime::tests::expired_capture_deadline_never_reaches_quic_and_preserves_cleanup`
failed during cleanup because the lease revoke deadline expired before ACK
registration. The exact test then passed alone; the full serial suite passed
184/184. No HID cleanup deadline or test source was changed. These subsequent
passes do not erase the initial scheduling-sensitive failure.

Native r24 phase-trace Release and CTest 11/11 passed. Source archive:
`40503e877250351774320592e3b9c9c78b65518638e8498afeeceb1be1c4fb63`;
main source `06040ca272ce8260d89f9d8d70ab1820498e3fbd0425228db4593ac08a481ecb`;
EXE `5a5b5733c3aaedf5586ef20e6d3d0e2249b53b0f7830fcfcf4bf45ac90e7dd6e`.
Private Windows staging: `viewflow-r24-expired-phase-20260905-P8W4`.

## r24 bounded live evidence

Rust Windows tests 39/39 and offline locked Release passed. Archive
`8c73fc4841705d299f97058d8c10d8276b7f8e4c3bcea310c127cbd52ce3a3f4`;
Windows EXE `c093da9554cf11aeec8d86528ded5c2b65ab4a136176e3783e6253c7641a73c2`;
Linux native-GPU EXE `c06563d4f0e722713436bab0023891802ec96373b870dafbfd9ff3cffd3d2ebc`.
Receiver private staging: `viewflow-presentation-reserve-r24-20260905-6B7E`.

The 5,000 us reserve trial ran until the sender's configured 10 s diagnostic
timeout, rather than failing early on a late Presented ACK. It sent 430 frames:
414 fresh ACKs, 15 recoverable rejections, and one in flight at termination.
Two captures were discarded before encode. Receiver counters showed one
pre-pipe rejection after validation. Native phase evidence recorded 12
before-decode rejections, frame 348 before-copy, and frame 350 after-copy.
Transmission continued beyond those identities to frame 579. This exercises
the post-copy rejection path and subsequent stream progress, but does not
replace an independent oracle proving the prior visible texture was unchanged.

Receiver PID 12448 ran 09:22:24.733–09:22:36.215 UTC. Sender ended with its
configured timeout; receiver ended with peer-closed connection (both exit 1,
not clean application shutdown). The outer watchdog did not fire. Cleanup
verified no diagnostic processes or UDP 44339 endpoint and removed r24's task.

This single short trial is not a controlled causal comparison, long-running
stability proof, 6K60 result, or physical scanout latency measurement. Reserve
remains opt-in/default zero. No network, VM NIC, or persistent service changed.

Evidence at `/tmp/viewflow-warmup-three.7ETt2i/`:
- `terminal-r24.json`: `700d8c25210ad71961e6859837860d1385d08aab6eea8cd7524ceb361c2092f0`.
- `sender-r24.stderr`: `8fc81f573572e735cbce6a412e2cb712dce743bcd6509757b4e926dae42351ee`.

# Rejected experiment: pace source UDP bursts

2026-09-08. **Pacing eight single-datagram sends per 1 ms window reduced native commit throughput and increased normal feedback latency. It did not reliably remove the hundred-millisecond stalls. The implementation was removed from active code, and the rebuilt source executable exactly matches the preceding NDIS/active-UDP baseline hash.** This experiment does not improve the 4K60 / two-frame target.

## Controlled change

The experiment wrapped the source's existing Quinn runtime socket. A configured quota returned `WouldBlock` without consuming the `Transmit`; each Quinn writable poller used its own asynchronous timer before retrying the underlying socket. The wrapper retained no payload, charged only successful sends, and forwarded receive operations unchanged. It imposed no session deadline or input restriction. The quota used non-accumulating 1 ms windows, not a bound on every rolling 1 ms interval. Actual wake scheduling can lengthen the interval.

Both A (unpaced) and B (eight packets/window) advertised one transmit segment, disabling GSO in both arms. This prevents a GSO difference from being mistaken for a pacing benefit. All four trials used one newly built Linux source executable, the same unchanged Windows receiver/presenter, socket tracing, GPU alpha comparison/reuse, and the same 3840×2400@60 owned fixture. Order was A1, B1, B2, A2, 25 seconds each. No extra UDP probes, desktop observer, NDIS capture or WPR recording ran during these trials.

## Measured result

Samples below exclude frames below 30. A native commit is an application event, not physical display FPS. Feedback ends at application feedback reception, not first presentation or photon time.

| Trial | Native commits/s | Feedback median ms | P95 ms | Maximum ms | Feedback >33.33 ms | Feedback >100 ms |
|---|---:|---:|---:|---:|---:|---:|
| A1 unpaced, 1 segment | 53.239 | 7.449 | 15.449 | 342.178 | 20 / 1,259 | 6 |
| B1 eight/window | 40.548 | 12.996 | 53.970 | 125.831 | 147 / 963 | 2 |
| B2 eight/window | 35.918 | 13.225 | 57.826 | 342.637 | 169 / 845 | 5 |
| A2 unpaced, 1 segment | 52.940 | 7.854 | 17.687 | 379.960 | 19 / 1,274 | 5 |

Both repetitions show lower throughput and approximately 5–6 ms higher median feedback. B1's smaller maximum is not a reliable improvement: B2 still reaches 343 ms, while the overall slow-feedback count increases substantially. Pacing spreads large frames over more time; this tradeoff is counterproductive at the tested setting. The result rejects this implementation/setting as an optimization, not every possible congestion or pacing strategy.

All four source traces contain single-datagram successful sends, matching the GSO control. The median group size, using gaps greater than 1 ms to delimit groups, falls from 27 to eight. Such groups are an analysis convention and can span several limiter windows, so their maxima are not quota violations. Socket counters include all connection traffic, including control packets. In particular, `connection_socket_send_span_ms` is not the duration of sending a frame's media packets.

The 33.33 ms threshold only selects diagnostic samples. No connection is dropped or frame deadline introduced by that threshold.

## Validation, rollback and evidence

A Linux UDP test verified ordered, byte-identical delivery without duplicate sends; `WouldBlock` on quota exhaustion; asynchronous resumption of two poller objects; and successful receive/metadata delivery while sending was paced. Both pollers ran within the test's task, so this test alone does not prove every multi-task interleaving. The native 4K integration trials completed with planned source timeout, peer-close receiver exit, watchdog=0, and no owned processes/tasks left. This temporary source experiment was not built or deployed as a Windows source.

The source runtime module and its two integration edits were removed after the negative result. The restored Release build passed and produced SHA-256 `0366cb9ae34238e0c1595e3a1c3b668d81247f4301520a9e80c9a6f844626687`, exactly the pre-experiment executable. The archived `.rs.trial` files retain the actual test inputs and are not compiled by the repository. [Trial hashes](udp-pacing-trial-source-sha256.json), [restored hashes](restored-source-sha256.json), and [Windows final inspection](windows-final-state.txt) record these boundaries.

[Comparison JSON](udp-pacing-comparison.json) contains stage distributions and selected slow frames. Each trial directory includes compressed source/receiver/producer/runner/cleanup logs, fixture metadata and clock/stage analysis. Both source and receiver socket record counts match the parsed rows with zero omitted records. The [analyzer](summarize-udp-pacing.py), build/test logs, orchestration scripts and exact trial sources are included.

The temporary headless output was removed after its fixture exited. Full monitor lists match before/after, observed focus state is unchanged, and the temporary fixture rule was confirmed disabled. No mouse or keyboard input was injected, and no Windows registry, driver, service or security setting changed.

# QUIC receive readiness, actual UDP calls, and wake timing

The 25-second isolated 3840×2400 trial still contains 260–381 ms feedback tails. The new trace locates the repeated pauses before the receiver's readiness notification. It rules out Tokio cooperative-budget exhaustion and long scheduling delays after the notification for the recorded slow frames. It does not yet identify which kernel, driver, or virtual-network component causes the delay. The 60 fps / 33.3 ms end-to-end goal remains unmet.

## Instrumentation and validation

`VIEWFLOW_QUIC_SOCKET_TRACE=1` now instruments the equivalent of Quinn 0.11.11's Tokio UDP receive loop: readiness polling, the `quinn_udp::UdpSocketState::recv` call, and the registered readiness waker. On Windows, that receive implementation calls WSARecvMsg. A separate `pending_budget` status records an empty Tokio cooperative budget at a pending readiness poll. The waker records its notification before forwarding to the original parent waker, outside its mutex.

Default operation still uses Quinn's original Tokio runtime. The opt-in trace uses bounded metadata records and flushes after endpoint retirement. The writable readiness future is boxed in this diagnostic implementation, so this run is diagnostic evidence, not an uninstrumented speed comparison. No payloads, input, focus changes, connection policy changes, or registry changes were added.

Two tests pass on both native Linux and native Windows: a real UDP exchange that first pends and then wakes on a delayed reply; and an explicitly exhausted cooperative-budget poll that performs no receive call and is subsequently woken after the task yields. Both release builds pass. The cooperative test's initial assertion was corrected to allow Tokio's deferred wake after yielding; the final logs are included.

## Observations

There are 125,795 source and 188,416 receiver records, with zero omitted records and zero rejected frame-clock correlations. Across the whole trial:

| Observation | Count |
|---|---:|
| Source sends accepted | 6,649 |
| Source sends blocked / writable pending | 0 / 0 |
| Receiver successful UDP receive calls | 46,001 |
| Receiver UDP receive calls returning WouldBlock | 2,616 |
| Receiver readiness pending / wake notifications | 2,613 / 2,609 |
| Cooperative-budget pending, either role | 0 |

Receive, readiness, and wake counts are not expected to be identical: readiness may remain cached, multiple notifications may coalesce, and the endpoint retires with pending operations. The maximum receiver UDP receive-call duration was 365.2 µs.

For frame 569 (381.17 ms encode-to-feedback), the source accepted 226 datagrams / 325,980 bytes between encode +0.251 and +0.603 ms. Windows then received batches of 10 datagrams about every 18 ms. After each batch, the actual UDP receive returned WouldBlock. For example, readiness went pending at +8.154 ms, its wake arrived at +26.208 ms, and the next poll started at +26.263 ms: 18.054 ms before the wake and 0.055 ms after it. The same pattern recurs for frames 237 and 706 (270.462 and 260.204 ms feedback).

These datagram totals belong to the connection and can include control traffic; they are not a byte-for-byte proof of the identity of every frame packet. A successful source send proves acceptance by its socket API, not arrival at the Windows NIC. A WouldBlock result proves no datagram was returned at that call, not that none arrived later while notification was pending. These limits leave the network path, Windows stack/driver, and readiness notification machinery as possible contributors.

Native surface commits averaged 54.44 Hz after frame 30. The desktop observer was disabled, so this is neither physical display fps nor a desktop latency measurement. Empty desktop observation data are marked unavailable.

## Artifacts and cleanup

`socket-summary.json` contains full counts, clock anchors, slow-frame calls, and pending-to-wake-to-poll intervals. The trial subdirectory contains compressed raw source/receiver/producer logs, fixture dimensions, retirement logs, and stage summaries. Build/test logs, exact source and executable hashes, analysis scripts, and ownership snapshots are included.

The temporary headless output was removed, before/after monitor snapshots match, observed focus stayed unchanged, and no owned Windows processes or scheduled receiver tasks remain. The native preview is unchanged; the isolated Windows Rust receiver contains only the diagnostic update. The live installation was not replaced.

## Follow-up capture validation

A bounded synthetic UDP probe on port 49101 received all 420 packets in eight batches. PktMon's port-only capture recorded 24 packet events, all Tx, although its Rx counters were nonzero. The earlier IP-plus-port capture had the same missing-Rx limitation. Counter rows mentioning Rx must not be mistaken for actual packet events. A separate event-provider-only `Microsoft-Windows-Kernel-Network` trace also lacked UDP events. Neither trace can support conclusions about ingress timing; the system network trace below passed a separate completeness check.

Microsoft's [UDP/IP ETW documentation](https://learn.microsoft.com/en-us/windows/win32/etw/udpip) specifies kernel network tracing for these events. Its [SystemProvider documentation](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/systemprovider) describes the WPR kernel-provider configuration used by the follow-up probe.


## Validated system network trace

A WPR profile with only the system `NetworkTrace` keyword captured the probe's 420 UDP receives and eight acknowledgements, with zero lost events. The independent TraceEvent reader resolves events that PktMon etl2txt could not format. Every receive is 1,400 bytes and matches the controlled probe's ordered receipt sequence. Kernel-event-to-probe receipt ranged from 0.064 to 1.305 ms. The event has no nonce payload, so this correspondence uses the probe's isolation, exact count, order, and sizes.

The subsequent 25-second `4k-deep-network` trial kept the same executables, source options, and disabled desktop observer, while adding this system trace. After filtering by the owned port and source address, all 46,982 kernel receives match all 46,982 successful socket receives in count and ordered byte lengths. ETW lost zero events. Kernel-event-to-receive completion is 0.574 ms median, 1.823 ms p95, and 14.774 ms maximum. The local QPC/socket anchor spans 10.84 µs. Repeated equal lengths cannot uniquely identify packets, so this is an ordered correspondence, not a payload identity proof.

For slow frame 771 (282.098 ms feedback), the source accepts its initial 180-datagram burst between encode +0.344 and +0.664 ms. The Windows **kernel events themselves** arrive in groups of ten at +8.13, +29.18, +39.62, +67.18, +76.75, +91.75 ms, and continue with similar pauses through +273.12 ms. Socket reads closely follow these groups. Frame 1048 (221.548 ms feedback) shows the same pattern.

This places those long pauses before the kernel UDP receive event, excluding a large queue between that event and the application as the cause of these particular tails. It still does not separate the Linux host/bridge, QEMU/e1000 path, Windows NIC driver, and earlier Windows network processing. A system UDP receive event is not a physical NIC ingress timestamp. No NIC, registry, QEMU, congestion-control, or timer settings were changed.

The traced run produced 56.66 native surface commits/s; this is not a performance A/B result or physical display fps. The target remains unmet. `network-trace/` includes filtered event JSONL, event counts, the full socket/ETW correlation, raw application logs, trial source hashes captured before the run, and cleanup verification. The local source hashes still match that pre-trial ledger; Windows hashes match the earlier deep-socket run. WPR and PktMon are stopped, no packet filters or owned processes/tasks remain, and the temporary output was removed with matching before/after monitor snapshots.

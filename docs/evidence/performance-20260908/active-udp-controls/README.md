# Active plain-UDP controls alongside the 4K stream

2026-09-08. **The long receive stalls also affect independent plain-UDP processes in the same interactive Windows session. Both ECN=0 and ECN=2 flows stall during the same video stall.** This narrows the remaining investigation to a shared receive-path mechanism; it does not identify a particular Windows service, registry setting, or filtering component. No production performance improvement is claimed by these diagnostic trials. The 4K60 / two-frame end-to-end target remains unverified.

## Workload and isolation

Two 25-second Linux→Windows trials used the existing 3840×2400@60 fixture, GPU alpha comparison/reuse, borrowed tile storage, and native alpha reuse. The Windows receiver and native presenter binaries match the preceding NDIS trial. Socket tracing was enabled; desktop observation, WPR and NDIS recording were off. These are instrumented trials with extra probe traffic, not an A/B performance baseline. Native commit rates were 52.882 and 52.914 Hz; these are not measured physical display rates or first-presentation latency.

The helper is a separate native Winsock process with a 4 MiB receive buffer and a successful 1 ms timer-resolution request. Each datagram contains a nonce/batch/sequence header and random tail, totaling 1,443 bytes. The Linux sender sets DF and the selected IP TOS/ECN value. No QUIC framing, cryptography, decoder or presentation work runs in the helper. Acknowledgements are sent after a complete batch. Batch nonce, sequence and count checks passed, with no missing or duplicate recorded sequence numbers. Host batch RTT includes both directions; Windows QPC timestamps independently measure the first-to-last receive span and inter-packet gaps.

Helpers ran in session 1 alongside the actual receiver and presenter, verified with live process snapshots. The two-port experiment used separate processes and scheduled tasks, sending concurrently with 200 ms pauses after batch acknowledgement. It was not synchronized packet-for-packet. The earlier sequential mode experiment paused 50 ms between batches. Each run used an owned temporary headless output and fixture; no input was injected. Full monitor lists matched before/after cleanup, observed focus state was unchanged, and the fixture's temporary rule was disabled. Final inspection found zero owned Windows processes/tasks and all recording sessions stopped.

## Results

| Probe | Mode / ECN | Batches / packets | Median RTT ms | Maximum RTT ms |
|---|---|---:|---:|---:|
| active-nonblocking-v2 | WSARecvMsg + select / 2 | 28 / 2,120 | 0.822 | 4.903 |
| active-blocking-v2 | recvfrom / 2 | 28 / 2,120 | 1.030 | 286.356 |
| paired-ecn0 | recvfrom / 0 | 52 / 4,160 | 1.525 | 462.057 |
| paired-ecn2 | recvfrom / 2 | 52 / 4,160 | 1.374 | 592.457 |

The first two probes ran sequentially during different portions of one stream. Their difference **does not establish an I/O-mode effect**. The blocking result does establish that QUIC processing and nonblocking receive are not required to reproduce the stall. Its slow batch 12 sent 150 datagrams in 0.333 ms, received them over 220.363 ms, and had repeated gaps around 18 ms after every ten packets. The batch overlapped video frames 786 and 788, whose feedback spans were 64.805 and 237.341 ms.

The concurrent experiment establishes the ECN and cross-process result:

- ECN=0 batch 19: 20 datagrams sent in 0.063 ms; RTT 454.314 ms. Linux interval 194583988606434–194584442920697 ns.
- ECN=2 batch 20: 150 datagrams sent in 0.229 ms; RTT 592.457 ms. Linux interval 194584028910138–194584621366825 ns. The Windows receive span was 178.513 ms, with repeated approximately 18 ms gaps between groups of ten.
- Both intervals overlap video frame 452 (441.681 ms feedback) and frame 454 (211.337 ms feedback). The overlap calculation uses source `CLOCK_MONOTONIC` timestamps in the same Linux clock domain and requires no cross-host clock offset.
- A later ECN=0 20-packet batch had 462.057 ms RTT, overlapping video frame 819's 450.496 ms feedback. This later example does not have a simultaneous other-probe RTT above the 33 ms diagnostic threshold.

The 33 ms value only selects diagnostic samples. It does not terminate any connection or impose a product restriction.

The [previous NDIS trace](../ndis-ingress/README.md) separately placed a reproduced stall after the upper captured NDIS layer and before the kernel UDP receive event. Combining that evidence with these ordinary UDP controls supports a shared Windows receive-path investigation. This trial does not independently trace where each probe packet waited. It does not prove all stalls have one cause, exclude every process scheduling contribution, or establish MMCSS/Defender/WFP as the cause. Extra probe traffic may alter the severity of the stalls. No registry, driver, security policy, NIC setting or service was modified.

## Evidence and reproduction

- [Validated batch summary](active-udp-summary.json) contains all batch timestamps, receive spans, gaps and overlapping slow video frames. [Analyzer](summarize-paired-udp.py) checks sequence completeness, process sessions and successful helper exits before producing it.
- Each probe directory contains source measurements, compressed per-packet receive logs, runner exit status and live process/session snapshots. Each 4K trial directory contains source/receiver/producer logs, fixture metadata, clock/stage analysis and socket-boundary analysis.
- Native helper/runner sources, Visual Studio build commands, orchestration scripts and output-ownership snapshots are included. [Final Windows inspection](windows-final-state.txt) records build output, actual executable hashes and cleanup state.
- [Source hashes](source-sha256.json) were verified after these trials against the prior NDIS pretrial ledger. These two trials did not record their own fresh pretrial hash ledger.
- An initial attempted interactive trial failed before sending probe traffic because Python did not expose the Linux socket-option constants as named attributes. The corrected valid trials use the Linux header-defined values and verify them before sending. That failed setup is excluded from the table and is retained in `setup-failure/`; it is not a network failure or performance sample.

Helpers and analysis scripts retain their recorded local/Windows paths. Build the native helpers using the included command files before running the owned-output wrappers. The wrappers require the existing isolated full-resolution harness and authenticated Windows SSH access. They are evidence of this controlled environment, not a standalone cross-platform benchmark package.

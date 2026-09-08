# Windows ingress through NDIS, UDP delivery, and Viewflow

The long receive stalls occur after packets have passed through the Windows NIC and observed network filter layers. In the slowest captured frame, the media burst passes all four observed NDIS positions in about 4 ms, but UDP receive events deliver ten packets at roughly 18 ms intervals for over 300 ms. The maximum observed delay between the final NDIS observation and the kernel UDP receive event is 340.97 ms.

This is stronger localization than the previous [socket and kernel trace](../deep-socket/README.md). It does not yet identify a particular Windows policy, callout, timer, or function as the cause. The 60 fps / 33.3 ms end-to-end goal remains unmet.

## Capture validation

PktMon's missing receive packet events were not used. A separate `netsh trace` capture records source IPv4 172.16.105.62, UDP, destination port 49101 for the probe and 49073 for the isolated stream. `CustomIp=UINT16(22,port)` selects the UDP destination port in the observed IPv4 headers. Captures truncate each packet to 64 bytes and enable multiple NDIS positions; no unfiltered packet capture was performed.

The native probe validates nonce, batch, sequence, and packet count before acknowledging each batch. All 420 probe packets are observed once at each of four positions. Captured fragments match across positions, and the probe's sequence/batch identifiers match the independent application receipts. Both the probe and stream ETLs have zero lost events. The TraceEvent reader extracts the packet-fragment records and QPC timestamps; all reader sources and validation scripts are included.

The current adapter and component inspection maps the observed indexes as follows. These are interface indexes, not PktMon component IDs:

| LowerIfIndex | Observation |
|---:|---|
| 12 | Intel PRO/1000 MT virtual NIC, E1G6032E.sys |
| 16 | WFP Native Filter, wfplwfs.sys |
| 17 | QoS Packet Scheduler, pacer.sys |
| 18 | WFP 802.3 Filter, wfplwfs.sys |

The prototype probe runner's initial `netsh trace stop` observation exceeded its 60-second local SSH deadline. Reinspection confirmed the trace session had stopped while the original export process was still running. The same completed ETL was parsed successfully; the export process subsequently exited without being killed or restarted. The 4K runner allowed a longer export observation. This is an export observation issue, not a stream timeout or retry.

## 4K result

`4k-ndis-network` is a 25-second animated 3840×2400 fixture on an owned temporary headless output, with atlas padding recorded in the fixture JSON. It uses the same Linux source and isolated Windows executables as the preceding deep-socket run. The source GPU alpha optimizations remain enabled. The desktop observer is disabled. NDIS capture, the system `NetworkTrace` provider, and the opt-in socket trace run together.

There are **44,393 packets at each NDIS position, 44,393 kernel UDP receives, and 44,393 successful Viewflow receive calls**. All four NDIS positions have the same ordered, unique captured 64-byte fragments. The kernel and socket records have the same complete ordered sequence of byte lengths. ETW and socket trace record loss is zero. The kernel/socket events do not contain packet payload identity, so those correspondences rely on isolation, order, counts, and byte lengths. The NDIS comparison verifies the captured prefix, not uncaptured packet bytes.

| Segment | Median (ms) | p95 (ms) | Maximum (ms) |
|---|---:|---:|---:|
| NIC 12 → filter 16 | 0.187 | 0.411 | 1.575 |
| Filter 16 → scheduler 17 | 0.168 | 0.391 | 1.444 |
| Scheduler 17 → filter 18 | 0.169 | 0.399 | 0.649 |
| Filter 18 → kernel UDP receive event | 0.421 | 8.218 | **340.970** |
| Kernel UDP event → socket receive completion | 0.707 | 3.056 | 8.514 |

For frame 777 (350.346 ms encode-to-feedback), the source accepts 231 datagrams / 332,764 bytes between encode +0.266 and +0.654 ms. The initial connection traffic, including one earlier control packet, is observed at all four NDIS positions by +3.871 ms. Kernel UDP receive events then show groups of ten at +16.826, +35.501, +54.014, +72.827 ms, continuing through +337.031 ms before the remainder is delivered. The per-frame group lists and every underlying socket call are in `correlation.json` and `socket-summary.json`.

The slow packets already appear above the virtual NIC and observed filters, so host bridge delivery, QEMU packet ingress, and these observed filter transitions are not where their hundreds of milliseconds accumulate. The unresolved region is after the final NDIS observation and before kernel UDP delivery. This does not exclude an unobserved Windows filtering/classification stage. It is not proof that `NetworkThrottlingIndex`, MMCSS, Defender, or a particular timer is responsible.

With the additional capture overhead, native surface commits average 51.95 Hz after frame 30. This is diagnostic data, not a speed A/B result, physical display fps, or desktop latency measurement. The synthetic validation itself shows capture overhead, so the sub-millisecond stage values must not be presented as uninstrumented baseline costs.

## Blocking versus nonblocking control

A second native probe uses the same executable, buffer sizes, packet protocol, and 1 ms timer request with two receive modes: blocking `recvfrom`, or nonblocking `WSARecvMsg` followed by `select` only after WouldBlock. A1/B1/B2/A2 order runs 52 batches per trial (28 × 20 packets and 24 × 150 packets), with nonce/sequence/count validation and no packet loss.

| Trial | Mode | 150-packet median RTT (ms) | Maximum RTT (ms) |
|---|---|---:|---:|
| A1 | blocking | 2.994 | 3.661 |
| B1 | nonblocking | 2.879 | 4.062 |
| B2 | nonblocking | 2.870 | 5.007 |
| A2 | blocking | 2.809 | 4.846 |

The nonblocking trials genuinely exercise WouldBlock (174 and 99 times). Neither mode reproduces the stream's 100–350 ms delivery tails. This does not justify replacing the production I/O implementation. These are SSH-session, idle synthetic probes; their session, packet contents/markings, and concurrent rendering conditions differ from the interactive QUIC stream. They do not exclude a condition that depends on those differences.

## State and remaining work

No production source changes, registry changes, NIC configuration changes, service restarts, VM changes, or input/focus injection were made in this diagnostic turn. Read-only inspection shows `NetworkThrottlingIndex=10` and a running MMCSS service; those values are candidate context, not a causal finding. No QoS policy rows were returned. Security settings were inspected, not changed.

The temporary output and fixture were removed, before/after monitor snapshots match, and observed focus stayed unchanged. Owned receiver processes/tasks are gone; WPR, PktMon, and netsh tracing are stopped. Linux pre-trial source/binary hashes still match; both isolated Windows executable hashes match the preceding run. Raw compressed logs, filtered packet/event records, scripts, exact hashes, and current component inspection are included. The live installation remains unchanged.

The next useful experiment must distinguish the remaining Windows delivery/inspection mechanisms or reproduce the failure with a probe matching the stream's process/session and socket/packet conditions. Changing global settings or rewriting I/O without that check would not establish which change actually fixes the observed wait.

Microsoft documents the capture filters and trace controls in [Netsh Commands for Network Trace](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/jj129382(v=ws.11)). The local command help and the successful nonce-controlled probe determine the actual capture behavior used here. [UDP/IP ETW documentation](https://learn.microsoft.com/en-us/windows/win32/etw/udpip) describes the kernel receive events. [qWAVE flow documentation](https://learn.microsoft.com/en-us/windows/win32/api/qos2/nf-qos2-qosaddsockettoflow) concerns outgoing traffic provisioning and does not establish a fix for the observed inbound queue.

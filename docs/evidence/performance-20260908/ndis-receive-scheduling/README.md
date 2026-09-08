# NDIS receive scheduling and the Intel telemetry thread

2026-09-08. **A controlled change to one Intel telemetry thread's priority removed the reproduced hundred-millisecond steady-state stalls and raised native commit throughput to 59.5–59.6 Hz. Restoring its original priority brought the stalls back.** The thread and process were restored after testing. This establishes a useful mitigation for the measured environment; it does not establish physical 4K60 or two-frame display latency, and no automatic third-party process adjustment was added to Viewflow.

## Where the slow receives execute

A focused WPR profile recorded TCPIP event 1170 (`UdpEndpointReceiveMessages`) with stacks, plus kernel network and process/module metadata. Both captures have zero lost events and zero missing delivery stacks. Microsoft public symbols resolved the NDIS/TCPIP/kernel addresses. The profile uses documented [event-ID filters](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/eventfilters) and the [provider stack option](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/eventprovider).

For the original High-process/TimeCritical-thread capture, all 48,013 selected delivery events match the count and ordered payload lengths of the 48,013 kernel UDP receive events on the owned endpoint. Local/remote IPv4 addresses and port are checked. This is ordered length/endpoint matching, not cryptographic packet identity. All delivery stacks include:

```
NDIS periodic receive worker
  → ndisDoPeriodicReceivesIndication
  → ndisIndicateSortedNetBufferLists
  → ndisMIndicateNetBufferListsToOpen
  → TCPIP receive / UDP delivery
```

47,641 events enter that path through `ndisReceiveWorkerThread`. The remaining 372 enter it through the DPC callback `ndisPeriodicReceivesTimer`.

The 325.335 ms feedback span of frame 121 contains 181 timer-path connection datagrams and 19 worker-path datagrams. Eighteen timer batches of ten appear around encoded+9.94, 28.13, 46.64, …, 310.69 ms, followed by resumed worker delivery around 319.56 ms. The frame has 179 media packets; the connection counts also include control traffic. Frame 1240 similarly contains eight ten-packet timer batches before worker delivery resumes. These are the same kind of long gaps that the [prior NDIS ingress capture](../ndis-ingress/README.md) placed after the upper captured NDIS layer and before kernel UDP delivery.

This identifies the execution path at delivery. It does not directly record a blocked/ready interval for the worker thread, and a DPC's interrupted process context alone does not establish that process as a cause.

## A specific scheduling condition and two controls

361 of the 372 timer-path events occurred in the context of PID 8108 / thread 10144. Live inspection identified this as the long-running Intel SUR process `esrv_svc.exe`, service `ESRV_SVC_QUEENCREEK` (Energy Server Service queencreek). Its process class was High and the selected thread used TimeCritical, base priority 15. The NDIS receive worker, System thread 532, had base priority 8 (current priority 11 at inspection).

A process-class-only control changed Intel's process between High and Normal. The thread remained TimeCritical/base 15 throughout, as both direct readback and the [Windows priority table](https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities) explain. This control did not consistently remove stalls:

| Process class | Native commits/s | Feedback median ms | Maximum ms | Feedback >100 ms |
|---|---:|---:|---:|---:|
| High A1 | 53.129 | 8.106 | 539.317 | 7 |
| Normal B1 | 52.489 | 8.403 | 476.993 | 8 |
| Normal B2 | 55.601 | 8.716 | 167.654 | 3 |
| High A2 | 50.019 | 7.717 | 423.310 | 8 |

The stronger control then held the **process class at Normal in all four arms**, changing only thread 10144 between TimeCritical/base 15 and Normal/base 8. Process and thread creation times protected identity; before/after readback confirmed that the requested priority persisted through each trial.

| Thread setting | Native commits/s | Feedback median ms | P95 ms | Maximum ms | Feedback >33.33 ms | Feedback >100 ms |
|---|---:|---:|---:|---:|---:|---:|
| TimeCritical A1 | 56.970 | 7.341 | 14.994 | 341.105 | 9 / 1,345 | 2 |
| Normal B1 | 59.581 | 7.215 | 14.841 | 30.287 | 0 / 1,424 | 0 |
| Normal B2 | 59.520 | 7.719 | 15.839 | 26.490 | 0 / 1,423 | 0 |
| TimeCritical A2 | 54.711 | 8.317 | 17.511 | 372.832 | 14 / 1,307 | 5 |

These are 25-second trials in A1/B1/B2/A2 order, with frames below 30 excluded as startup. The source executable, Windows receiver/presenter, 3840×2400@60 fixture, and capture/encoding settings were unchanged. Socket tracing was enabled; desktop observation, WPR and NDIS capture were off during both four-arm controls. No synthetic UDP probes ran. The result strongly supports scheduling interference from this specific thread priority as a cause of the reproduced long receive stalls, rather than a need to rewrite Quinn's receive API or pace source bursts.

## Follow-up stack capture under the effective setting

A separate capture with Normal process/Normal thread recorded 48,260 matching delivery/kernel receive events, again with zero lost events and no missing stacks. 48,170 deliveries used the worker path and 90 used the timer path. Only 19 timer events occurred in the Intel thread's context, versus 361 in the original capture. Other timer contexts remained, including DWM and System.

The follow-up's largest steady-state feedback span was 44.394 ms; no steady-state hundred-millisecond stall occurred. This stack-instrumented run is not interchangeable with the lighter control trials. It shows that timer-path delivery is not eliminated completely and that other shorter delays remain. Startup frame 10 still had 148.756 ms feedback despite receiving its initial media promptly through the worker path, so the diagnosed receive stall does not explain all startup or presentation delays.

## Measurement limits and restoration

Native commits/s counts an application commit event. The logged feedback span starts after media enqueue and extends through source-side feedback handling. It excludes source capture/encoding and does not identify physical first presentation. The tables **do not measure capture-to-display latency or physical display FPS**. Two 25-second successful treatment runs are not a guarantee across reboots, service updates, different workloads or other machines. Current production defaults were restored after the tests.

No service was stopped, restarted or disabled. Intel's service remains Running/Auto, with the same process identity and original High process / TimeCritical thread settings. No registry, driver, NIC, security policy or input behavior was changed. All temporary outputs were removed, before/after monitor lists match, observed focus state is unchanged, and the temporary fixture rule was disabled. Final checks found no owned receiver/helper processes, no owned receiver/restore tasks and no active recording sessions.

Each priority experiment registered an independent, one-shot restoration watchdog and also restored in its normal cleanup path. The first process-class harness encountered the existing PowerShell restriction on running script files during cleanup, after its High A2 trial had already completed. Restoration was verified through a command without changing execution policy; the independent task was removed. Its watchdog action had been changed to a command-based action before the treatment trials. The corrected reproduction harness uses commands throughout. A first thread-control setup attempt exceeded the Windows command-line length limit before any priority change or stream trial; its logs are retained under `setup-failure/` and excluded from results.

## Files

- [All eight control summaries](esrv-control-comparison.json), [thread treatment/restoration state](esrv-thread-state.json), [process-only control state](esrv-priority-state.json), and [follow-up capture state](esrv-stack-state.json).
- `udp-stack/` and `udp-stack-normal/` contain compressed, endpoint-filtered events with resolved stacks, event counts, complete correlation results and source hashes. The raw ETLs remain in the isolated Windows directory as `udp-stack.etl` and `udp-stack-normal.etl`.
- Each `4k-*` directory contains source/receiver/producer/runner/cleanup logs, fixture metadata, clock/stage analysis and a summary. The clock mappings used for all selected stack examples remain valid through their analyzed spans.
- Reader source/project, WPR profile, build/validation logs, analysis and orchestration scripts are included. `esrv-priority-trials.py.recorded` is historical text; use the corrected `.py` harness for reproduction, after resolving the current process/thread identity. These are machine-specific diagnostics, not portable production startup scripts.
- [Final Windows state](windows-final-state.json), [recording state](recording-final-state.txt), and [verified source hashes](verified-final-source-sha256.json) confirm cleanup and unchanged production binaries.

# DPI-aware successful submission

2026-09-04: same 564x262 decorated frame, explicit 282x131 DIPs; existing
DPI-fixed Windows release binary from `raw-peer-dpi-attempt.md`. Linux sender
adds cooperative yielding every 16 fragments on its current-thread runtime.

```text
media sender: queued_packets=434 queue_elapsed_ns=440216 terminal_elapsed_ns=24473631 path_rtt_ns=1120438 cwnd=37440 lost_packets=3 congestion_events=1
receiver accepted and submitted the raw BGRA frame: receiver_received_ns=1419850350 receiver_native_submission_ns=1421325250; clock_rtt_ns=1011113 uncertainty_ns=505557. This is native submission only, not physical-display or end-to-end latency proof.
```

Sender exited 0. Receiver PID18116, Session1, exit0. Queueing took0.440ms;
start-of-send to terminal receipt24.474ms; receive-to-native-submit1.475ms.
The connection-wide lost-packet count includes possible probes/control; it
does not identify lost image chunks. Actual frame successfully reassembled.
The packet count differs from the earlier attempt because negotiated datagram
size can vary; don't compare packet counts as identical MTU runs.

One success after yielding does not prove yielding caused the improvement.
No repeated-run latency distribution or capture-to-display timing is established.
User visual confirmation of corrected scale/clarity was requested and is pending.

```text
Linux example source SHA256:
26149dbdab566b3bf19151a9f3dc8e5c85e6dde3c2d891d6a8be55ce9f5aa5b3
Linux release binary SHA256:
87f1ac6517a470c492420ca4215f4380ab171ba01f0680a2fd153f6cd53ee457
```

Temporary task `Viewflow Raw Test pTgxe7-r5` removed after exit; raw peer census
empty. Logs remain at `C:\Users\wilf\AppData\Local\Temp\viewflow-raw-live-pTgxe7-r5`.
No installed service, UAC setting, or firewall setting changed.

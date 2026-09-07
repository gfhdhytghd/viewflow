# DPI-fixed cross-host attempt

2026-09-04: native Windows release build and Linux release build passed.
Explicit logical dimensions 282x131 were sent for the 564x262 capture.
Source now uses scoped PMv2 awareness and target-window DPI resampling.

```text
example source SHA256:
fc3d3f3407e5addaa294170cba796e69dba631fe1ebaa3bf198ee59b061b9ff7
native proxy source SHA256:
e5a08cfa3c6e0fa45bb250f440f21cab2c76ca40c394577405e0cc85951b50f4
Windows source archive SHA256:
f3510717db76b4a64d5758afc5becdc66fda471f5edc43f63fe2be2fcfcb68b5
Windows EXE SHA256:
1ceefb4028907368b6d5bca9969b946c6bfc6c79813e8bb30282e628fedde82d
```

Windows build root:
`C:\Users\wilf\AppData\Local\Temp\viewflow-raw-peer-release-20260904-181838-YC0PaO`

Sender returned a real explicit rejection, not a session timeout:

```text
Error: receiver rejected raw BGRA frame: code=2 packets=372 chunk=371/445 first_arrival_elapsed_ns=1870600 last_arrival_elapsed_ns=46922320 normalized_source_age_ns=46850865 uncertainty_ns=1142167
```

Thus the first packet arrived 1.87 ms after receiver readiness, but the frame
was late at packet 372/445 (46.85 ms conservative normalized age). The unchanged
33.33 ms assembly budget rejected it before resampling/presentation, so this
run neither confirms nor refutes the DPI visual fix. Subsequent packet delivery
or handling, rather than initial arrival alone, needs investigation. Do not
infer a specific scheduler, congestion, or codec cause without further data.

Temporary task `Viewflow Raw Test pTgxe7-r4` removed after terminal state.
Logs remain in `C:\Users\wilf\AppData\Local\Temp\viewflow-raw-live-pTgxe7-r4`.
No global settings or installed services were changed.

# Two asynchronous VPL tasks: initial performance experiment

69 local/remote inputs match and six Windows CTests pass. The same executable compares AsyncDepth 1 and 2, with input surfaces allocated from QueryIOSurf recommendations and held until Data.Locked is zero. Output tasks have separate bitstreams/sync handles. Actual output timestamps map back to the accepted original PTS instead of assuming the newest input produced the current output.

| Trial | Depth | Distinct FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|---:|
| depth1-a1 | 1 | 40.688 | 69.918 | 86.848 | 153.139 |
| depth2-b1 | 2 | 50.109 | 70.985 | 74.033 | 154.632 |
| depth2-b2 | 2 | 52.991 | 59.169 | 75.876 | 143.213 |
| depth1-a2 | 1 | 38.545 | 71.807 | 88.772 | 154.908 |

Depth 2 improves throughput in both repeats. **This first candidate is not suitable for deployment.** Real EncodeFrameAsync calls return MORE_DATA for an accepted input before later output. Code inspection showed a pending last input could then block the one-frame mode or atlas resize, or delay a static final update. The performance workload kept submitting new frames, so these full-route metrics do not qualify lifecycle behavior. The [v2 candidate](../vpl-depth-v2/README.md) explicitly requests buffered output when the source cannot feed more frames. No production file was changed for this first candidate.

# Linux receive, decode and presentation timing

A separate native stderr file prevents diagnostics from interleaving with the parent clock protocol. The 14 build inputs and actual Linux executable hashes are retained. Build and two CTests pass. The repeat qualifies under the unchanged full-route analyzer, exits normally and removes its private nested compositor. Windows uses the current canonical VPL executable, with its pre/post identity checked.

After a 3-second warmup, 1158 presented samples give:

| CPU wall-time interval | Median ms | P95 ms | Maximum ms |
|---|---:|---:|---:|
| decode | 4.6032 | 4.9817 | 5.6192 |
| upload | 0.0715 | 0.1162 | 3.2399 |
| alpha | 0.0006 | 0.0013 | 0.0036 |
| draw_swap | 0.3821 | 0.7613 | 1.2171 |
| accept_total | 5.1720 | 5.7178 | 7.9874 |
| receive_to_accept | 0.0239 | 0.1372 | 2.3317 |
| geometry | 0.2175 | 0.7790 | 8.1582 |
| cuda_map | 0.0327 | 0.0582 | 3.1202 |
| cuda_copy | 0.0248 | 0.0372 | 0.1140 |
| cuda_unmap | 0.0086 | 0.0141 | 0.0821 |

Full-route result: 41.100 distinct FPS, upper-envelope latency median 69.707 ms, P95 86.649 ms, max 152.860 ms. This is a diagnostic run, not a new optimization or physical scanout measurement. CPU intervals include API synchronization; CUDA subintervals are not independent GPU work durations. Logging overhead is not subtracted.

Texture upload and ordinary geometry polling do not account for the missing tens of milliseconds; their measured medians are below 0.3 ms. Receive-to-accept is also short, while decoder submission averages around 4.6 ms at the median. The 8.16 ms worst geometry sample is retained. No queue, memory or geometry behavior was changed in production. The full-route total is now 60 qualified trials, plus the explicitly rejected mixed-log profiling trial.

# DMA motion runs 8–14 (2026-10-09)

All runs use fixed Windows integrated-v3 and depth 1. Source pool, priority, GPU queries and receiver alpha were varied explicitly; raw records and parameters remain in each run directory. No input was injected.

| Run | Change | Published frames/s | Sampled WGC-to-Wayland P50 / P95 ms | Stable input/focus/extent |
|---|---|---:|---:|---|
| 8 | Integrated baseline, GPU queries on | 30.90 | 60.27 / 76.75 | Yes |
| 9 | Source pool on | 43.80 | 56.11 / 71.89 | Yes |
| 10 | High queue priority on | 43.50 | 61.87 / 65.20 | Yes |
| 11 | GPU queries off | 48.85 | 45.57 / 62.68 | Yes |
| 12 | Integrated Linux, synchronous alpha | 49.65 | 52.25 / 56.60 | Yes |
| 13 | Asynchronous alpha | 50.75 | 36.91 / 53.74 | Yes |
| 14 | Presentation-counts Linux candidate | 51.35 | 52.37 / 56.92 | No |

Source pool recorded 878 adoptions in run 9 and six remaining bridge records across the whole session. It eliminates the intermediate copy for adopted sources, not the original WGC copy. Priority alone did not establish improvement. GPU queries introduced measurable instrumentation overhead, so latency/throughput acceptance should run without them.

Run 12 sustained receiver CPU-submit samples around 5.7 ms per frame; run 13 around 0.4 ms. These include synchronization/CPU submission, not isolated GPU alpha duration. Run 13 is a promising single controlled run, not sustained 60 FPS proof.

Run 14 first 20-second presentation summary reported DP-4, 795 presented, 68 discarded, two pending, no untracked commits, 39.78 unique-source feedback/s. That interval includes the static startup gate and is not the exact motion interval. Input changed, so it is not a controlled A/B latency comparison. It does establish that complete per-proxy presented/discarded feedback is available. Longer runs with an interior fully moving interval are needed for sustained presentation FPS.

Every run exited zero, drained its owned native process, restored the original wrapper and normal task. No normal binaries were changed by these test runners. Wayland feedback is not photon timing; WGC timestamps are not generator timestamps. The 6K60 and <=16.7 ms end-to-end goal remains unachieved.

## Normal deployment after tests

Windows normal config now points to fixed integrated-v3 (SHA256 D946A703FABCA9C794F4758A9D49A5490E00C678BD01FD0E1A7842B1770D62DB), with SOURCE_POOL=1. PID 9492 and exact executable path were verified. The first deployment attempt failed at .NET File.Replace's null backup argument; original files were manually restored and old PID 16296 verified before retry. The replacement helper then passed actual temporary-file forward/rollback tests. Retry succeeded after coordinating Linux peer reconnection. Backups: `C:\Users\wilf\Viewflow\backup-source-pool-20261009-retry1`.

Linux normal executable is the tested integrated candidate (SHA256 991d23e134d39c008da2765469f89a54c20a42c2e5af6a715c3527aef5b5e7d8), ASYNC_ALPHA=1; live /proc executable hash/environment and raw external-OES DMA upload were observed. Backup: `build/ivshmem-backup/async-alpha-production-20261009`.

Queue priority and GPU query timing remain off in normal configuration. Fullscreen DD remains opt-in and was not enabled. The normal desktop currently has only a small proxy, so normal-session 6K performance or user interaction acceptance is not claimed; the figures above belong to the controlled fixtures.

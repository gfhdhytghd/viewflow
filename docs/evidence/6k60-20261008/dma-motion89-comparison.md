# Motion8 versus motion9: owned source pool

Motion9 improves publication throughput and sampled latency, but neither run meets 6K60 or one-frame latency. Both use one in-flight slot. The source pool avoids an additional bridge copy for adopted snapshots; it is not a zero-copy pipeline.

Reproduce from existing logs with `python3 docs/evidence/6k60-20261008/analyze-motion89.py`. Full values, provenance, restore state and underlying analysis are in [comparison JSON](dma-motion89-comparison.json). No Windows access is needed.

| Exact motion-loop metric | Motion8 | Motion9, source pool |
|---|---:|---:|
| Generator submission FPS | 60.0007 | 60.0004 |
| Unique WGC timestamps / second | 49.2506 | 50.2004 |
| Published atlas PTS / second | 30.9004 | 43.8003 |
| Host accept-end / second | 30.8004 | 43.7003 |
| Sampled capture→Wayland P50 / P95 ms | 60.268 / 76.755 | 56.115 / 71.890 |
| Feedback sample count | 59 | 62 |

Host accept-end measures CPU submission completion, not display FPS. Feedback tracing is subsampled, so presented FPS is unavailable. WGC timestamps are not generation timestamps. Both runs have zero observed foreground changes, unchanged recorded last-input values, a single 6144×3456 atlas extent, zero CPU fallback/frame counters, and restore records confirming native drain, unchanged wrapper and normal task Running.

## Queue decomposition

Each cell is P50 / P95 milliseconds, selected by atlas PTS within the exact logged motion-loop QPC boundaries (618 and 876 completed transactions). Adjacent GPU, calibration, stage and publication records supply diagnostic association; they are not independent per-frame tracing IDs.

| Component | Motion8 | Motion9 |
|---|---:|---:|
| Host prefix wait | .002 / .005 | .002 / .004 |
| Import | .002 / .003 | .001 / .003 |
| CPU submission | .200 / .275 | .185 / .253 |
| Submit-end→GPU-start, calibrated estimate | 14.200 / 21.043 | 2.243 / 12.656 |
| D12 GPU copy timestamps | 3.632 / 3.952 | 4.338 / 4.832 |
| GPU-end→CPU-observed, derived estimate | 12.287 / 16.330 | 11.881 / 14.549 |
| Largest observed polling gap per transaction | 2.644 / 4.089 | 2.534 / 3.974 |
| Adjacent submission interval | 32.388 / 39.858 | 20.241 / 32.486 |

The clearest improvement is the pre-copy wait estimate, consistent with adopting an already-owned source snapshot rather than submitting another bridge copy. D12 copy itself is slightly slower in motion9. Hot mapping/import overhead remains negligible. Queue scheduling and producer-fence dependency are combined in the pre-copy estimate and cannot be separately attributed. The roughly 12 ms post-copy observation interval is much larger than the largest polling gap median; it cannot simply be labeled polling sleep. Specifically, copy_.poll calls report_timing after fence completion, and PendingPublication records done only after report_timing returns. Thus consumer_observed includes query-result Map/Unmap, GetClockCalibration and two trace writes. The timestamped copy interval also ends before ResolveQueryData. The derived tail includes this unmeasured GPU query-resolution work and CPU instrumentation overhead; it is not a direct fence-completion delay. A GPU-timing-disabled control is needed before attributing that tail to the production pipeline. Calibration call duration medians are .020/.019 ms; these are call durations, not guaranteed error bounds. Percentiles of components do not add to percentiles of total latency.

## Copy accounting

Motion9 logs **878 adoption records and six bridge records across the entire session**, including static gate/setup and teardown. These totals differ from the 876 publications selected inside the motion window. Do not claim the whole run eliminated every bridge operation. D11 query groups separately report 1006 WGC-to-owned-source samples (P50 3.511 ms, P95 6.097 ms) and six bridge-role samples. D11 snapshot-local sequence has no reliable PTS join, so these groups remain explicitly all-session, including gate. Source capture still copies pixels into owned GPU storage, followed by the D12 transfer; the improvement removes an extra bridge for adopted snapshots rather than all pixel copies.

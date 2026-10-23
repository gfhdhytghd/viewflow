# Direct staging GPU timestamps after display-layout repair

Bounded opt-in VIEWFLOW_SHM_GPU_TIMING=1 experiment, static four-worker CPU copy, normal compositor scheduling. Actual6144x3456 BGRA. Fixture30s, no injected input/focus, foreground changes0,103/104 proxy observations pinned (initial observation before pin). Normal binary and wrapper restored with original SHA256 hashes verified; receiver active.

76 completed GPU timestamp samples: copy interval P50 3.762ms, P95 3.926ms, max4.228ms.1548 source publications: readiness P50 4.838ms/P95 8.083ms; CPU shared publication2.943/3.916ms. These are separate distributions, not additive per-frame percentiles. Timestamp queries every20copies may affect scheduling; not a clean performance gain comparison.

Five receiver intervals:286/5.014769s,292/5.012337s,300/5.000167s,290/5.015398s,298/5.002797s. Not sustained60fps. Fixture submission60.012fps is not accepted or presented unique-frame rate.

CRITICAL timestamp audit:1386/1548 profile_shared_capture records have WGC SystemRelativeTime later than producer enqueue log QPC (minimum enqueue-minus-capture -8.9581ms). Raw sampled WGC-to-Wayland feedback36.568/40.505ms (80samples) is NOT accepted as strict capture latency while this discrepancy is unresolved. Atlas-submit-to-feedback39.173/43.376ms uses explicit producer QPC; neither measurement is photon latency. Offset calibration endpoint envelope ±0.0975245ms does not explain the several-ms guest-local discrepancy.

Next action: instrument callback-entry QPC alongside original WGC timestamp and retain original timestamps unchanged; audit actual capture timestamp semantics and virtual-display behavior before claiming end-to-end timing. GPU copy measurement establishes substantial cost in direct readback rather than only polling delay. No encoder changes. Goal remains unmet.

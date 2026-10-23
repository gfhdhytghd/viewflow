# Paced60Hz Present0 with both-end marker validation

Windows fixture Release rebuilt and bounded30s test completed. Exact6144x3456. Explicit steady-clock pacing yielded1800submissions/30.000348s=59.999fps, waitable max_latency1,zero timeouts,foreground changes0. This fixes the previous710fps workload confound.

1588 host pixel markers matched1588 guest markers by atlasPTS,sequence and generationQPC;zero mismatches/unmatched.1589source publications,1587unique sequences,1repeat,22gaps in observed source sequence range. One undecoded publication not silently counted. Host decodes only while holding SHM ownership (production lease enabled). This validates sampled marker identity through SHM, not every pixel or final GPU rendering.

Generation-to-callback P50 19.071ms/P95 26.165ms.80 generation-to-Wayland-feedback correlations P50 55.982ms/P95 67.655ms, min37.590ms/max72.208ms. Calibration endpoint envelope±0.09857ms; not photon latency. These are separate distributions and must not be percentile-subtracted to infer stage budgets. Receiver intervalacceptance roughly58.0–60.0fps,not proven sustained unique presentation60fps. Goal unmet.

Both guest production native/wrapper/probe and Linux receiver binary restored with hash equality checks. Runtime marker environment override removed, service active. Host backup moved to build/ivshmem-backup/pixel-stamp-host-native.backup; hash recorded separately. No mouse/keyboard injection,focus dispatch,plugin reload or VM reboot. Next use matched per-frame stages to target callback-to-feedback copy/upload/compositor waiting, preserving pixel identity verification.

Instrumentation caveat: current readback map_ms brackets marker decode/logging as well as Map and reports0.315ms median versus earlier~0.002ms without marker. Do not interpret this as a Map API regression; separate/relocate diagnostics before optimization comparisons. Per-frame marker logging itself changes CPU/I/O load.

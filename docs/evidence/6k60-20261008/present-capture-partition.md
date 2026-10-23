# Same-frame Present-to-capture partition

Added analyze-present-capture.py. It joins fixture sequence AND exact generated QPC with source pixel stamps, then maps the corresponding capture identity to callback QPC. Only actual6144x3456 frames are admitted; duplicate sequences are removed. All timestamps are guest QPC100ns, avoiding host calibration error. Present end means CPU API return, not GPU completion/display.

Runs progressive5/6/7 yielded respectively1600/1593/1544 joined identities, with zero generated-QPC mismatches. Median Present-call time:0.0488/0.0519/0.0456 ms. Median Present-end-to-callback:15.869/19.744/17.572 ms; p95:20.692/27.199/24.362 ms. Generation-to-Present-begin medians are below0.010 ms. Run7 remains confounded by an observed foreground change; its figures are diagnostic only, not a valid optimization comparison.

Thus CPU Present blocking does not explain the measured pre-capture latency for these waitable/present-zero runs. The unresolved interval includes GPU work, composition and capture delivery. No claim of GPU/display completion is inferred from API return. At callback time the latest completed Present call was often one sequence newer, but this does not prove a newer WGC frame was available: GPU/compositor processing may still be pending. Existing pool-drain evidence found no queued newer frame, so these data do not justify blind extra TryGetNextFrame polling.

No live state changed in this analysis. Existing raw logs plus per-run *-present-capture.json preserve reproducibility. Goal remains unmet. Next investigate GPU/composition-to-capture boundary using pixel-correlated GPU completion evidence and actual capture backend capability, rather than tuning already-small CPU Present duration or asserting photon timing.

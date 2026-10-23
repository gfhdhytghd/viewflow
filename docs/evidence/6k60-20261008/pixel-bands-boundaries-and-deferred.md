# Banded publication tail boundaries and deferred-output control

Both Windows Release builds and 6144x3456 hardware staging/publication pixel tests passed. Initial boundary build additionally passed WARP17x13 and shared-memory ownership/concurrent-integrity tests. Tests exercised per-band flush and tracing; second hardware test enabled deferred tracing.

## Boundary observation

physical-pixel-bands-boundaries1: 1516 correlated band frames. Callback-to-write median7.8653ms, P9514.7959ms, max99.7163ms. Worst frame pts42793977969: adopt-to-write98.5559ms, first poll2.510ms, CPU publication3.129ms, Map0.008ms, query max0.002ms, Unmap max0.001ms, pre-publish diagnostic/cleanup92.408ms. The latter block contains two fprintf calls plus moved-frame/pending cleanup; it does not individually distinguish file I/O from cleanup. This directly locates the dominant delay in that observed frame outside GPU polling/copy. Normal production per-frame metrics are disabled.

1518 host pixel markers all matched source. One observed foreground change means aggregate performance comparisons are confounded; marker matches verify identity bytes, not all rendered pixels or photon timing.

## Deferred-output control

Added opt-in VIEWFLOW_SHM_DEFER_BAND_TRACE. Snapshot diagnostic fields, release pending ownership, publish frame, then output band and pixel-stamp logs. No changes to ordinary default path. This removes pre-publication trace output but cannot eliminate other synchronous logs or subsequent-frame delay. Production-ready logging design still needed if further profiling confirms the bottleneck across diagnostic call sites.

physical-pixel-bands-deferred1 has only401 correlated band frames: observed residency moved/cropped away from full6K during the run and one foreground change. It is invalid for sustained6K performance acceptance. All403 host markers matched. Pre-publish cleanup max0.002ms; deferred two-log block max2.199ms. No92ms deferred event recurred, so this is not proof of eliminating the previous tail. Max callback-to-write96.1613ms: first poll82.020ms. Another81.6623ms frame still has unaccounted pre-write time, potentially other logging boundaries; do not claim causal proof without measurement.

Both bounded runs restored host binary hashes, guest binary/wrapper/probe hashes, and exact preexisting plugin inventories. Temporary plugin unloaded; Linux service active. No mouse/keyboard injection or focus operation. Candidate binaries and diagnostic switches remain experimental. Goal of sustained6K60 and <=16.7ms end-to-end remains unmet. Next isolate synchronous diagnostic output across all critical-path call sites, without comparing different resident extents or treating shifted stalls as eliminated.

# Asynchronous source diagnostics control

Implemented opt-in VIEWFLOW_ASYNC_TRACE=1 for profile records in Windows reverse main and shared_readback. Fixed4096-record queue,1024-byte record limit, try-lock producer, dedicated sink thread. Consumer releases queue lock before stderr I/O. Full queue, lock contention and oversize records increment an explicit dropped counter. Worker reports counters every256 records and drains/reports at graceful shutdown. Ordinary default logging unchanged. Source timestamps are formatted on producing thread, not on output thread.

Linux and Windows blocked-sink tests passed: producers fill bounded capacity and reject excess while sink deliberately waits; exact dropped count and complete drain validated. Windows Release and6144x3456 hardware capture/staging/publication pixel test passed with async tracing and per-band flush enabled. Local test startup was subsequently hardened against legitimate initial try-lock contention and passed again; production code unchanged.

Bounded live physical-pixel-bands-async1: no observed foreground change and all five accept intervals6144x3456, approximately59.5–60.1fps.1597 host pixel markers all matched source.1586 correlated band frames had callback-to-write median6.90535ms, P9512.6708ms,max45.8898ms. Pre-publication diagnostic/cleanup max0.026ms across1584 available records, versus92.408ms in prior synchronous boundary observation. No100ms source event observed in available records; this does not establish complete elimination.

Critical limitation:84 dropped diagnostic records reported, mainly try-lock contention can cause loss before capacity exhaustion. Analyzer flags this run invalid/confounded for complete performance acceptance.80 generation-to-Wayland-feedback samples median38.237ms,P9549.581ms,min27.447ms. These exclude photons, do not establish continuous presentation60fps and remain above16.7ms. All timings are descriptive of observed subset, not an accepted target result.

Host native hash and guest native/wrapper/probe hashes restored by runners, standalone deadline plugin unloaded and original inventory matched exactly. Receiver active after restoration. Backup moved to build/ivshmem-backup/pixel-bands-async-native.backup. No mouse/keyboard/focus operations.

Next: eliminate routine trace loss without allowing sink I/O to block producers, then repeat the same full6K control. The observed source-callback and host-presentation delays must still be reduced; fixing diagnostic overhead alone cannot satisfy the original objective.

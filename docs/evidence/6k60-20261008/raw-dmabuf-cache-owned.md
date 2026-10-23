# Raw DMA-BUF import cache candidate

Isolated synthetic test on EGL device 0; no production deployment or desktop/input/focus operations.

Command: `/tmp/viewflow-raw-dmabuf-cmake-build/viewflow_raw_dmabuf_upload_test --run 0`.
Build target: `viewflow_raw_dmabuf_upload_test`, opt-in `VIEWFLOW_BUILD_RAW_DMABUF_PROBE`.

Actual 1024×1024 BGRA results in `raw-dmabuf-cache-owned.log`:
- First import plus 32 same-dimension repetitions: 1 successful EGL import, 32 cache hits.
- Mean wall time per warm upload, including glFinish and fence retirement: 0.272112 ms. This is a short synthetic 4 MiB measurement, not a 6K throughput or latency claim.
- New per-frame owner wrappers still hit the cache. Reused FD integer with a different dma-buf inode creates a new import. Changed dimensions create a new import. More than eight geometries evict idle entries and keep cache size at eight.
- Full 4 MiB sampled snapshot verification, including BGRA swizzle and alpha: zero mismatches before/after FD reuse and eviction.
- Slot leases remain held until fence polling and expire afterwards even though the import remains cached.
- Memfd residency remains 4 MiB; tail residency is zero.

Cache identity includes fstat device/inode, byte offset, pitch, dimensions and EGL display/context, not the integer FD or ephemeral wrapper address. Each entry retains the export owner so that the inode cannot be recycled while cached. Cache entries never retain SharedPixels. Jobs retain both SharedPixels and their entry until the GPU fence completes. Idle-only LRU eviction runs on the current-context rendering thread. If all eight entries remain in flight, a local glFinish completes the existing jobs before reclaiming an entry; no timing cutoff or session teardown is involved. Destruction drains jobs before clearing imports.

No old scratch socket or Windows VM validation was run for this cache change. Existing Windows-to-Linux 6K helper evidence predates caching. The test harness also now unbinds its validation shader before deleting it, avoiding a stale current-program restore in subsequent helper calls.

## Cached import observes changing source contents

Follow-up actual run, logged in `raw-dmabuf-cache-dynamic-owned.log`: the same dma-buf inode, dimensions and EGLImage were reused for 32 different complete 4 MiB patterns. Revision adds `revision*17` to every source byte modulo 256, including alpha. Each CPU write was bracketed by successful `DMA_BUF_IOCTL_SYNC` START/END with WRITE. Each preceding GPU copy was completed before the next CPU modification. Every revision was GPU sampled and fully read back: zero mismatches/stale bytes, one total EGL import (64 cache hits including the static repeats). Export lifetime and slot retirement tests still passed, resident 4 MiB and tail zero.

This verifies source updates through the cached import on this driver's CPU producer path. Cache rebinding is not producer synchronization: production must publish only after the Windows GPU producer fence completes, and the receiver must retain the slot until its own GPU fence completes. A dynamic Windows GPU production fixture remains necessary to validate that producer's visibility and ordering; no live Windows bank was sampled without a lease.

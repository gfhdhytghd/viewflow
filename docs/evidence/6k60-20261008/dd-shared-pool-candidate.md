# Desktop Duplication shared-source candidate

Default-off switch: `VIEWFLOW_SHM_D12_DD_SOURCE_POOL=1`. Existing fullscreen routing must separately be enabled with a compatible reserved output. No test execution, deployment, or desktop input was performed for this candidate.

## Data path and ownership

The first eligible direct DD frame binds a lazy SharedCapture pool to that lane's actual Transport D12 device. Subsequent acquisition copies the borrowed DD texture directly into an owned shared texture, signals the producer fence, and returns the snapshot immediately in the same poll call. It does not wait for an EVENT query before Source publication. Transport.enqueue_owned queues a GPU wait on that producer fence and retains the snapshot through D12 consumer completion.

FullscreenWindowCapture separately retains the DesktopCapture::Frame and producer snapshot. Later polls release the DD acquisition only after its producer fence completes. This frees the borrowed frame independently of the longer D12 consumer lifetime. Source's current shared snapshot carries its own device reference; WGC pool binding remains separate. Cross-lane device mismatch, atlas composition, and padding continue through the original bridge.

Pool busy means no GPU copy was submitted: the newly acquired DD frame is immediately released and the previous Source snapshot remains. Failed shared submission may have queued GPU work, so a preallocated EVENT retains the DD frame until completion; the feature then falls back to ordinary DD copying. Query failure replaces the EVENT and keeps the lease; restore and teardown drain pending producer access before releasing acquisition. In-flight consumer snapshots remain alive through their existing shared ownership after pool destruction.

The new copy timing scope is `DD-to-owned-source-GPU-copy`, distinct from WGC source and bridge copies.

## Build and validation boundary

Windows MSVC Release build passed for `viewflow_windows_reverse` and `viewflow_d12_shared_texture_probe`. Neither executable was run. Saved:

`C:\Users\wilf\Viewflow\fusion-20261007\build-16k\Release\viewflow_windows_reverse.dma-dd-pool.exe`

SHA256: `d825a3f4806affe4c49338f6db2cf03f1c18deaaa1cc5412a0cd860e16ba9fe7`

The previously executed private SharedCapture probe covers the same shared-texture allocation, producer fence, pool lease retention, D12 private copy, and lease release components. It does NOT exercise this new DD adapter orchestration. New DD acquisition retirement, busy handling, injected Signal/query failures, output loss, restore during consumer activity, cross-lane fallback, capture/version matching, and actual end-to-end FPS/latency remain untested runtime boundaries. Build success alone does not establish them. Fixed v3/v4 artifacts and normal services were not modified.

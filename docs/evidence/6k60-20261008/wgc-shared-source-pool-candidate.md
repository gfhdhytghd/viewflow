# WGC shared source pool candidate

Implemented behind `VIEWFLOW_SHM_D12_SOURCE_POOL=1`, default off. No production deployment or desktop interaction was performed.

An eligible single-window direct transport lazily initializes a Source-owned SharedCapture pool bound to its D12 device. Subsequent WGC callbacks copy the existing content crop directly to a shared NT texture and publish its snapshot/SRV together with capture metadata under the Source lock. Transport adopts that snapshot using its producer fence and consumer lease, eliminating the second owned-bridge copy.

Busy pool leaves the old pixels/version intact without a GPU wait. Shared allocation/submission failure preserves the pool for management-thread teardown and resumes ordinary capture in a newly allocated nonshared texture, avoiding writes into a leased shared snapshot. Source removal already stops/joins callbacks on management before destruction. The four-slot pool allocates lazily.

Atlas composition, padding, staging/banded capture, and activity lanes with a different D12 device keep the original bridge. DD snapshot publication clears the WGC shared-snapshot pointer; DD still uses its existing bridge path. No ordinary DD texture is treated as a leased shared source.

`SingleTransport` and `Transport` provide `enqueue_owned(shared_ptr<SharedCapture::Snapshot>, metadata)` with producer-state, extent/format, and canonical D12-device identity validation. Both routes use the same FIFO/admission/publication implementation. The new route never calls SharedCapture::capture inside Transport.

## Validation

Windows MSVC Release build of `viewflow_windows_reverse` and `viewflow_d12_shared_texture_probe`: PASS.

Executed the existing private synthetic probe only (no capture, no IVSHMEM, no input):

- Both enumerated Intel Graphics hardware adapters passed.
- Each adapter copied three 6144×3456 BGRA frames, 84,934,656 bytes per frame.
- All six full-byte comparisons had zero mismatches.
- Every transaction reported source lease retained by copy and released after copy.
- D3D11 and D3D12 device-removed reasons remained S_OK.

This probe validates the modified shared texture/SRV pool and downstream private-memory GPU copy. It does not exercise live WGC Source callback integration, production enqueue_owned, FIFO under two concurrent production frames, or latency improvement. Those remain pending the root-owned controlled benchmark.

## Candidate artifact and handoff

Preserved Windows candidate:
`C:\Users\wilf\Viewflow\fusion-20261007\build-16k\Release\viewflow_windows_reverse.dma-source-pool.exe`

SHA256: `09F9F4E659A6B492FF20BC7F235AEE7ABC7EA76D89EB66A8986C0C40125E4717`

Main source locations at handoff:

- `platform/windows-reverse/main.cpp:118`: Source pool, shared snapshot, binding device and attempt/failure state.
- `main.cpp:471`: WGC shared crop submission and busy/ready/error handling.
- `main.cpp:493`: ordinary fallback clears snapshot and forces a fresh texture when the old one was leased/shared.
- `main.cpp:619`: DD publication clears the WGC shared pointer.
- `main.cpp:1156`: default-off feature switch and lazy direct-source pool initialization.
- `main.cpp:1176`: same-device direct snapshot adoption; all other routes retain the bridge.

Pending live validation must establish actual `profile_d12_adopt` records from WGC, matching capture version/geometry, absence of second bridge copy for adopted frames, correct busy/resize/fallback behavior, and measured FPS/latency. The private probe cannot establish any of these main integration properties. No further private probe repetition is needed for this handoff.

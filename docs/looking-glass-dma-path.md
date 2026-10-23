# Fullscreen GPU-direct transport work

Status: implementation/probing in progress; not an active transport path.

The target remains 6144x3456 at sustained 60 fps and generation-to-presentation
within 16.7 ms. CPU-only tests, heap creation, and build success do not establish
that target. Software presentation feedback is not photon latency.

## Reference and current differences

Reference inspected: Looking Glass commit
`cdba29f2f6bcae3ded26369fc231a067cbca3752` from
https://github.com/gnif/LookingGlass .

Its Windows D12 implementation imports the IVSHMEM address with
`ID3D12Device3::OpenExistingHeapFromAddress`, creates aligned placed buffers, and
publishes after GPU copy completion. Its IVSHMEM mapping requests write-combined
cache mode (2). Viewflow currently requests cached mode (1), and copies mapped
D3D11 staging textures into separate pixel banks on the CPU.

Desktop Duplication's shared texture import in Looking Glass is not proof that
WGC capture textures have the same sharing flags. The window path must inspect
actual sharing capability; otherwise it needs an explicitly shared intermediary
and cross-API GPU fence, adding a GPU copy but avoiding CPU staging.

Linux KVMFR/DMA-BUF import is a separate capability from Windows GPU writes.
The current host has no observed /dev/kvmfr device; ordinary shm files cannot
simply be relabeled as DMA-BUFs. Current CUDA host-memory uploads remain the
fallback until the real backend and renderer import are verified.

## Integration boundaries

1. Probe D3D12 capability and external private-RAM heaps separately from live
   IVSHMEM. A successful private test does not validate the driver mapping.
2. Probe actual IVSHMEM only with exclusive scratch storage, never by placing a
   test resource over a running stream's control header or pixel bank.
3. Select/cache placed resources using actual heap alignment and copy footprints.
   Preserve bank leases until both producer GPU work and consumer access finish.
   Publish only after the GPU fence establishes written pixels are ready.
4. Negotiate fullscreen transport hints independently of input commands. Linux
   actual fullscreen state, output physical dimensions, and matching source
   geometry are needed. Enter/exit must retain the last complete snapshot until
   the replacement route produces a matching frame.
5. Fullscreen single-window GPU-direct transport can retain WGC. Switching to
   Desktop Duplication additionally needs a correct guest-output binding; a
   Linux-fullscreen proxy alone does not prove the guest monitor contains only
   that window. Do not replace a window stream with an unrelated whole desktop.
6. Failed or unsupported DMA imports fall back locally to the working raw path;
   they do not terminate unrelated streams. Preserve on-demand 16K maximum
   capacity rather than allocating all maximum frame storage at startup.

Live input/focus tests remain user-operated. Host research jobs are preserved.

## Actual guest copy-layout query

The standalone probe now queries GetCopyableFootprints without allocating texture
storage or submitting GPU commands. Windows Release build and default execution
passed on both enumerated Intel adapters. Both reported:

| BGRA dimensions | Logical row bytes | D3D12 pitch | Required bytes |
| --- | ---: | ---: | ---: |
| 6144x3456 | 24576 | 24576 | 84934656 |
| 6143x3456 | 24572 | 24576 | 84934652 |
| 16384x16384 | 65536 | 65536 | 1073741824 |

The target 6K size can match the current tightly packed layout; this does not
prove actual IVSHMEM import or texture copying. Arbitrary window widths cannot
reuse the tightly packed protocol blindly: 6143-wide frames already require
padding. A future direct path must either negotiate row pitch or retain the
ordinary path for such layouts. The 16K query allocates no 1 GiB frame.


## Reusable component and handoff validation

The probe now uses `d12_external_heap.hpp` for imported-heap and placed-buffer
ownership. The buffer retains the heap; the heap retains the mapping owner.
Bounds use actual GetResourceAllocationInfo results, not logical pixel size
alone. Queue completion remains the caller's responsibility before release.
Windows build and the 6K private-texture copy test passed on both Intel adapters
with zero mismatches; weak-owner checks confirmed retained_by_buffer=1 and
released_after_buffer=1. Evidence: d12-external-heap-6k-windows.log.

The runtime-independent fullscreen_dma_transition state machine passed Linux
and Windows CPU tests. It retains the active route while a new matching complete
frame is pending, permits ordinary old-route updates for the same window,
rejects obsolete route tickets, and requests local fallback after DMA failure.
It owns no actual pixels or GPU leases. Neither this state machine nor the heap
component is yet connected to the production streaming queue or fullscreen
feedback protocol. Actual IVSHMEM testing still awaits restart confirmation.


## Nonblocking texture copy component

`d12_external_copy.hpp` supplies one in-flight texture-to-external-buffer copy
with retained source/destination ownership, nonblocking submission, fence polling,
and completion-based resource retirement. A failed queue Signal keeps resources
and retries synchronization; no frame-time threshold causes retirement. The
caller must provide a synchronized COPY_SOURCE texture and exclusive COPY_DEST
buffer. D3D11 sharing is now exercised by the separate capture probes below;
production queue integration is still absent.

Windows Release build passed. The 6K probe now drains its synthetic upload
preparation queue, submits through this component, polls completion, and checks
all 84,934,656 bytes. Both Intel adapters passed with zero mismatches and correct
mapping-owner retention/release. Evidence: d12-external-copy-6k-windows.log. This
single-copy correctness run is not a throughput benchmark, fault-injection test,
allocator-reuse stress test, or actual IVSHMEM validation.


## Capture lifetime constraint found in current source

`platform/windows-window-capture/wgc_window_capture.hpp` defines the WGC surface
as borrowed only for the callback and disallows retaining the WGC surface/frame.
The existing callback enqueues its copy before returning. A D3D12 COM import
alone does not establish an independent pixel snapshot after that callback.
The first window-path integration should therefore copy inside the callback to
an owned, shareable D3D11 texture and signal a shared fence. The D3D12 copy queue
must wait on that fence before writing the external buffer. Keep that owned
texture leased until the destination copy completes. This adds a GPU-side copy
but can still remove the staging-map/CPU-copy step. Desktop Duplication's source
ownership is a separate backend contract, not an automatic replacement for WGC.

## Actual desktop texture direct-copy validation (2026-10-09)

The separate `viewflow_d12_desktop_copy_probe` now validates that contract on the
guest's actual 6144 x 3456 desktop output. It holds the Desktop Duplication frame,
directly imports its shared texture into D3D12, and copies into an external
private-RAM heap. All 84,934,656 bytes matched an independent staging reference;
both devices and ReleaseFrame reported S_OK. See
`evidence/6k60-20261008/d12-desktop-copy-windows.log`.

This is a correctness result only. The reference copy is diagnostic overhead,
not a proposed production step. Actual IVSHMEM mapping, Linux GPU import, and
fullscreen backend switching remain pending; no production route was enabled.

The capture code is now reusable in `d12_desktop_capture.hpp`, with stable
adapter LUID/output-name binding and an acquired-frame lease. Consumers must
retain that lease through GPU completion. Access loss requests local duplication
recreation; pending frames do not destroy the session. The probe using this
component and `ExternalCopy::wait` passed the same full-frame comparison (see
`d12-desktop-lease-windows.log`). `wait` uses fence completion events instead of
normal-path fixed polling sleeps; no latency improvement has yet been measured.

## Existing SHM1 external-write publication interface (2026-10-09)

`Frames::Write` now exposes `slot_index()` and `external_destination()` for an
already reserved slot. The span covers only the tightly packed image extent.
After successful GPU completion and visibility, the caller may invoke
`complete_external(width*4)` and the existing `finish()` to publish the unchanged
SHM1 reference. Padded pitches, CPU/external mixing, incomplete publication and
duplicate completion are rejected. Readers cannot acquire the slot before
finish, even after completion is marked. No pixel clearing or maximum-capacity
allocation is introduced by this interface.

The caller must retain the transaction, Frames instance and mapping through
GPU completion, including error/cancel paths: the existing writer destructor
releases the slot and does not drain a GPU. The production pending-publication
owner has not yet been connected, so this interface does not enable DMA by itself.
Linux strict g++ compilation/test and Windows Release build/test passed with
assertions enabled, including existing concurrent integrity tests. The new tests
simulate the external producer on CPU; they do not establish actual DMA fence
visibility, IVSHMEM support, or performance.

## Pending GPU publication owner (2026-10-09)

`d12_publication.hpp` now couples ExternalCopy with the SHM1 writer transaction.
It retains Frames, mapping and capture owners, validates the selected slot's
actual heap base/extent and tight copy footprint, and creates/caches only an
image-sized placed buffer at offset zero. Poll publishes the existing reference
only after GPU completion. Cancel/destruction drains submitted work before
releasing the reserved slot. A missing/incompatible heap does not submit a copy.
The reusable component is not yet wired into the production main loop.

`Mapping::pixel_bank` returns a separately mapped bank plus shared mapping owner;
legacy contiguous layouts are rejected. Cache policy is unchanged. The Windows
main candidate still builds with this accessor. Import support and whole-bank
residency must be established separately before enabling it.

Windows Release `viewflow_d12_publication_probe --6k` passed on its first hardware
adapter: slot 0 stayed writing before poll, published pixels acquired through
Frames matched all 84,934,656 bytes, and a second canceled submission returned
slot 1 from writing to free. Both device-removal checks were S_OK. Evidence:
`evidence/6k60-20261008/d12-publication-6k-windows.log`. These are synthetic private
banks, not actual IVSHMEM; cancellation was not tested with an artificially
stalled fence, and throughput/end-to-end latency remain unmeasured.

`PendingPublication::begin_with_bank` now resolves the heap only after choosing
a writable slot and validating the tight footprint. The 6K probe was rerun with
a lazy provider: two transactions requested/imported exactly their selected
banks 0 and 1, leaving 2 and 3 unimported. Pixel and cancellation checks passed
again (`d12-publication-lazy-6k-windows.log`). This avoids eager imports during
initialization; it does not establish the physical residency cost of each bank
once that bank is imported.

## Opt-in Windows sender integration (2026-10-09)

The Windows main loop now includes `d12_transport.hpp`, selected only with
`VIEWFLOW_SHM_D12=1`. It creates D3D12 on the D3D11 capture adapter, retains frame
metadata while PendingPublication runs, and emits normal SHM1 only after
completion. A lane enters DMA only after CPU readback becomes idle; no newer CPU
frame is queued while DMA is pending. Unsupported layouts/import failures use
the existing CPU readback locally. Completion failure forces another frame so
an unchanged source is not left permanently skipped.

The candidate path needs `VIEWFLOW_SHM_PROGRESSIVE=0` and
`VIEWFLOW_SHM_CAPTURE_STAGING=0` (unset capture bands for clarity). Existing
SHM2/staging/bands configurations retain their original paths. Logs distinguish
requested, initialized and first actual GPU submission; profile counters include
DMA submitted/published and CPU frames, so a requested-only path is not treated
as hardware success. Banks are imported on their first selected use, with no
cache-policy change.

Windows Release main build and diff checks passed. The candidate was **not
installed as the running sender**, and actual bank import/coherence/residency,
fallback behavior and throughput remain unverified. Existing normal service
remained active. This path uses an owned shared intermediate texture and removes
CPU framebuffer copying; it is not yet the fullscreen Desktop Duplication direct
capture route, nor Linux KVMFR/EGL import. Do not enable it by default based on the
private-RAM probes alone.

## Production IOMMU constraint discovered after scratch validation

The actual VM uses `platform/qemu/viewflow-cpu-only-ivshmem.patch`. Its VFIO
listener explicitly skips all `viewflow_cpu_only_*` regions; the four production
banks use that prefix. This is what keeps their 4 GiB virtual aperture sparse,
and those banks MUST NOT be submitted for GPU DMA. The new scratch device lacks
that prefix and is DMA mapped, so its WC/cached successes remain valid but do
not establish production-bank eligibility. The proposed import-only production
bank test was canceled before stopping services or opening a bank.

`BankLayout.reserved` bit 0 is now the explicit host declaration
`bank_gpu_dma_mapped`. Existing preparation leaves it zero; live metadata was
read back as zero. Mapping's GPU bank accessor and Transport initialization
reject that unsupported DMA configuration before any import/submission, retaining
CPU readback. This is an IOMMU capability constraint, not an authorization,
focus or frame-age restriction. Merely setting this bit does not create an IOMMU
mapping: a future host-side DMA-capable backing setup must establish mappings
before advertising it. No live flag was changed.

The Windows candidate and shared-frame tests rebuilt successfully. No production
DMA was attempted. Enabling DMA on maximum-sized stock VFIO backings would pin
their full capacity, so a genuinely demand-sized DMA mapping/backing design is
required before promoting the candidate. The current source/candidate remains
disabled for the live CPU-only banks.

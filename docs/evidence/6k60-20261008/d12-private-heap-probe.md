# D3D12 private allocation probe

Source: `platform/windows-reverse/d12_heap_probe.cpp`. Independent implementation
using the documented D3D12 API sequence also used by Looking Glass D12:
[upstream d12.c](https://github.com/gnif/LookingGlass/blob/master/host/platform/Windows/capture/D12/d12.c).
This is not integrated into the production capture or transport.

Build from an x64 Visual Studio Developer Command Prompt with a Windows SDK:

```bat
cl /nologo /std:c++20 /EHsc /W4 /O2 platform\windows-reverse\d12_heap_probe.cpp /Fe:viewflow_d12_heap_probe.exe /link d3d12.lib dxgi.lib setupapi.lib
```

Modes:

```bat
viewflow_d12_heap_probe.exe
viewflow_d12_heap_probe.exe --test-private-heap
viewflow_d12_heap_probe.exe --test-private-copy
```

The default mode enumerates hardware adapters, creates a D3D12 device, queries
ID3D12Device3 and D3D12 OPTIONS, and reports HRESULT/device removal. It creates no
command queue. The heap mode additionally reserves and commits its own 4 MiB
VirtualAlloc allocation, checks 64 KiB alignment, imports that address, and tries
a 1 MiB row-major cross-adapter buffer in COPY_DEST state. It submits no GPU work.
The copy mode additionally fills an upload buffer with a nonuniform byte pattern,
issues one 1 MiB COPY queue transfer into the imported allocation, waits for its
fence, and checks all bytes through the original CPU allocation address.

The three modes above do not open a device file or existing IVSHMEM bank. No mode performs capture, focus changes,
input injection, display mode changes, or desktop rendering occur. Each adapter
has its own allocation and COM objects. Resource, heap and device references are
released before VirtualFree. Submitted copy work must complete or device removal
must be observed before releasing allocations. A failed queue Signal without
device removal deliberately waits rather than freeing potentially live memory;
the parent process may terminate a stuck standalone probe. A stalled GPU fence
also leaves the probe waiting. This is not a session watchdog or product policy.

Exit 0 means hardware enumeration completed, not that every capability or copy
succeeded. Inspect individual HRESULTs and `private_gpu_copy ... result=passed`.
Even a passing private-RAM copy is not proof that the guest IVSHMEM mapping can be
imported, that DMA writes are coherent on the Linux side, or that capture, frame
ownership, synchronization and presentation are correct. It proves no 6K latency
or throughput target. Default execution does not prove a GPU copy.

Implementation created without executing the probe. Build/runtime results must
be recorded separately by the integrating agent.
# Executed result

Additional executed mode: `--test-private-texture` built and ran on both guest
Intel adapter LUIDs. Upload buffer -> 6144x3456 BGRA8 DEFAULT texture -> placed
external private-RAM buffer completed, with all 84,934,656 bytes verified and
zero mismatches on each adapter. Reported device-removed checks remained S_OK.
See `d12-private-texture-6k-windows.log`. This verifies full-size texture-copy
correctness only: no WGC source, IVSHMEM mapping, Linux renderer, sustained FPS,
or end-to-end timing was involved. Pending restart was not performed.

The Windows Release probe and fullscreen route test built successfully. Route
tests passed on Windows and Linux. Executed `--test-private-copy` on the guest:
both enumerated Intel Graphics adapters (8086:7d67, distinct LUIDs) supported
Device3 and external private-memory heap import. Both created the placed buffer,
submitted the COPY queue, completed its fence, and verified all 1,048,576 bytes
with zero mismatches. GetDeviceRemovedReason remained S_OK at reported checks.
Raw output: `d12-private-copy-windows.log`.

This is real GPU writing to private CPU-addressable RAM, not actual IVSHMEM,
not a capture texture transfer, and not an end-to-end performance measurement.
No live frame banks or host research processes were modified. Actual IVSHMEM
mapping/caching compatibility and fullscreen transport integration remain pending.

## Explicit dedicated IVSHMEM scratch mode

Additional link library: `setupapi.lib`. Existing private modes retain their
behavior. A fourth explicit mode accepts the PCI bus and device slot (function
is fixed at zero) plus the exact byte count:

```bat
viewflow_d12_heap_probe.exe --test-ivshmem-copy 0 10 16777216
```

This example is only valid after the operator has provisioned a separate unused
16 MiB scratch device at that exact location. The probe uses SetupAPI to find
exactly one matching IVSHMEM interface; it never selects a device by enumeration
index. Invalid bus/slot/size arguments return before device enumeration. A driver
mapping must report exactly 16 MiB before any heap import or copy. Mapping uses
virtio-win IOCTL function 0x802, cache mode 2 (write combined). It does not use
Viewflow's Mapping class and never recovers or edits production frame metadata.
The device handle outlives all GPU resources, heaps and devices.

The COPY test writes only the first 1 MiB using byte formula
`(i * 37 + (i >> 8) + 91) & 255`, where `i` starts at zero. Linux can independently
recompute this pattern in the separate scratch backing file after the GPU fence
completes. `ivshmem_scratch_gpu_copy ... result=passed` checks the Windows mapping
only; host-side verification is separate and remains required. Provision/clear
the scratch file before a new run to distinguish new writes from stale bytes.

The size guard and explicit PCI location prevent accidental automatic selection
of existing Viewflow control/bank mappings. They cannot identify ownership of
an arbitrary separately configured 16 MiB device: the operator must supply the
location of the dedicated scratch device. No device was opened or probe run while
implementing this mode.

## Explicit private 6K texture round trip

```bat
viewflow_d12_heap_probe.exe --test-private-texture
```

Only this mode allocates a full 6144×3456 BGRA8 image (84,934,656 bytes) per
hardware adapter, sequentially. A 64 KiB-aligned VirtualAlloc region sized to the
rounded-up buffer extent backs the imported external heap. The probe fills an
upload buffer with the per-channel pattern
`(x*17 + y*29 + channel*61 + (x>>8) + (y>>8)) & 255`, where channel 0..3 means
B/G/R/A. It copies that footprint into a DEFAULT BGRA8 texture initially in
COPY_DEST, transitions the texture to COPY_SOURCE, then CopyTextureRegion writes
the texture into the placed external-heap buffer. GetCopyableFootprints supplies
the transfer layout; the test rejects unexpected non-tight layouts instead of
claiming full-byte verification while skipping padding.

After the COPY queue fence completes, the original CPU VirtualAlloc address is
checked across all 84,934,656 bytes. Look for
`private_texture_6k_gpu_copy ... mismatches=0 ... result=passed` and all HRESULTs.
This is synthetic texture-transfer correctness only: it does not capture a
window/desktop, open IVSHMEM, inject input, or measure capture/performance or
end-to-end presentation. Other modes keep their smaller allocations and prior
behavior. Source implementation alone is not proof of a passing run.

## Shared external heap ownership primitive

The probe now uses `d12_external_heap.hpp` for imports and placed buffers.
`ExternalHeap` retains the mapping's shared owner and D3D12 device/heap references;
`ExternalBuffer` retains its heap owner and releases its resource first. Import
checks the returned heap size and actual heap alignment against the backing
extent/address. Buffer placement checks GetResourceAllocationInfo size/alignment,
the heap's actual alignment, and overflow-safe bounds in both heap and mapping.
Invalid arguments, allocation failures and D3D12 failures return HRESULT plus a
stage diagnostic; device removal is checked after import/resource creation.

The caller still owns queue/fence synchronization. It must finish GPU work before
releasing the last buffer: these wrappers do not wait for queues or implement
transport. The probe drops caller ownership of private pages after heap import,
then drops its explicit heap reference while retaining the buffer, prints
`external_owner retained_by_buffer=1`, releases the drained buffer, and expects
`scope=private released_after_buffer=1`. Scratch main intentionally retains its
own shared mapping until all adapters are done, so immediate expiration is not
expected there. This ownership exercise does not verify real IVSHMEM transport.

## Reusable asynchronous texture-copy primitive

`d12_external_copy.hpp` adds `ExternalCopy`, a single-threaded helper with one
in-flight BGRA8 texture-to-external-buffer copy. initialize creates a COPY queue,
allocator, list and fence. submit records CopyTextureRegion and returns without
waiting. poll returns pending, complete or device_lost; fence UINT64_MAX is device
loss, never successful completion. The allocator/list are reset only after the
previous copy has completed. Source COM and destination shared ownership remain
held while GPU work is pending, so the external heap and backing mapping remain
alive as well.

The caller must first finish source production and cross-queue synchronization,
provide a COPY_SOURCE texture and COPY_DEST destination, and prevent writes/reuse
of both until completion. The helper contains no implicit D3D11 bridge or desktop
capture. It supports one BGRA8 2D subresource and validates the footprint against
the destination resource extent and device identity.

A queue Signal failure after ExecuteCommandLists still owns pending work. poll
retries the queue Signal to establish a reliable completion fence; it does not
free resources on the failed HRESULT. The destructor drains pending work, including
recovery signals, until actual completion or device removal. There is no 16.7/33
ms abandonment boundary. A permanently stalled device can block destruction.

`--test-private-texture` now first initializes the pattern texture with a separate
COPY queue, waits for that preparation fence, then submits the texture through
ExternalCopy and polls it before CPU verification. Its existing full-frame byte
check is unchanged. This is a correctness probe, not a performance measurement:
the preparation queue, sleeps and CPU verification are not a production frame
pipeline. No production capture/transport caller has been integrated by this
change. This implementation was not executed while adding the helper.


## ExternalCopy reuse validation

The private-texture mode now submits twice through the same ExternalCopy object.
After each completed fence, every byte is checked; before each submission the
private destination is cleared to prevent stale pixels from satisfying the
check. Windows Release build passed, and both Intel adapters returned zero
mismatches for both 84,934,656-byte copies with S_OK device checks. Mapping owner
retention/release checks also passed. Raw output:
`d12-external-copy-reuse-windows.log`.

This establishes basic allocator/list/fence reuse correctness, not sustained
60 fps, a benchmark, actual IVSHMEM, or capture interoperability. No restart or
production deployment was performed.

## Separate synthetic D3D11 shared-texture interop probe

Source: `d12_shared_texture_probe.cpp`. Link `d3d11.lib d3d12.lib dxgi.lib`.
`viewflow_d12_shared_texture_probe` takes no arguments and performs a synthetic
6K GPU correctness transfer for each hardware adapter. It allocates a D3D11
shared NT-handle BGRA texture, fills the same per-pixel pattern via
UpdateSubresource, and signals a D3D11 shared fence. D3D12 opens both handles on
the same adapter, uses queue Wait on that shared fence, then a local fence/CPU
drain before passing the COMMON texture (implicitly promotable to COPY_SOURCE)
to ExternalCopy. The external destination is private VirtualAlloc RAM and the
full 84,934,656 bytes are compared. Output records API HRESULTs, device removal,
per-adapter byte mismatch results and aggregate pass count. Exit 0 requires all
hardware adapters to pass; unsupported APIs report failure.

The extra CPU synchronization is explicitly correctness-only. Production should
connect shared-fence Wait to the actual copy queue without this CPU drain. Handles
and mapped-memory owners survive submitted work; failed post-submit signals are
retried while retaining objects until completion or device removal. No desktop,
IVSHMEM or input is accessed. This does not prove WGC original textures can be
shared. A production fallback still must copy WGC's borrowed callback texture
into an owned shared D3D11 intermediate inside its valid callback lifetime, then
signal a shared fence for D3D12. This probe tests that kind of owned intermediate's
interop mechanism, not the real WGC callback integration or any latency target.


## Executed D3D11/D3D12 sharing probe

Windows Release build and execution of viewflow_d12_shared_texture_probe passed
on both enumerated Intel adapters. Shared NT texture and shared fence handles
opened successfully in D3D12; queue Wait plus drained synchronization completed.
ExternalCopy then wrote the synthetic 6144x3456 texture to private imported RAM,
with all 84,934,656 bytes correct on both adapters and S_OK device checks.
Raw output: d12-shared-texture-6k-windows.log.

This supports the feasibility of the owned shared intermediary used by a future
WGC bridge. It does not test a borrowed WGC texture, real IVSHMEM, Linux rendering,
or performance. The probe's CPU synchronization drain is deliberate for isolated
correctness validation, not the intended production scheduling design.

## Shared producer fence dependency on the actual copy queue

ExternalCopy submit now accepts optional `(ID3D12Fence*, producer_value)` arguments.
The fence must belong to the same D3D12 device (open a shared D3D11 fence into that
device first). The copy queue issues Wait before executing CopyTextureRegion;
source, destination and producer fence remain retained until completion/removal.
No CPU producer wait is performed. Existing submit calls without a producer fence
retain their already-synchronized-source contract. A failed Wait submits no copy;
the caller must still protect any independently pending producer work. Signal
failure after copy execution retains resources and uses the existing recovery.

The synthetic shared-texture probe now passes its imported D3D11 producer fence
directly to ExternalCopy. The old separate synchronization queue and pre-copy CPU
drain are removed. A D3D11 producer lifetime guard handles every early failure
following UpdateSubresource, retrying producer Signal and waiting for completion
or removal before allowing its texture/fence to be released. Normal successful
flow waits only for the final copy completion before comparing all bytes. It
remains a synthetic correctness check, not a WGC or latency benchmark.


## Direct consumer queue dependency

ExternalCopy now accepts an optional imported producer fence/value and enqueues
Wait on its own COPY queue before the texture copy. It retains that fence until
completion. The D3D11 interop probe no longer CPU-drains a separate synchronization
queue before submitting. An independent producer lifetime guard still drains on
cleanup/early failure. Both probe targets rebuilt successfully.

The updated shared-texture probe passed on both Intel adapters: 84,934,656 bytes,
zero mismatches, device checks S_OK. Raw output:
`d12-shared-texture-queue-wait-windows.log`. This verifies the no-prewait code path;
it does not prove the producer was still pending when the GPU reached Wait,
quantify overlap, or establish sustained performance. Production WGC/IVSHMEM
integration remains outstanding; no restart was performed.

## Owned D3D11 capture bridge

`d12_shared_capture.hpp` provides SharedCapture: initialize validates an immediate
D3D11 context, Device5/Context4 support and matching D3D11/D3D12 adapter LUID.
capture records CopyResource from a borrowed BGRA8 source into its own shared
texture, then shared-fence Signal and Flush, returning an owned Snapshot with
opened D3D12 texture/fence/value. The borrowed source is not retained. Optional
D3D11_BOX cropping is bounds-checked (single 2D slice) and uses
CopySubresourceRegion into a texture with exactly the cropped dimensions. No
pixel Map or CPU readback occurs in the bridge.

A three-slot pool reuses an entry only when it has no owner outside the pool and
its producer fence is finished. Full pool reports busy so the caller can retain
the old picture; no stream close is implied. The caller must keep the Snapshot
itself alive through downstream ExternalCopy completion, not merely hold its
texture COM pointer. The immediate context and pool access are single-threaded
and require caller serialization. Failed producer Signals retain the slot;
subsequent reuse checks retry Signal without blocking, and final destruction
retains/drains pending producer work until completion or device removal.

The shared-texture probe now creates an ordinary non-shared synthetic source and
uses this bridge, followed by ExternalCopy. It verifies three full 6K frames with
different patterns (+53 per frame), holds the first snapshot while capturing the
second to prevent reuse, then releases it to exercise pool reuse on the third.
The production WGC callback is still not integrated, crop correctness has not
been executed here, and this source change is not a performance result.


## Owned capture bridge executed

Added SharedCapture: three owned shared-texture slots, optional validated crop,
D3D11 GPU copy from callback-borrowed source, shared fence, and explicit Snapshot
lease. A slot can be reused only when no external Snapshot owner remains and
producer work has completed. Downstream users must retain Snapshot through GPU
completion, not merely its texture COM pointer. Full pool returns busy locally.

Windows Release build and synthetic execution passed on both Intel adapters.
Three distinct 6144x3456 patterns per adapter were copied from an ordinary
non-shared D3D11 texture through SharedCapture and ExternalCopy to private RAM;
all 84,934,656 bytes per frame matched. The first Snapshot was retained across
second capture and was not selected for overwrite. Device checks remained S_OK.
Raw output: d12-shared-capture-6k-windows.log. Cropped and full-pool paths were not
exercised in this run. Real WGC callback integration and IVSHMEM remain pending.

## Explicit actual Desktop Duplication direct-import probe

`d12_desktop_copy_probe.cpp` is a separate opt-in executable, linked with d3d11,
d3d12 and dxgi. Example (only after inspecting adapter/output enumeration):

```bat
viewflow_d12_desktop_copy_probe --capture-output 0 0 --log desktop-copy.log
```

Without --capture-output it exits without capturing. It requests per-monitor-v2
DPI coordinates, acquires one Desktop Duplication frame with a 1000 ms timeout
(no new frame is pending, not a transport failure), and keeps that frame acquired
through all GPU work. It calls CreateSharedHandle on the actual acquired texture
and opens that handle directly in D3D12. An unsupported direct import reports the
real HRESULT and stops; there is no intermediate/shared-clone fallback.

For correctness comparison only, D3D11 copies the same held frame into a staging
reference and signals a shared producer fence. ExternalCopy waits on the imported
fence and copies the directly imported frame into an external private-RAM buffer.
After completion, the reference is mapped and all BGRA image bytes are compared
row-by-row using each side's pitch. Output contains byte count/mismatch count and
API statuses, never pixel values, hashes or a screenshot. The staging copy and
comparison make this a correctness probe, not a latency measurement.

RAII keeps the acquired frame through D3D11 producer drain and D3D12 consumer
drain on all post-submit failure paths, then drops source references and calls
ReleaseFrame. Failed signals retain objects and retry synchronization; device
removal is explicit. It does not open IVSHMEM, change display modes/focus, inject
input or alter windows. Success proves this actual DD texture's direct sharing
and private-RAM GPU copy only; production transport and IVSHMEM remain untested.
Windows Release build and an explicit interactive-session run passed on
2026-10-09. The hidden one-shot scheduled task completed with LastTaskResult=0
and was removed after completion. Output was adapter 0, LUID 00000000:00006ccc,
DISPLAY5, 6144 x 3456 BGRA8. Both CreateSharedHandle(actual DD frame) and
OpenSharedHandle(actual DD frame) returned S_OK. ExternalCopy completed and all
84,934,656 image bytes matched the independent D3D11 staging reference
(mismatches=0). D3D11/D3D12 device checks and ReleaseFrame returned S_OK.
Raw evidence: `d12-desktop-copy-windows.log`.

This verifies direct import of an actual acquired desktop texture and GPU copy
to external private RAM, not actual IVSHMEM, Linux DMA-BUF import, sustained
throughput, latency, or fullscreen route activation. The production services
were not replaced, and no input/focus/display-mode operations were performed.

## Reusable desktop lease and completion event (2026-10-09)

`d12_desktop_capture.hpp` now owns direct DD capture independently of the probe.
It binds by adapter LUID and output device name, retains the acquired frame in a
shared lease, reports pending/busy without closing a session, and recreates the
bound duplication after access loss. Callers must keep the entire lease until
all GPU consumers complete; retaining only the imported COM texture is not enough.
Recovery behavior is source-reviewed but not fault-injection tested.

`ExternalCopy::wait` uses SetEventOnCompletion instead of a fixed 1 ms sleep on
normal completion. Observation timeouts retain pending work and all resources.
Queue Signal failure still retries without abandoning submitted GPU commands.
Windows Release builds passed. The two-adapter synthetic 6K test passed twice
per adapter, clearing the destination between copies, with zero mismatches
(`d12-copy-event-windows.log`). The real desktop probe using the extracted lease
and event wait also compared all 84,934,656 bytes with zero mismatches, successful
device checks and ReleaseFrame (`d12-desktop-lease-windows.log`). Its hidden
scheduled task completed with exit 0 and was removed. These remain private-RAM
correctness tests; no throughput or end-to-end latency result is claimed.

## Submitted copy owns the capture lease (2026-10-09)

ExternalCopy::submit now accepts a source lease in addition to the imported
texture and producer fence. Both DD and shared-capture probes pass their complete
frame/snapshot lease. This prevents DD ReleaseFrame or shared-pool reuse when a
caller drops its own reference while a copy is submitted. Completion/device
removal releases the source COM reference before releasing the lease.

Windows Release builds of both capture probes passed. In the synthetic shared
capture probe, the caller deliberately resets its snapshot immediately after
submit: the remaining owners are the pool and copy, then only the pool after
completion. All three 6144 x 3456 frames on each of the two Intel adapters passed
this ownership check and all 84,934,656-byte comparisons with zero differences;
both device checks were S_OK. Evidence: `d12-source-lease-windows.log`.
The updated DD probe was built but not rerun for this ownership-only change.
Actual IVSHMEM and production transport remain untested.

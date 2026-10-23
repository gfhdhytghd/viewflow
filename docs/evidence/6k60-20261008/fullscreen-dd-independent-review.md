# Independent DD fullscreen review

Read-only review of lease/restore/transport coupling, followed by the root-authorized local rotation and device-loss corrections. No live desktop input, capture test, service change, or deployment.

## Corrected: rotated outputs

The copy-only DD route accepted a 180-degree output because its width/height still matched. It copied the internally rotated image unchanged, causing incorrect orientation and pointer mapping. The bind path now rejects non-identity rotation before moving the window; the acquire path rechecks rotation before submitting any consumer copy. Only that window returns to WGC, with an explicit `copy-only-DD-rotation-unsupported` diagnostic. Identity, unspecified, 90, 180 and 270 enum values have compile-time assertions.

Microsoft's API description explicitly requires clients to correct rotated images: https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api

The bind capability check may return pending safely: DesktopCapture opens duplication and assigns State::output before AcquireNextFrame can return WAIT_TIMEOUT. Thus output_description is initialized when this pending status is returned.

## Corrected: pending device removal

The pending-copy branch previously returned immediately on GetData S_FALSE without checking removal. It now checks GetDeviceRemovedReason first, drains/releases only after device removal establishes the end of GPU access, then requests local WGC fallback. Healthy pending GPU work remains retained without a frame-deadline timeout.

## Lease/restore review

No concrete premature ReleaseFrame or mutex deadlock was found in the current ordinary DD bridge path:

- Pending owns the full DesktopCapture::Frame until the D11 EVENT completes.
- Query failure retains the lease and uses a replacement EVENT, rather than treating failure as completion.
- Source receives an owned D11 slot; Transport.enqueue copies it into its own shared snapshot before asynchronous D12 consumption.
- Slot reuse and that bridge copy are submitted on the same ordered D11 immediate context. A raw slot is not sufficient for enqueue_owned and must not be passed there.
- Failed restore retains ownership/reservation for retry; callbacks stop/join outside the Source lock.

## Remaining technical limitation and future direct adoption

DesktopCapture.acquire currently requires CreateSharedHandle/OpenSharedHandle on each actual DD texture even though FullscreenWindowCapture only uses texture11. This adds per-frame import work and can reject an otherwise usable D11-only capture. A future optional D11-only acquire mode should retain existing direct-D12 behavior by default.

To remove the second bridge copy, FullscreenWindowCapture should copy the DD texture directly into SharedCapture's leased shared pool, retain the DD Frame until that snapshot's producer fence completes, and return the shared snapshot to Source. Transport.enqueue_owned then waits on its producer fence and keeps the pool lease until D12 completes. The pool must bind to the actual Transport D12 device, not the separately created App::fullscreen_device. Busy pool means retain the last snapshot; no CPU fence wait. Original DD bridge remains the fallback.

The unified Windows candidate build is owned by the d12 timing agent; live rotation fallback and actual DD adoption are not validated by this source review.

## Follow-up: optional D11-only acquisition

Implemented `DesktopCapture::FrameAccess::{direct_d12,d11_only}` as a trailing initialization argument, defaulting to direct_d12. FullscreenWindowCapture explicitly selects d11_only. Original direct desktop-copy probe call sites remain unchanged.

Static source inspection verifies that D11-only success skips these per-frame operations on the acquired OS texture:

1. QueryInterface for IDXGIResource1;
2. CreateSharedHandle for the actual DD texture;
3. D12 OpenSharedHandle for that texture;
4. the corresponding per-frame handle close and D12-resource release (neither object is created).

It still acquires/releases the actual DD lease, obtains and validates texture11, copies to the owned D11 slot, and waits for actual producer completion before release. D12 device initialization remains required by the existing API and transport. No SharedCapture refactor of the DD snapshots was performed.

This removes a concrete redundant sharing requirement and API work, but does not demonstrate higher FPS or lower measured latency. Unified main/default-direct-probe compilation is delegated to the d12 timing agent; no desktop probe was run for this change.

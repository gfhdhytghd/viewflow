# Production decoder progressive texture interface

GpuDecoder now exposes begin_progressive(Read lease), poll_progressive(), and
cancel_progressive(). The interface is dormant: normal session still usesSHM1.
CUDA is selected from the current EGL rendering device, as with the existing raw
upload path. Each active upload owns an independent RGBA8 texture with BGRA
sampling swizzles, a registered CUDA resource, pinned host bytes, stream, event,
and the shared-memory reader lease. Each poll copies only newly published rows
using cuMemcpy2DAsync into the corresponding array row offset.

Full publication plus completed unmap/event is required before swapping the
visible decoder texture. Cancellation drains DMA, unmaps, unregisters/unpins,
and releases the reader lease without replacing the existing visible texture.
Ordinary upload cancels an outstanding progressive transaction locally.
No time cutoff or session exit was introduced.

`build/ivshmem-linux/viewflow_progressive_texture_test` passed on the NVIDIA
RTX PRO6000 current EGL device:6144x3456,27prefix polls,84,934,656texture bytes
read back through a GL framebuffer and individually checked with zero mismatches.
No prefix texture became visible. A second frame aborted after a prefix DMA
submission; the previous texture identity and all bytes remained unchanged.
Completed and aborted slots could be reused after lease release.

This test uses local mapped-style storage, not Windows for its producer.
Earlier real-IVSHMEM CPU/CUDA-buffer tests are separate evidence and do not
establish that this GL texture path is integrated across the live session.
No desktop input/focus change, deployment, or service restart in this turn.

Remaining integration: earlySHM2 frame routing and receiver polling; reusing
texture/stream/event and host registrations instead of allocating per frame;
real-Windows cross-VM texture test; full frame-identity latency/fps benchmark.
A passing texture integrity test does not establish performance or photon delay.

## Real Windows IVSHMEM to production GL texture

Added `viewflow_progressive_texture_probe`, using the same standalone Windows
producer and host Mapping as the previous CPU/CUDA-buffer probes. Its consumer
calls the production GpuDecoder progressive interface, not a duplicate upload.
Runs1791505835407540387 and1791505890555214925 passed full84,934,656-byte GL
framebuffer readback against the epoch/offset pattern. Actual control BAR1MiB,
four1GiB banks, slot0. Both normal endpoints were restored by the runner.

The second run enabled VIEWFLOW_PROGRESSIVE_UPLOAD_TRACE:
19upload submissions, setup138.007ms, host pin5.563ms, summed asynchronous-copy
API CPU time0.339ms, final event wait1.068ms, overall432.564ms. These are cold
correctness-fixture timings, with producer pattern generation, deliberate band
pauses, host CPU verification, and1ms polling included.247polls do not mean
247ms GPU fence wait: most polls occurred before complete source publication.
No steady-state bandwidth/latency claim follows. The large cold setup confirms
that persistent context/resource preparation and reuse must precede meaningful
steady-state comparison. No existing source capture or interactive desktop
presentation was part of these probes.

## Resource reuse

Progressive uploads now retain their stream/event and an idle registered spare
texture. Completion swaps the registered texture/resource with the visible raw
texture, rather than unregistering/reallocating every frame. Cancellation drains
DMA and preserves the spare allocation; CUDA errors destroy the spare locally.
Size changes discard only the incompatible spare. Persistent host registration
uses the decoder's bounded four-entry cache and retains the storage mapping,
not the frame lease. The frame lease is released after upload completion/drain.
Storage without a mapping owner still uses per-transaction pin/unpin.

Expanded test covers five further distinct generations, three same-size6K
frames followed by17x13 then6K, checking every resulting byte and retaining the
previous texture until completion. The earlier abort/slot-reuse checks remain.
All passed in `progressive-texture-reuse.log`. Warm same-size setup measured
0.022/0.032ms with pin time rounded0.000ms, versus139.359ms cold initialization.
First spare setup1.430ms. These are local correctness-fixture CPU-wall samples,
not a statistically established latency improvement or end-to-end benchmark.
Fixture generation still contributes to25–27ms total, so that total cannot be
used as production transport latency. No production deployment in this step.

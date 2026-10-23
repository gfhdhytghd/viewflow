# Optional CUDA completion notification

VIEWFLOW_PROGRESSIVE_NOTIFY=1 passes the App nonblocking eventfd to progressive uploads. After graphics unmap and EventRecord, optional dynamically loaded cuLaunchHostFunc writes one eventfd increment. Callback invokes no CUDA API, logging or allocation. Render thread still checks EventQuery; notification never substitutes for completion verification. Original1ms polling remains for prefix progress, unsupported symbol, context errors and scheduling fallback. Busy-poll control remains separate and off.

Pointer lifetime: callback data is decoder Progressive::completion_fd, set before submission and not changed until cancel_progressive synchronizes the stream. Decoder destruction occurs before App closes eventfd. Texture resize cancels old stream before setting new fd. Completed upload cleanup drains the callback before recycling storage. Launch failure retains polling. The public optional-fd contract requires nonblocking eventfd alive through cancellation/destruction.

NVIDIA API documentation: https://docs.nvidia.com/cuda/cuda-driver-api/cuda_driver_api/group__CUDA__EXEC.html ; host function follows preceding work, must not call CUDA APIs, may not execute on context error. These constraints motivate notification-only callback and retained polling.

Linux receiver and texture test built. Hardware test on RTX PRO6000 validated all84934656bytes of6K image, exactly one notification for first complete frame, abort snapshot retention, bank reuse, shared decoder registration, five warm generations and shrink/grow. No desktop input or focus. Live latency benefit not yet tested; normal deployment unchanged.

## Progressive25 live validation

Two-band baseline, host async diagnostics and upload timing, completion notification enabled, busy polling disabled.1519uploads: final-event observed wait median1.178/P952.125ms versus progressive23 polling2.116/2.687ms; upload lifecycle5.618/9.232ms versus6.284/8.859ms. No notification-launch fallback records. Typical completion observation improves similarly to busy polling, but this is not GPU-timestamp evidence or stable whole-pipeline benefit.

1522host markers all match source; both trace queues report0drops,foreground changes0.20interior seconds generated1197,published/accepted1162; every published frame accepted, no active/queued supersessions, source callback-bin counts292/291/289/290 and pool-busy0. Thus remaining throughput deficit is upstream of publication in this run, not dropped host uploads. Still below sustained60fps.

80software feedback samples median42.362/P9554.407/max117.101ms,clock±0.098ms; includes startup, excludes photons.16.7ms unmet. Keep notification defaultoff until repeat and broader lifecycle validation; normal guest/host restored with hash checks, plugin inventory restored. New analyze-progressive-upload.py makes CPU interval analysis reproducible.

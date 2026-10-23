# WGC available-frame queue control

Added default-off VIEWFLOW_WGC_LATEST=1. Each callback obtains initial frame, attempts at most frame_pool_buffers-1 additional nonblocking TryGetNextFrame calls, releases superseded frame and keeps newest complete frame with its own content size and timestamp. No wait for fresh frames and no performance-based session termination. Reports cumulative callbacks/skipped every120 callbacks. Windows Release build and existing WGC contract/window-only checks passed (2/2); these checks do not exercise runtime replacement branch.

physical-pixel-bands-latest1 otherwise uses prior wakepoll control. Observed counters from120 through1440 callbacks ALL skipped=0. Thus no available older/newer frame pair was encountered in the measured interval; latest-frame replacement never fired. This rejects available WGC frame-pool backlog as explanation for this run, but says nothing about hidden compositor scheduling or capture service queues. Do not attribute performance differences to supersession that never happened. Keep default disabled; runtime replacement branch lacks triggered live coverage.

All accept intervals6144x3456, no foreground change, reported trace drops0, exact plugin inventory restored.1547 host markers all match source. Generation-to-callback median20.072ms,P9528.880ms;80 generation-to-sampled-feedback median40.711ms,P9554.530ms,min29.830ms. Accept intervals287–294frames/5s (~57.4–58.6fps),1546unique marker sequences and53gaps. Not continuous60fps, not16.7ms, not photon measurement.

Both native binaries and guest wrapper/probe restored with runner hash checks, Linux receiver active, experimental deadline plugin unloaded. Backup in build/ivshmem-backup/pixel-bands-latest-native.backup. No input/focus operations. Prior README120Hz source trials were inspected: they added load/backlog and encountered VDD hot-restart issues, so no refresh switching repeated here.

Next focus is fixture generation/presentation to WGC delivery timing and host presentation phase, not frame-pool draining or further shorter polling. Original goal remains unmet.

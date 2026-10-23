# Receiver periodic geometry log

Inspection confirms `poll_progressive()` submits every newly observed row prefix,
without waiting for producer completion. The event loop polls pending uploads at
1 ms intervals by default; the existing busy-poll diagnostic is opt-in. No polling
policy changed here.

Found a remaining synchronous `reverse-geometry-timing` fprintf in the rendering
loop. Route this periodic record through existing `vf_diag::trace`, preserving
its fields and cadence. With `VIEWFLOW_ASYNC_TRACE=1`, sink I/O now runs in the
existing bounded diagnostic worker; with the option absent, behavior remains
synchronous. This removes one potential logging stall in instrumented runs, not
the measured WGC capture delay or GPU transfer cost. Sorting and timing collection
are unchanged. No claimed or measured latency gain.

Validation: `cmake --build build/ivshmem-linux --target viewflow_linux_reverse -j 2`
completed successfully. No deployment, GPU benchmark, input injection, or changes
to research jobs. Live performance validation remains outstanding.

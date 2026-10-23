# Host diagnostic I/O isolation

Inspection: renderer uses eglSwapInterval(0), does not wait for a Wayland frame callback before drawing, and flushes the commit before synchronous geometry IPC. This does not establish GPU completion/presentation cost.

Moved existing portable AsyncTrace and diagnostic formatter to reverse-common, retaining Windows include forwarding headers. Linux host frame-stage, fixture marker, sampled presentation and progressive-texture diagnostics now route through vf_diag::trace. VIEWFLOW_ASYNC_TRACE=1 enables bounded background output; unset preserves existing behavior. Timestamps are captured on the producer before enqueue. Queue overflow is explicit and invalidates complete statistics. Error reporting remains synchronous. Shutdown still drains and joins the worker, so this removes active-path sink writes rather than providing a bounded shutdown guarantee.

Existing queue test passed on Linux: blocked sink, capacity/overflow, eight-producer integrity/order, drain. Linux receiver build passed. Live overhead benefit and progressive-upload measurements pending; normal deployment unchanged. Next bounded runner should enable VIEWFLOW_ASYNC_TRACE=1 and VIEWFLOW_PROGRESSIVE_UPLOAD_TRACE=1 on host, check host as well as guest trace drops, and correlate upload timings without treating diagnostic wall times as GPU timestamps.

## Cross-platform build closure

Synchronized reverse-common async_trace/diagnostics and Windows forwarding headers to experimental guest source tree. Current Windows reverse Release target rebuilt successfully from common-header layout; normal installed build-banks binary untouched. Windows viewflow_async_trace_test rebuilt/run successfully after migration, matching Linux blocked-sink/overflow/concurrent-producer/drain coverage. No codec optimization or transport configuration change. This closes the portability build gap; does not establish additional latency benefit.

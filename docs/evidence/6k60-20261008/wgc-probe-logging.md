# WGC optional probe logging

The bounded latest-frame drain and dirty-region probe still called fprintf under
the frame-delivery mutex. Route their three diagnostic outputs through the shared
bounded asynchronous logger. With VIEWFLOW_ASYNC_TRACE=1, sink backpressure no
longer performs stderr I/O in these capture paths. Without that option the prior
synchronous behavior remains. No queue depth, draining policy, capture settings,
or frame selection changes. These optional paths are not asserted to explain
the baseline capture delay, and no latency gain has been measured.

The WGC target treats MSVC getenv deprecation warnings as errors. Scope the
existing shared header's CRT compatibility warning exception around its include;
do not weaken warnings for the rest of the target. The first build exposed this
compatibility issue; the corrected Windows Release WGC library and reverse
executable both built successfully in build-16k. No installation, GPU workload,
desktop input, or research-process changes.

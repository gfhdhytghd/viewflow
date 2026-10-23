# Actual IVSHMEM progressive CPU visibility

Standalone diagnostic built with Linux g++ C++20 O2 and Windows MSVC Release.
Runner: `run-progressive-mapping.py`. Both normal endpoints are stopped for this
probe and restarted in finally; production binaries and configuration unchanged.
No user input, focus changes, plugin reload, or VM reboot.

Run `progressive-mapping-1791505366689842682.log` passed both endpoints (exit0).
Windows mapped the existing 1MiB control BAR and four 1GiB pixel banks through
the real IVSHMEM driver. Linux used existing host files and exclusive reader
flocks. Windows used the exclusive native writer mutex. New negotiation nonces
were agreed before bank use. Experimental headers occupy control1536..2047;
legacy metadata and BankLayout remain unchanged. Only slot0 pixels were used.

One6144x3456 BGRA frame:84,934,656bytes verified individually with an offset- and
epoch-dependent pattern. Windows publishes128-row bands with a1ms diagnostic
delay; Linux observed26partial-prefix advances before full-frame completion.
Zero byte mismatches. The delay ensures prefix observation; these timings are
not throughput or latency measurements. The reader retains its mapping and
lease until verification ends. Negotiation reader teardown acknowledges completion.

This proves CPU byte visibility and early-prefix consumption across this VM's
actual IVSHMEM mapping. It does not prove GPU DMA ordering, visual presentation,
continuous60fps, or <=16.7ms end-to-end latency. Production stays SHM1. Next:
retain progressive reader leases through per-band GPU completion and measure
capture/copy/upload overlap using matching frame identities.

## CUDA device-buffer extension

`progressive_cuda_probe.hpp` adds pinned-host asynchronous HtoD prefix copies,
a retained shared reader lease, stream drain before unpin/release, and whole
GPU-buffer readback. Build the common probe with
`-DVIEWFLOW_PROGRESSIVE_GPU_PROBE -I/opt/cuda/include -lcuda` and select it via
`VIEWFLOW_MAPPING_PROBE=build/ivshmem-linux/progressive-mapping-gpu-probe`.

Authoritative run: `progressive-mapping-1791505570291107015.log`.
27GPU upload submissions;84,934,656GPU readback bytes exactly verified, zero
mismatches. CPU verification also passed. An event recorded after the first
upload reported complete BEFORE a subsequent acquire-load observed a prefix
smaller than the full frame. This ordering verifies early GPU completion while
the producer had not yet published the full frame. An earlier diagnostic
(1791505529838382043) sampled the prefix before querying the event; its early
completion flag alone was insufficient to establish that ordering, superseded
by this run. Initial GPU correctness run1791505490061594330 also passed.

The fixture deliberately pauses1ms between128-row publications. This is a
correctness/overlap capability test, not evidence of production latency savings.
CUDA allocation is a linear device buffer, not yet the production registered
GL texture. Integrating banded CUDA/GL uploads and early SHM2 transport references
remains necessary. Normal Windows task and Linux service restored after runs.

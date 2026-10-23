# Four-bank production candidate, 2026-10-09

Following the user's reboot authorization, Windows shut down normally. The
candidate QEMU keeper and Linux receiver were installed with rollback copies
under `build/ivshmem-backup/dma-four-bank-boot`. No research process was stopped.

The real guest enumerates 69 IVSHMEM devices, all status OK: control and four
1 GiB CPU aliases plus 64 independently managed 64 MiB GPU aliases. All four
memfds initially have zero resident bytes. This now establishes Windows PCI
resource allocation, beyond the earlier paused-QEMU topology check.

The normal source was then upgraded to the candidate Windows binary
SHA256 `6e200daa378436789449b0c398214715e2dace90c237ef8675c1ab600b619835`.
`VIEWFLOW_SHM_D12=1`, staging/banded/progressive capture disabled, selects the
segmented D3D12 path. Linux `VIEWFLOW_RAW_DMABUF=1` selects the external-OES
import, GPU-local snapshot copy, and fence-owned shared-slot retirement.

Passive normal-window observations show a 3840×2299 atlas (3824-pixel content
plus 16 alignment pixels), successful D12 publication with zero fallback/CPU
frames, and actual Linux external-OES selection. Four bank masks are each 1;
all failed masks are zero. Each bank has 64 MiB resident, 256 MiB total, rather
than preallocating 4 GiB. Exact menu/window crop metadata remains unchanged.
The existing atlas shrink hysteresis can retain a prior larger allocation;
128-pixel alignment itself adds at most 127 columns.

Evidence: `segmented-topology-windows-pnp-after-reboot.json`,
`dma-four-bank-boot-residency.json`, `dma-four-bank-live-residency.json`,
`dma-four-bank-live-windows.log`, `dma-four-bank-live-linux.log`.

These are static-window integration and allocation results, not a 6K60
throughput result. Automatic fullscreen Desktop Duplication routing remains
unfinished. The pure 6K synthetic byte-correctness probe does not certify
production presentation latency or photon latency.

## Sustained raw DMA measurement follow-up

`dma-production-motion4` completed the gated 20-second owned fixture run and
restored both normal services. All published frames used D12, with no CPU
fallback. The generator submitted 59.998 fps, while the approximate motion
window had 32.95 WGC captures/s and 31.65 publications/s. These are distinct
from physical presentation FPS. The sampled motion-window WGC-to-Wayland
median was 62.25 ms (p95 345.88 ms, including initial motion transients).
The gate lacked an exact guest QPC in this run; see `analysis.json` for scope.
This does not meet 6K60 or the single-refresh latency goal.

The four banks grew to two 64 MiB segments each (512 MiB total), with the
remaining 3.5 GiB nonresident. Growth is retained for reuse until VM restart;
this is not automatic shrinking. No research task was stopped.

`dma-production-motion5` adds producer/consumer fence observations, but
foreground/geometry changes make it unsuitable as a stable comparison. Its
cleanup script failed due to a PowerShell case-insensitive variable collision;
host recovery verified original-process exit and restored normal service.
The script has been corrected. Fixed candidate binaries remain separate from
the normal Windows binary; double-in-flight and asynchronous host alpha are
not yet validated or enabled in normal service.

## GPU-timed pipeline comparison

Runs `dma-production-motion6` and `dma-production-motion7` use fixed
`viewflow_windows_reverse.dma-gpu-timing.exe` and exact fixture-loop QPC
boundaries. Both restored normal services with native drain confirmed.

| Run | In flight | WGC captures/s | Publications/s | Host accepts/s | Sampled WGC-to-Wayland median |
|---|---:|---:|---:|---:|---:|
| motion6 | 1 | 49.75 | 31.25 | 31.20 | 63.61 ms |
| motion7 | 2 | 40.90 | 40.35 | 40.15 | 87.48 ms |

Motion7 received user button input and a foreground change. It is **not** a
controlled improvement/regression comparison. Neither host accepts nor sampled
feedback establishes a complete displayed-frame rate. All publication remains
GPU DMA with zero CPU fallback. No generation-to-photon claim is made.

Motion6 actual GPU timestamps show about 2.98 ms median owned D11 bridge copy
and 3.67 ms median D12 segmented copy. Their scopes exclude the earlier WGC
source copy and queue scheduling. CPU-observed producer and consumer completion
include those waits; they must not be reported as copy-engine durations.
Reproduce analysis with `tools/analyze-dma-6k60.py --run <run-directory>`.

The current Looking Glass D12 implementation requests a HIGH copy queue:
[upstream D12 source](https://raw.githubusercontent.com/gnif/LookingGlass/master/host/platform/Windows/capture/D12/d12.c).
An optional locally implemented HIGH queue candidate checks support and falls
back to NORMAL; it has been built but not runtime-tested. This is an experiment,
not evidence of improved performance. No GLOBAL_REALTIME priority is used.

# Dynamic forward atlas

Hyprland-to-Windows sessions negotiate a maximum canvas separately from the
initial coded dimensions. `media.width` and `media.height` on the source (and
`width` / `height` on the receiver) specify the initial canvas. Optional
`max_width` and `max_height` specify the shared limit, at most 8192 by 4096.
Omitting these fields retains fixed-capacity operation.

In legacy `occlusion: off` mode the sender grows when a captured window cannot
fit, and existing allocations retain their positions. With the default sparse
mode, growth accounts for source preparation dimensions and visible patch
slots; see [occlusion and transparency](occlusion-and-transparency.md). The sender It releases the unencoded capture leases, completes the
previous transport disposition, prepares the larger encoder, then sends fresh
color and lossless-alpha keyframes with a new layout revision. Per-window input
coordinates remain bound to the exact acknowledged frame. The native receiver
retains each pending frame's own dimensions and layout across the switch.

There is no automatic shrinking during a session. A window that cannot fit even
at the limit is withheld while other fitting windows continue. Sparse mode reclaims covered and off-viewport patches, but neither mode
guarantees space for an unlimited number of overlapping windows.

At 8192 by 4096 a raw alpha plane alone is 32 MiB. The encoded-byte allowance must
cover both color and worst-case exact alpha; a 128 MiB allowance and 256 MiB
decoded/input allowance are used in the desktop configuration. These are limits,
not instructions to allocate or transmit the entire allowance for every frame.

Hardware verification (2026-09-07): an owned empty canvas was encoded on the
Linux NVIDIA GPU at 1024x1024, 4096x4096, then 8192x4096, preserving frame IDs
1, 2, 3 and generating paired keyframes at every transition. The same AV1
access units were submitted to the Windows hardware compositor in a single
process, which returned all three exact output dimensions. This is a correctness
check; it does not establish 8K full-motion frame rate.

The Windows AV1 D3D11VA decoder needs a fresh surface pool on a canvas resize;
retaining the prior decoder could produce a larger decoded geometry backed by
an old small texture. The compositor now rebuilds that decoder on the same
D3D11 device after all pending frames have been composed. The manual
`viewflow_atlas_growth_gpu_test` probe covers this transition without creating
windows or injecting desktop input. Both color and alpha transport allow the
full 16-bit chunk count so an exact 32 MiB alpha plane can fit at the maximum
canvas size, subject to the configured encoded-byte allowance.

Legacy initial enrollment uses the negotiated maximum for its allocation dry run;
otherwise a first window larger than the small initial canvas would be rejected
before reaching the growth path. The dry run does not mutate placements or
allocate GPU resources. Regression cases cover 1566x894, 1722x1422 and 8192x4096
first windows, as well as fixed-capacity configurations and window-count limits.

Sparse enrollment keeps virtual full-window geometry and warms an empty initial
canvas. It never reserves the sum of overlapping window rectangles at startup.

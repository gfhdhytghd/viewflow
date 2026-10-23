# First enabled SHM2 live capture run: failed upload cache integration

Runtime opt-in VIEWFLOW_SHM_PROGRESSIVE=1 now advertises feature2 in addition to
probe feature1. Both sides must intersect feature2 before Windows Readback uses
early references. Probe-only endpoints remain SHM1. Linux checks CUDA/GL device
availability on the rendering thread before advertising support. Negotiation
mixed-capability/lifecycle tests passed Linux and Windows. Source diagnostics
separate profile_shared_announced from profile_shared_completed; host ready and
pixel stamps occur after full upload. Earlier shared_ready timing interpretation
must not be used for early SHM2 announcements.

Run physical-pixel-progressive1 used actual Windows capture and Hyprland path,
no injected input/focus. Guest logged1574announcements and1574completions. Host
logged772recoveries with CUDA 'part or all of the requested memory range is
already mapped'. This is a failed performance validation, not latency/fps proof.

Cause identified in source: each GpuDecoder owns a separate persistent host-pin
cache. Active/spare decoder rotation (and potentially two activity lanes) can
register the same bank already cached by another decoder. Single-decoder texture
tests did not cover this. Next change must share registration ownership across
renderer decoders with PORTABLE registrations, keep mapping and registration
context alive, and retain each pin through asynchronous DMA. Cache eviction or
resize must not unregister another decoder's active DMA. Add a bank-reuse test
with decoder rotation; local fixture currently sends too few completed frames
to force repeated bank reuse. Do not merely ignore already-registered errors.

Restoration completed: host service stopped, guest task stopped, host control
and all four bank flocks acquired, guest viewflow_shared_recovery obtained its
exclusive writer mutex and recovered both protocol states, then original
wrappers/binaries restored. Host SHA256
2e3008638c8f9498668c1921ccca045306ab16bead216e7511ef76c468cf88d2;
guest SHA2567FCDB747CD188AFE12E2CA9CE73C4D51CBA62E21664108B72DE2E299F85D3000.
Both services/task read back active/Running. Cleanup utility requires coordinator
host locks; it must not run beside a live host endpoint. No VM reboot or plugin
reload. Bounded runners preserve unique backups; use a new tag for the next run.

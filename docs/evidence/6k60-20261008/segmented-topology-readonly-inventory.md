# Post-reboot read-only Windows inventory

PnP query found 69 present IVSHMEM devices, all Status OK. Control/full-bank
slots 5..9 each contain function 0; segment slots 10..17 each contain functions
0..7 (64 segment devices). Exact BDFs are archived in
`segmented-topology-windows-pnp-after-reboot.json`.

The existing output probe ran with no capture arguments through one explicitly
hidden interactive-session ScheduledTask (WScript Run window style 0). Task
finished Ready, LastTaskResult 0. Full output is archived in
`segmented-output-task-after-reboot.log`. No sender was started/stopped, no frames
were acquired, and no windows, focus or display modes were changed. Completed
one-time task and VBS launcher were removed; Windows output log remains.

Current adapter 0 Intel Graphics LUID `00000000:00011e17` has attached outputs:

| Output | Rectangle | Dimensions | Rotation |
|---|---|---|---|
| DISPLAY5 | 0,0,6144,3456 | 6144 x 3456 | identity |
| DISPLAY1 | 6144,780,9984,3180 | 3840 x 2400 | 180 degrees |
| DISPLAY6 | 6144,3180,9222,5490 | 3078 x 2310 | identity |

Adapter 1 Intel Graphics LUID `00000000:0001a719` enumerated no output. LUIDs
changed across reboot; use this fresh binding rather than an old enumeration
index/LUID. DISPLAY6 is an independent attached output, but this probe does not
establish its driver type or primary flag. PnP/output enumeration does not prove
all segment mappings are DMA-ready, that GPU transmission was deployed, or that
60 fps / one-frame end-to-end latency is achieved.

# Relative GPU device priority retest, 2026-10-09

User resumed goal and authorized retest. Preflight: normal host service active, motion task Ready3, no fixture process or prior benchmark process. Same experimental binaries and control settings for progressive12(priority0) then progressive13(priority7); neither uses ETW recording. Both explicitly read back requested device priority with all HRESULTs0 and shared_device1. Existing opt-in remains off normally. No keyboard/mouse/focus injected.

Priority0:80software presentation samples median48.730ms,p9569.786ms,max144.737ms;5second accept intervals47.31,43.53,41.25,42.79,42.50fps. One observed foreground change toPID19228; process had already exited on read-only lookup. Origin unknown, not attributed to user. This baseline is confounded.

Priority7:64samples median39.540ms,p9549.701ms,max131.450ms. No observed foreground changes/extent failures/async trace drops. Accept intervals55.01,58.39,57.39,57.70,34.80fps. No continuous60fps proof. End interval may involve workload lifecycle; retained as measured rather than discarded. Sampling is software feedback, not photon timing.

The sequential pair does not establish causal priority benefit due invalid baseline and variable load. Neither result achieves16.7ms or sustained60fps. Do not promote priority7. Current switch accepts explicit0/7, unset untouched; affects shared capture/copy device, not proven to affect internal DWM context.

Both runners exit0; coordinated shared-slot recovery, guest/native/probe/wrapper and host restores succeeded. Both plugin inventories exactly restored; normal host unit active. Backups moved to build/ivshmem-backup. Detailed analyses in gpu-priority-retest.json and per-run files. Next inspect the baseline foreground/lifecycle disturbance and repeated host accept losses before another priority claim.

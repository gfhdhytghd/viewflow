# Shared registration cache fix and live SHM2 rerun

RawUploadCache is shared by all App decoder instances, including active/spare
and activity lanes. Registrations use CU_MEMHOSTREGISTER_PORTABLE. Each entry
retains mapping ownership and an AVBufferRef for the registration CUDA context;
its destructor unregisters in that context before releasing the context owner.
Each asynchronous upload holds its own registration reference until DMA drain.
The four-entry cache evicts only entries with no in-flight borrower. Resize
cannot unregister an active borrower. Synchronous legacy raw uploads use the
same cache. No already-registered error is ignored.

Tests: receiver fixture extended to eight generations, recycling the four
physical slots: completepts1,3,4,5,6,7; abortpts2; unfinished producer exitpts8.
Actual receiver --validate accepts exactly those six complete generations,
no recovery errors. Texture test adds two CUDA contexts sharing a bank and
registration, destroys the first decoder before finalizing the second, then
checks all84,934,656bytes. Existing warm/resize/abort tests pass.

Live physical-pixel-progressive2:1590host pixel markers all match source, zero
mismatch/unmatched. Zero progressive upload recoveries (previous run772).
1601early announcements;1606total completed publications including initialSHM1.
Trace drops0, foreground changes0. Residency initially6016x3456 then6144x3456;
five accept intervals use6144x3456 (293,299,301,300,300frames over~5s each).
Later intervals59.79/59.82fps. Source marker sequences contain5gaps; this does
not certify uninterrupted60fps or every displayed GPU pixel.

80same-identity Wayland feedback samples: generation→feedback median51.579ms,
P9560.614ms, clock envelope±0.090ms. This excludes photons. Same-frame median
partitions: generation→WGC callback19.703ms; callback→early write3.100ms;
early write→host uploaded-ready5.864ms; host accept0.272ms; accept-end→feedback
23.127ms. Do not sum independent medians. Host announced→uploaded-ready across
1587frames median4.859/P956.891ms. Readiness now includes GPU upload, so it is
not directly comparable to the older SHM1 pre-upload ready marker.

This fixes correctness under real decoder rotation, but does not meet the
latency objective. No standalone deadline experiment plugin used in this run.
Remaining dominant waits are capture delivery and compositor presentation;
SHM2 transfer overlap alone does not eliminate either. Next comparison should
isolate actual same-frame transport savings with matched scheduling conditions.

Runners completed coordinated slot recovery and restored original binaries and
wrappers. Host service active; hash2e3008638c8f9498668c1921ccca045306ab16bead216e7511ef76c468cf88d2.
Native backups moved to build/ivshmem-backup. New code remains experimental,
not promoted as the default. No input injection, VM reboot, or plugin reload.

# Live cross-VM negotiation probe

Wired default-off VIEWFLOW_SHM_NEGOTIATION_PROBE into Windows main loop and Linux frame-reader loop. RAII probe creates fresh nonce per endpoint lifetime, polls offer/answer/commit, clears only its own still-current fields on graceful destruction. Critically, this is probe-only: agreement never switches pixel/reference format; logs explicitly say payload=shm1. Ordinary production has no probe nonce or control mutations when env absent.

Linux native and Windows native Release builds passed; Windows existing negotiation tests passed. Additional endpoint-lifecycle cleanup/restart test added afterward and passed on Linux; that additional test has not yet been rebuilt on Windows. It verifies graceful reader replacement and writer destruction, not forced process death.

Bounded physical-pixel-negotiation1 live run confirmed BOTH role=writer agreed=1 and role=reader agreed=1 through the actual IVSHMEM control mapping. All1592host pixel markers matched source. All aggregate accept intervals6144x3456, no foreground or residency disruption flagged, reported trace drops0. This establishes successful cross-VM negotiation alongside ordinary full-frame transport, not SHM2 pixel delivery or crash-restart acceptance.

This run intentionally did not load the deadline experiment plugin; do not compare its53.854ms median generation→Waylandfeedback to prior deadline-enabled runs as a negotiation overhead result. Goal remains unmet; no progressive upload performance evidence yet.

Host/guest native binaries and guest wrapper/probe restored with runner hash checks, runtime override removed, Linux receiver active. Backup in build/ivshmem-backup/pixel-negotiation-native.backup. No plugins loaded/reloaded, no desktop input/focus operation. Next: progressive mapped storage and early-reference lifetime integration, then partial GPU upload with complete-frame-only presentation.

# Async band capture with existing wake/poll controls

Bounded existing-options control, no new capture implementation: VIEWFLOW_SHM_CAPTURE_WAKE=1, VIEWFLOW_SHM_EARLY_POLL=1, VIEWFLOW_SHM_POLL_US=250 added to2-band per-flush, asynchronous serialized logging, paced60Hz pixel fixture and5ms compositor deadline setup. Candidate binary unchanged from asyncserial1. Unique runner/backup/evidence tags retained.

physical-pixel-bands-wakepoll1: all five accept intervals6144x3456, no observed foreground change, no reported dropped trace records, plugin inventories identical after temporary experiment unload.1555 host pixel markers all matched source.1554 unique sequences,one duplicate,47 gaps. Thus marker identity passed, but continuous60unique-frame presentation is not established.

1554 correlated source frames: callback-to-write median6.5546ms,P959.8803ms,max28.6498ms. Publication-construction to first poll median0.5615ms,P951.155ms,max13.085ms, compared with1.996ms median in previous asyncserial run. That earlier run was confounded; comparison indicates expected local timing behavior but is not a matched end-to-end speedup proof. CPU band publication median4.0505ms,P955.006ms,max7.778ms. Faster polling does not remove GPU/copy time and may increase resource contention.

Full6K accept intervals approximately58.1–58.7fps (291–294frames over5.00–5.02s).80 pixel-generation to sampled Wayland-feedback latencies: median38.642ms,P9557.210ms,min26.625ms,max63.220ms. Generation-to-callback median15.643ms,P9526.741ms over1555records. Excludes photon latency. These observations contradict achievement of sustained60fps and16.7ms objective, despite reducing first-poll wait.

Host binary and guest native/wrapper/probe restoration checks passed; receiver active. Standalone plugin unloaded and exact inventory restored. Backup moved to build/ivshmem-backup/pixel-bands-wakepoll-native.backup. No input/focus injection. Controls not promoted to production defaults.

Next optimization must address generation-to-capture delivery and host presentation phase, which dominate remaining end-to-end latency, while measuring copy contention and unique-frame throughput. Do not continue shortening sleeps on the assumption that first-poll savings alone meet the target.

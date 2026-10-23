# Progressive pipeline GPU-to-WGC boundary

Run physical-pixel-progressive8 uses progressive6 shared/prepared CUDA context, 2 readback bands, explicit WGC0, waitable present-zero 60Hz fixture and5ms standalone deadline control. Enabled existing VIEWFLOW_FIXTURE_GPU_TRACE and VIEWFLOW_WGC_DELIVERY_TRACE; no other performance changes. Runner exit0. No input/focus injection.

Fence follows fixture drawing before Present. CPU observer includes scheduling/poll delay, so generation-to-observed time is an upper bound on draw completion; observed-to-WGC is a lower bound on completion-to-WGC. It does not measure final desktop composition or photons.

1796 GPU records, zero pending/dropped.1579 pixel-identity-correlated actual6144x3456 samples span26749.958ms, no non6K exclusions. Generation-to-observed-GPU median2.488ms,p958.067ms; observed-GPU-to-WGC median16.166ms,p9527.940ms,min4.836ms. Generation-to-WGC median20.266ms. This independently confirms substantial delay after fixture GPU drawing completes in the current SHM2 experiment; further optimization of fixture CPU Present or basic draw submission cannot remove this observed wait.

No observed foreground changes or trace drops.1563 host markers all match.26 source sequence gaps.5-second accept intervals:287/5007.043ms,291/5015.693ms,299/5002.021ms,293/5015.213ms,293/5017.407ms; not sustained60fps proof.80 software-feedback samples median40.930ms,p9549.336ms,max59.835ms,clock envelope+/-0.117ms. No photon evidence. Goal unmet.

Coordinated bank recovery, guest wrapper/native/probe and host binary restore succeeded with hash checks. Plugin before/after inventories identical, normal host unit active. Backup stored in build/ivshmem-backup/pixel-progressive8-native.backup.

Next decision: investigate composition/capture delivery mechanisms or a capture path with demonstrably earlier availability while preserving independent-window fusion semantics. Do not substitute monitor capture that loses occluded window content, or tune synthetic generation phase and claim general application latency is fixed. Additional GPU-copy micro-optimizations alone cannot satisfy16.7ms while this measured boundary remains.

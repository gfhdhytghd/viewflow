# Shared CUDA upload context and startup preparation

The receiver now shares one raw-upload CUDA device/context through RawUploadCache across active/spare decoders and activity lanes. Registrations retain device references until DMA completes. With experimental SHM2 enabled, context creation runs before the reader and capability announcement. Preparation failure disables SHM2 advertisement and retains SHM1 fallback. Production experimental defaults remain off.

Build passed for viewflow_linux_reverse and viewflow_progressive_texture_test. The texture test checked all 84,934,656 bytes, five warm generations, shrink/grow, shared decoder registration, and aborted-frame snapshot retention. The actual --validate receiver processed exactly pts 1,3,4,5,6,7 while skipping aborted/incomplete generations; startup preparation took 112.078 ms. This test creates no desktop windows.

Bounded live control: physical-pixel-progressive6, same two capture bands, explicit WGC interval 0, waitable present-zero 60 Hz fixture and standalone 5 ms deadline experiment as progressive5. No input/focus injection. Startup context preparation took 113.691 ms before reader startup.

Results: 1,588 host markers all matched, zero mismatches/unmatched, 5 source sequence gaps. No observed foreground changes or trace drops. Five actual 6144x3456 accept intervals measured 59.040, 59.779, 59.977, 59.027, 60.003 fps. These aggregate intervals do not prove uninterrupted 60 fps presentation.

80 first-commit software presentation samples: generation-to-feedback median 42.879 ms, p95 55.779 ms, maximum 82.504 ms; clock envelope +/-0.110 ms. Same-frame medians: generation-to-callback 20.653 ms, callback-to-host-accept-end 9.952 ms, host-accept-end-to-feedback 8.993 ms. These independent medians must not be added as an exact partition. No photon latency measured.

Previous progressive5 maximum 294.878 ms was an SHM1 cold frame with host accept 150.868 ms. This run maximum is lower, but median/p95 did not improve and one before/after pair cannot establish stable causal benefit. Initialization moved out of frame consumption; initialization still costs startup time. Neither sustained 60 fps nor <=16.7 ms end-to-end is achieved.

Runner exited 0. Coordinated shared-bank recovery ran with both endpoints excluded. Guest wrapper/native/probe and host native restored with hash verification; host service active. Standalone plugin inventory before/after identical. Raw logs and analysis JSON are retained under physical-pixel-progressive6*. Host native backup moved to build/ivshmem-backup/pixel-progressive6-native.backup.

Next bottleneck: generation-to-WGC callback remains larger than one refresh period on the median sampled frame. Further upload-only optimization cannot close the total gap; investigate measured guest composition/capture timing while preserving actual 6K/60 Hz workload and avoiding input injection.

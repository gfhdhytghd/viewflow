# Reverse source main-thread MMCSS experiment

2026-09-09. The native source main thread opts into Playback MMCSS HIGH through the existing helper; failure keeps ordinary scheduling. WGC callbacks and process/task priority are unchanged. The standalone run records registration and priority success, and AvRevert success on normal exit. Full-chain A/B/B/A separately forces direct-source disabled and compares only the MMCSS flag. No installed reverse binary has been changed.

The 36 build-input files are archived under `source/`; local and remote SHA-256 maps agree. Build logs and actual probe status are retained in `method/`.

Standalone source run: 1033 decoded frames with exact opaque alpha, 30.625205 distinct frames/s after warmup; pre-draw to local output median 116.1290 ms, P95 133.3982 ms. This excludes QUIC and Linux live presentation and is not an end-to-end acceptance result. All emitted frames decoded, normal bounded exit, no remaining candidate processes, and installed native hash unchanged.

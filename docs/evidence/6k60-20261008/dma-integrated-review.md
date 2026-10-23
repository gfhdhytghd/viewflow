# Integrated DMA candidate review (2026-10-09)

These changes are built candidates, not deployed performance results. Normal Linux service remains active. No desktop input or focus tests were performed for this review.

- Both C++ wire endpoints accept the desktop-output bit 8192 while rejecting higher unknown bits. Wire regression verifies ordinary frame byte compatibility.
- Linux desktop-output rendering forces opaque alpha in the existing snapshot draw, skips unnecessary alpha extraction for all-DD atlases, and changes input/opaque regions only when the matching color snapshot is installed.
- Windows checks the desktop-output flag against the currently locked source snapshot in both direct and atlas paths. A WGC callback can change the source between layout and copying even at identical dimensions; mismatches now retry while retaining the previous frame.
- The copy-only DD route falls back locally for rotated outputs. Pending DD copies check device removal rather than remaining indefinitely in a pending query state.
- WGC shared-source copies and intermediate bridge copies now carry distinct GPU timing scopes. Offline analysis groups them separately; its backwards-compatible combined metric explicitly covers all roles.
- The controlled runner exposes `--source-pool`, records it, and clears the corresponding guest variable by default.

Windows integrated-v2 MSVC Release build passed. Linux integrated build, wire and fullscreen-backing tests passed; the retained-surface shader tests were run by the Linux implementation agent. Runner Python and guest PowerShell syntax checks passed. No new FPS or latency result is claimed.

Fixed artifacts and SHA256 values are recorded in `build/ivshmem-backup/dma-four-bank-boot/performance-candidates.json`. The source-pool-only Windows artifact predates final desktop-output wire validation; use a matching integrated pair for subsequent fullscreen evaluation. Rust peer deployment with input kind 17 and a reserved non-primary output are also required before enabling fullscreen routing.

## Integrated-v3: D11-only Desktop Duplication acquisition

FullscreenWindowCapture now explicitly initializes DesktopCapture with `FrameAccess::d11_only`; omitted arguments still select `direct_d12`, preserving existing direct-D12 consumers and probes. In D11-only mode the acquired OS-owned DD texture no longer requires an IDXGIResource1 query, NT CreateSharedHandle, or D12 OpenSharedHandle on each frame. Since those objects are not created, their per-frame close/release work is also absent.

DD frame acquisition/release, texture11 format validation, the owned D11 snapshot copy, and its completion lease remain. This changes a concrete redundant API dependency, not a measured throughput result. No DD SharedCapture adoption refactor was included, and no desktop probe or service deployment was performed. The final v3 build and artifact hash are recorded in the candidate manifest after the coordinated build completes.

## Next measurement

Use the same integrated Windows binary with depth 1 and GPU timing for both runs, first with the source pool disabled and then with `--source-pool`. Keep Linux unchanged for that comparison; measure async alpha separately using the fixed Linux candidate. Do not combine source pooling, queue priority, in-flight depth, and receiver changes in the first comparison. Check `profile_d12_adopt`, per-role D11 timings, exact-loop publishing and sampled presentation latency; reject input/geometry-changing runs as controlled comparisons. A 60 Hz fixture submission rate alone is not 60 Hz presentation.

Fullscreen DD is a separate acceptance path requiring a paired peer that accepts kind 17, a correctly sized reserved output, and user-operated fullscreen transitions. Current candidates do not establish that this setup is present or that the transition works live.

Final integrated-v3 MSVC Release build passed for both `viewflow_windows_reverse` (D11-only fullscreen caller) and `viewflow_d12_desktop_copy_probe` (unchanged default direct-D12 caller). The probe was compiled only, not executed. Saved `viewflow_windows_reverse.dma-integrated-v3.exe`, SHA256 `d946a703fabca9c794f4758a9d49a5490e00c678bd01fd0e1a7842b1770d62db`. Normal services and installed binaries were not modified.

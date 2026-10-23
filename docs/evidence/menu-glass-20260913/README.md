# Native menu glass recovery, 2026-09-13

On the live Mac, three ScreenCaptureKit display filters and CGDisplayStream for virtual display 12 returned Sidecar pixels. Both global-rectangle capture APIs returned the correct virtual-screen content. Probe PNGs record that comparison; the full-screen images were taken before the Linux background window was reinstalled on source reconnect.

The native menu region path captures the requested menu and the windows beneath it without moving, hiding or focusing any window. The existing Core Image material extraction preserves the native blur/refraction and restores the independent window's alpha shape. `viewflow-popup-1797-scene.png`, `-material.png`, and `-mask.png` show the native glass recovered versus the independent capture with missing glass.

Initial sequential capture measured roughly 9–13 FPS and capture P95 42–50 ms. Parallel captures improved throughput to about 26–28 FPS but did not meet a 33 ms target. These were diagnostic results, not acceptance claims.

The user then specified that 15 FPS for menus is sufficient, with priority on preserving main-window performance. That version limited all menu capture pairs in each source process to 15/sec total, allows only one pair in flight, shares admission round-robin between parent and child menus, and uses lower-priority worker queues than interactive capture. The main-window capture/encode target remains 60 FPS. Wrong full-display streams are stopped after their mapping is disproved. Menu capture starts before first publication when possible, and optional PNG diagnostics run off the main thread.

The capture-budget regression test passed (rate cap, single in-flight pair, submenu fairness, and menu closure during a pending request). The native helper built with warnings as errors and the installed app passed deep/strict signature verification. Mouse/keyboard tests are user-operated; final main-window smoothness requires live user acceptance and is not inferred from its 60 FPS setting.

The user subsequently raised the menu budget to 30 FPS. The new build uses a shared 30-pair/sec budget with one pair in flight and round-robin submenu admission. The rate-cap test now verifies the 30 FPS interval. Actual throughput remains bounded by native capture completion; this is a ceiling, not a guaranteed delivered frame rate.

# Seam drag and hot-unload recovery, 2026-09-10

Implemented native-window drag observation from the actual Mac cursor feedback,
pinned source bindings (producer process, window address/PID, surface), local
native-drag geometry ownership, and source retention until a native drag ends.
The Linux receiver configuration is prepared for origin (3072, 390), scale 2.
These changes have not completed live deployment/acceptance.

Validation: native plugin CTest 10/10; reverse renderer CTest 2/2 including the
acknowledged-geometry/native-drag regression; Rust native-drag unit test 1/1;
feature-enabled builds of vf-hyprland-windows and vf-cursor-peer; Python viewport
selection test. No real input was synthesized.

At 15:43 EDT, unloading the input plugin crashed the compositor (PID 1782828).
The core shows a call into unmapped code from IHyprRenderer::beginRender during
hymission off-screen rendering. Custom shadow pass objects survived plugin
unload. Cleanup now removes all `Viewflow Mac native shadow` pass objects before
unload, removes decorations and flushes deferred decoration deletion while the
plugin code is still loaded. The cleanup fix compiled successfully and the
replacement plugin is on disk. This fix has not been live-unload tested.

Hyprland watchdog restarted into safe mode, PID 337974. Normal configuration
requires the user's Load configuration action in the recovery dialog. Input
service remains stopped. Stale HEADLESS-158 pinning has been removed; the next
normal start will recreate the Mac viewport. Receiver service environment was
updated to the new compositor instance, but needs restart after normal desktop
configuration is restored. Do not count service-active state as acceptance.

Remaining: confirm normal desktop recovery, load corrected plugin, start input
and window services, verify launched binaries and viewport positions. Mac Input
app Accessibility grant remains user-operated. Continuous Linux-to-Mac held
native drags and the captured-cursor/local-window virtual-input loopback need
further implementation/verification; the overall seamless interaction is not
complete.

Update at 16:45 EDT: unload cleanup was strengthened for hidden/unmapped/fading
windows. The old destructor reproduced SIGSEGV in an isolated compositor. The
full fixed plugin passed 30 queued-pass unload cycles and CTest 10/10, then was
loaded into the current normal desktop (PID 487164). See
[the detailed unload regression](shadow-unload/README.md). Mac Input permission
is intentionally deferred by the user; cross-screen input acceptance remains
pending. The earlier safe-mode state above is historical.

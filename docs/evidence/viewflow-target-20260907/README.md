# Quickshell Apple / Windows input target (2026-09-07)

The installed HyprV button now selects Viewflow's real input route. Previously
its status came from HDMI state and a missing Mac profile silently left Viewflow
on Windows. The button preserves HDMI switching after input startup succeeds.

- UI: `~/.config/HyprV/quickshell/ViewflowTargetControl.qml`.
- Transaction helper: `~/.config/HyprV/quickshell/scripts/viewflow-target.sh`.
- Windows: existing `viewflow-desktop.service`, existing paired desktop source.
  Before reconnect, resume the existing Windows `ViewflowMain-Active` task:
  its receiver is one-shot and exits after the previous source disconnects.
- Mac: `viewflow-macos-input.service`, `~/.config/viewflow/macos-input-source.json`,
  new `vf-cursor-peer`, same native Hyprland cursor channel without video startup.
  macOS `org.viewflow.input-receiver` LaunchAgent uses the already authorized
  viewflowd executable in the GUI session on port 44139. Fresh permanent pairing
  credentials are separate from the deleted live-test keys.
- Only the selected Linux service is enabled at login. Switching stops the old
  source, waits for the new authenticated/native route, then saves the target.
  A failed startup attempts to restore the old service. HDMI errors report that
  input has switched but HDMI has not; the input indicator stays accurate.

The Mac's HDMI display is 1920 x 1200 logical points (3840 x 2400 backing
pixels). Its service sets `VIEWFLOW_CURSOR_OUTPUT_SIZE=1920x1200`; update this setting if the Mac's
logical display resolution changes. Global Linux viewport coordinates are
translated and scaled only for wire positions. Existing Windows coordinates
remain unchanged. Shared-edge return still uses Linux's global geometry.

Validation: native Mac mTLS handshake, accepted clock probes, and acknowledged
Hyprland cursor configuration observed. Stopped Mac service and resumed Windows
receiver/source; accepted Windows clock probes observed again. No mouse or
keyboard input was injected for this switch validation. QML lint and Bash syntax
checks passed; the cursor regression suite includes transformed click-position
ordering. The hermetic helper test covers both directions, startup rollback,
HDMI failure state, and invalid targets without touching real services or HDMI.

The existing Windows video session restarts when its input target is selected;
this change does not implement Mac window/video transport. The final target is
Windows. Prior button files are in `~/.local/state/hyprv/viewflow-button-backup`.

## Follow-up: touchpad scroll and bottom edge

The live Mac receiver logged `kind=touchpad` / `RejectedUnsupportedInput`.
The Linux plugin had suppressed derived finger-axis events while forwarding raw
contacts for Windows, but the Mac Quartz backend does not implement raw contacts.
A backward-compatible optional topology byte now selects derived scrolling for
`vf-cursor-peer`; legacy Windows topology packets retain raw contact forwarding.
After deployment, `capture_status()` returned `raw_touchpad:0`, `connected:1`, and
`remote:[2,3072,390,1920,1200]`. No synthetic user input was posted.

The earlier 1920x1080 value came from the Mac's then-active virtual display;
the HDMI display now reports 1920x1200. Correcting the output mapping removes the
120-point shortfall before Linux's lower adjacent display boundary. The input
plugin reload reset the owned headless output, which was restored to its previous
3840x2400, scale 2, origin 3072x390 layout; the other displays were preserved.

Validation: 17 cursor tests, 2 capture-wire tests, and all 10 plugin CTests pass.
Actual scrolling and edge behavior are left to user-operated verification.

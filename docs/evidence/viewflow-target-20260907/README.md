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

The Mac's currently reported display is 1920 x 1080 logical points. Its service
sets `VIEWFLOW_CURSOR_OUTPUT_SIZE=1920x1080`; update this setting if the Mac's
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

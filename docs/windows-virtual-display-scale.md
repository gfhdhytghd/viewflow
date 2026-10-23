# Windows virtual display startup scaling

`desktop-autostart-linux.py` reads the selected Hyprland monitor's current
`scale` before launching the desktop peer. To apply it to a Windows virtual
screen, add this to the Linux source configuration alongside `peer_discovery`:

```json
"windows_virtual_display": {
  "device": "\\\\.\\DISPLAY6",
  "utility": "C:\\Users\\wilf\\Viewflow\\desktop-test\\viewflow_virtual_display.exe"
}
```

Use the Windows device corresponding to the selected Linux monitor. The virtual
screen must already exist; this option does not install a driver or alter its
resolution/position. The existing utility checks that the target is a virtual
adapter. The host is resolved using the configured peer discovery identity.

At startup, a short-lived scheduled task executes the DPI utility in the same
user's logged-in Windows desktop, because OpenSSH normally runs in Session 0.
The task sets `scale * 100` and requires the utility's successful DPI readback.
It removes its task and temporary results after completion. No keyboard or mouse
input is generated. Windows must have that SSH user logged in interactively.

This sets the effective Windows per-monitor scale, not the Settings UI's
system-calculated “recommended” label. Unsupported factors (for example 1.2)
are reported rather than silently rounded. Failures are logged without stopping
the stream. Changes to Hyprland scale take effect at the next desktop peer start;
this is not continuous live synchronization.

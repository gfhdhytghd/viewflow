# Read-only output inventory attempt before segmented-bank reboot

Executed the existing `viewflow_d12_desktop_output_probe.exe` with no capture
arguments over SSH. The process exited 1; no frame was acquired and no window,
focus, display mode or production source was changed. Log:
`d12-output-inventory-before-segmented-reboot.log`.

The current SSH session enumerated Intel adapter index 0, LUID
`00000000:000100be`, then EnumOutputs returned `0x887a0022`
(DXGI_ERROR_NOT_CURRENTLY_AVAILABLE). This does not establish that no output
exists. Current output names/rectangles/primary and virtual status are unverified;
repeat enumeration in an interactive-session hidden task after reboot.

The earlier interactive-session evidence
`d12-desktop-output-capture-windows.log` records a different adapter LUID
`00000000:00006ccc`, with attached outputs:

| Name | Desktop rectangle | Extent | Rotation enum |
|---|---|---|---|
| DISPLAY5 | 0,0,6144,3456 | 6144 x 3456 | 1 (identity) |
| DISPLAY1 | 6144,780,9984,3180 | 3840 x 2400 | 3 (180 degrees) |
| DISPLAY6 | 6144,3180,9222,5490 | 3078 x 2310 | 1 (identity) |

These are historical observations, not current confirmation. DISPLAY6 was a
separate attached output, but this log does not identify the monitor driver as
virtual or expose the primary flag. Do not infer either from its name alone.
The earlier DD lease probe successfully used DISPLAY5 for a full 6K texture.

For runtime wiring, resolve the current output DeviceName and current adapter
LUID from an interactive enumeration rather than persisting the old LUID/index.
Use DesktopCapture's held-frame lease through segmented DMA completion. Select
only an output whose actual bounds match the intended full-display route, and
keep the existing window/atlas path when bounds, rotation or virtual-output
ownership do not fit. Enabling an output route must not move user windows or
change focus as a test. Primary/virtual output classification needs read-only
EnumDisplayDevices/monitor metadata from that interactive session before claiming
a dedicated non-primary virtual output is available.

# Hyprland decoration for Mac shadows — 2026-09-12

At the user's request, Mac window shadows on Linux now come from Viewflow's
`IHyprWindowDecoration`, using Hyprland's existing shadow renderer. The receiver
no longer allocates, draws or swaps an original-shadow subsurface. The plugin
no longer hooks surface-pass insertion or collects captured tiled shadows.

The native body, titlebar, geometry metadata and input mapping are retained.
The source still transports its full captured extent and alpha; source-side
cropping/encoding bandwidth reduction is not part of this display change.

## Reference and fit

The user prepared a white LibreOffice Writer background in workspace 8.
Hypr-agent-protal captured the same Mac Safari proxy at logical position
(1248,528), size 1209x825, on the 2x DP-4 monitor. Captures use a crop starting
at (1148,428), size 1409x1025. Workspace switching was only for the requested
screenshots; no mouse, keyboard, scrolling or dragging was synthesized.

- `native-reference.png`: original captured shadow over the white background.
- `simulated-first.png`: initial edge fit, before refining corner radii.
- `simulated-final.png`: final Hyprland decoration.
- `fit-shadow.py` and `fit-corners.py`: read-only pixel analysis/fitting.
- `comparison.json`: actual screenshot differences, excluding the entire
  body rectangle so changing webpage content does not enter the metric.

Parameters are logical points and calibrated with current shadow render power 4:

| Lobe | Range | Inset X/Y | Offset Y | Radius | Opacity |
| --- | ---: | --- | ---: | ---: | ---: |
| Broad | 88 | 13 / 14 | 17.5 | 35.5 | 0.233 |
| Ambient | 74 | 0 / 0 | 19 | 27 | 0.107 |
| Contact | 2 | 0 / 0 | 0 | 19 | 0.32 |

The proxy's native body uses a 16-point circular rounding cutout, no Linux
titlebar/border, and no additional built-in shadow. Decoration extents cover
small-window inset clamping as well as the calibrated window.

For visible reference shadow pixels outside the body (reference value <254),
the final mean absolute error is **0.556/255**, RMSE **0.917/255**. The initial
corner RMSE of 2.892/255 fell to **0.602/255**; maximum exterior error fell from
31 to 11 byte values. The final whole-exterior MAE is 0.235/255. This validates
this white-background/window/scale reference, not every Mac application, focus
state or display configuration.

## Validation and application

Linux receiver build and wire/geometry tests passed (2/2). Hyprland plugin
build and tests passed (10/10). The plugin was reloaded and the receiver
restarted at the existing deployed paths. The matching proxy returned at the
same position/size in workspace 8, and live config errors were empty.
Native-titlebar and physical input acceptance remain user-operated.

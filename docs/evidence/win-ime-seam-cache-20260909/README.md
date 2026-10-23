# Seam residency, live display rules, and Windows IME discovery

## Changes and deployment

The Linux atlas source now keeps 256 additional logical pixels resident across
an adjacent display seam for already enrolled windows. `desktop.seam_cache_dip`
can disable this with 0 or increase it up to 1024. Residency changes only the
pixel clipping region; the visible viewport, input coordinates, and enrollment
rules retain their existing meaning. The current remote viewport starts at
logical x=3072; its cached region now starts at x=2816.

The deployed Linux peer is
`/home/wilf/.local/lib/viewflow/desktop/vf-media-peer-main`, SHA-256
`9781b6a2c32f5a835dca6638c6031a898cba3deec0ee68f3ec15fb690e69e289`.
The startup log records the expanded resident rectangle in
`seam-cache-runtime.log`.

During live Word dragging, HEADLESS-13 had reverted to 1920x1080 at (3072,0)
while the active route expected 3840x2400, scale 2, at (3072,390). The reverse
proxy floating rules had also disappeared after a configuration reload. The
rules and monitor geometry were restored and persisted in the active Hyprland
configuration:

- `/home/wilf/.config/HyprV/hypr/hyprland-monitors.lua`
- `/home/wilf/.config/HyprV/hypr/hyprland-winrule.lua`

Both files passed the Lua configuration check; Hyprland reported no config
errors. Readback confirmed the expected display geometry and a floating Word
proxy on DP-4. No mouse, keyboard, focus, or gesture input was generated.

## Microsoft Pinyin candidate window

The user confirmed that candidates display when Word is on Windows but are
missing from its Linux proxy. A held composition had Chinese keyboard layout
`8040804`, open IME status 1, and Word foreground/caret ownership. A screenshot
of the actual Windows virtual display showed the candidate while the Linux
Word capture did not.

The candidate was CoreWindow `0x1041c` in TextInputHost, parent
ApplicationFrameWindow `0x20420` in Explorer. Both were absent from
EnumWindows and EnumDesktopWindows. Enumerating desktop descendants found the
CoreWindow; enumerating the isolated parent did not return that child. See
`ime-discovery.json`. Microsoft's [EnumWindows documentation](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumwindows)
describes its restriction to top-level desktop-app windows on Windows 8 and
later.

The new inventory supplements ordinary top-level discovery with visible IME
descendants and carries their IME classification to the capture target. For a
Microsoft IME CoreWindow hosted by an ApplicationFrameWindow, it captures the
parent. The child returned successful WGC startup but zero frames; the parent
produced a 1272x144 frame. These read-only comparisons are in `ime-probe.log`
and `ime-probe-parent.log`. Other child controls are not independently enrolled.
The existing owner mapping and Linux IME proxy rules keep candidate UI attached
to Word without keyboard focus.

The Windows reverse executable was replaced at
`C:\Users\wilf\Viewflow\desktop-test\viewflow_windows_reverse.exe` with SHA-256
`CBD930EA1113EAC5B16316CFDC6EA38D8993938A9064C7C01ACA8592FBEC89C3`.
`runtime-ime.json` verifies the actual process path/hash and continued native
frame commits. The prior reverse executable was saved as
`viewflow_windows_reverse.before-ime-child.exe`.

## Validation and limits

- Seam-specific tests: 3 passed.
- Desktop configuration/routing tests: 50 passed.
- GPU encoder tests: 17 passed, 1 existing hardware test ignored.
- Windows reverse/WGC CTest suite: 6 passed; final reverse and probe rebuilds succeeded.
- Existing candidate capture: child 0 frames, parent 1 frame at 1272x144.
- Source whitespace checks passed.

User-operated candidate selection, drag return, and mouse crossing acceptance
was requested after deployment. Process activity and captured frames alone do
not establish those interaction results. The extra seam residency covers a
finite drag distance and cannot remove every latency artifact during larger
instantaneous moves.

## Subsequent user result

The user confirmed that IME candidates are now visible. They separately reported Linux Win+drag, fast/slow Word seam returns, and cross-system stacking issues. Follow-up code, deployment, and physical acceptance status are recorded in [the drag/Snap/stacking evidence](../win-drag-snap-stacking-20260910/README.md).

# Windows virtual-monitor wallpaper sync, 2026-09-07

Implemented and deployed the optional static-wallpaper sidecar under
`tools/wallpaper/`. Scope is wallpaper only, without window overlap or background
video. Existing media/input processes were not restarted by this deployment.

Current Linux wallpaper was discovered from the live awww daemon on DP-4:
`/home/wilf/.config/HyprV/backgrounds/v2-background.jpg`. The actual HyprV launcher
uses awww's default centered crop. A 6144×3456 PNG was prepared for the matching
Windows reverse monitor rectangle `[-6144,-780,0,2676]`, obtained from the current
receiver configuration. The image is 33,896,831 bytes; subsequent unchanged polls
do not upload images.

The Windows COM helper was compiled with Add-Type and ran in interactive session
1 under the `ViewflowWallpaper` scheduled task. It verified the image SHA-256,
dimensions, target wallpaper readback, and unchanged wallpaper paths on other
monitors. The captured [receipt](windows-linux-wallpaper-20260907.json) records
SHA-256 `e5fcdfdff929f3ddfcf92b73cc8c57c45f1aa63fc35393d87a8f5490a046a1a7`.

Initial live testing found PowerShell cannot directly invoke methods on the
IUnknown COM RCW. Calls now stay in typed C# wrappers. Atomic manifest/receipt
replacement also stays in C# so null backup paths are passed as CLR null rather
than PowerShell string coercions. Repeated manifest publication after a sidecar
restart succeeded with the same hash and a verified Windows receipt.

Validation: four Python tests passed for monitor/path parsing, centered crop,
unchanged-image suppression and publication order, and PowerShell path quoting.
Python compilation passed. Both Linux `viewflow-wallpaper` and `viewflow-desktop`
services are active; Windows task state is Running (267009 / 0x41301). Logs
confirmed multiple unchanged polls without reupload, and one upload on restart.

No mouse/keyboard injection or focus change was used. This proves wallpaper
synchronization and assignment, not that a specific application's Mica/Acrylic
has refreshed or that WGC includes the final backdrop. That visual check remains
user-operated. Installation, configuration, limitations and restoration are in
[`tools/wallpaper/README.md`](../../tools/wallpaper/README.md).

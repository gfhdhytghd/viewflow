# Static wallpaper synchronization

This optional sidecar copies the Linux monitor's static wallpaper to the Windows
virtual monitor used by the reverse window source. It does not capture windows,
inject input, change focus, restart media, or reconstruct overlapping windows.

Linux queries the running `awww`/`swww` daemon every three seconds. It hashes the
source file (including replacements at the same path), prepares a monitor-sized
PNG, and uploads only on a source/configuration change or sidecar startup.
After startup the worker only checks the remote task/receipt every 30 seconds.
The Windows worker applies wallpaper in the interactive user's session with
`IDesktopWallpaper::SetWallpaper(monitorID, path)` and reads it back. Existing
SSH authentication is used; no additional listener or credential is created.
Transfers and retries run independently of the media and input paths.

Requirements: Python 3, Pillow, OpenSSH, systemd user services, awww or swww;
Windows PowerShell 5.1, a logged-in Windows user, and task registration rights
for that user. No native media rebuild is required: the Windows COM adapter is
compiled by Add-Type. Install from the repository:

```sh
python3 tools/wallpaper/install.py \
  --host USER@WINDOWS_HOST --monitor DP-4 \
  --receiver-config 'C:\Users\USER\Viewflow\desktop-test\receive.json' \
  --remote-root 'C:\Users\USER\AppData\Local\Viewflow\wallpaper'
```

The installer uses the receiver's four `reverse.args` values as the virtual
monitor rectangle, creates the `ViewflowWallpaper` interactive logon task, and
enables `viewflow-wallpaper.service` alongside `viewflow-desktop.service`.
It updates only its own task/service. Installation and updates do not restart
the media process. Linux settings are in `~/.config/viewflow/wallpaper.json`.

Default rendering matches awww's centered `crop`. `resize` can be `crop`, `fit`,
`stretch`, or `no`; fit/no padding is black. The provider query does not report
custom crop gravity or resize mode, so installations using those need explicit
configuration/support. Current paired monitors have the same pixel dimensions
and aspect ratio. Different aspect ratios are rendered for the target, so they
do not promise pixel-for-pixel correspondence with the source display.
Animated wallpaper is treated as a static frame; this is not a video stream.

The generated image exactly matches the virtual monitor size, preserving the
existing Windows wallpaper positioning policy rather than changing it globally.
Windows Span mode cannot use this per-monitor layout and is reported as an
unsupported wallpaper layout; streaming continues. The original target wallpaper
is saved once in `backup.json`. An applied receipt includes its monitor ID,
rectangle, image hash, interactive session ID, and whether other monitors kept
their previous wallpaper paths. `error.json` contains a retryable failure.
The receipt proves wallpaper assignment, not successful Acrylic/Mica capture.

```sh
journalctl --user -u viewflow-wallpaper.service
cat ~/.cache/viewflow/wallpaper/receipt.json
python3 -m unittest discover -s tools/wallpaper -p 'test_*.py'
```

To stop synchronization, disable the Linux sidecar and Windows task:

```sh
systemctl --user disable --now viewflow-wallpaper.service
```

In Windows PowerShell, stop and disable `ViewflowWallpaper`. To restore its
original target wallpaper, run the helper with `-Restore` in the interactive
session after stopping the task:

```powershell
Stop-ScheduledTask -TaskName ViewflowWallpaper
Disable-ScheduledTask -TaskName ViewflowWallpaper
& "$env:LOCALAPPDATA\Viewflow\wallpaper\windows.ps1" -Restore
```

Wallpaper remains assigned on an ordinary disconnect; the next connection or
login continues synchronization. Old content-addressed PNGs are retained for
diagnosis and can be removed when no longer referenced by the request, receipt,
or original-wallpaper backup.

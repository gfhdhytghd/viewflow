# Manual desktop-drag test launch

## Prepared WindowsVM trial (2026-09-06)

The current machine pair has release binaries and seven-day certificates
prepared on 2026-09-06. See [current checks and limitations](project-status.md)
before starting; the previous handoff's uncompiled-source warning is historical.
This is a manual trial, not a completed physical-desktop acceptance.
The application remains on Linux; Windows displays its proxy. Windows-native
applications are not captured by this launcher.

1. On the WindowsVM desktop, double-click
   `C:\Users\wilf\Viewflow\desktop-test\start-windows.cmd`.
2. On Linux, run:

   ```sh
   bash /home/wilf/data/viewflow/build/desktop/start-linux.sh
   ```

3. After the launcher says it is waiting for a crossing, drag a **floating**
   Linux window across the right edge of DP-4 within logical y=822..1590. The first crossing starts the
   capture session. On its Windows proxy, hold **Win** and left-drag to move that
   same Linux window. Drag toward the left edge until its bounds cross the
   shared boundary, then release to place it back inside the Linux viewport.
   Additional visible Linux windows crossing into the output can join the
   same atlas, up to eight enrolled windows in this session.
4. Stop with Ctrl+C in the Windows console and:

   ```sh
   bash /home/wilf/data/viewflow/build/desktop/stop-linux.sh
   ```

This trial uses an intentionally bounded 1536×1152 physical viewport at 1.5× scale at Windows
desktop (0,0), mapped to Linux logical (3072,822). It is **not** a claim that the
Windows monitor was detected at that resolution. The launcher checks the
viewport fits the actual Windows desktop. The encoder atlas is independently
2048×1536; initially try a modest-sized floating window. The source template is
`/home/wilf/.local/state/viewflow/desktop-test-20260906-coordinates/send.json`.
Existing displays/plugins are not taken over. Stop retains the effective
policy and logs in the printed `.stopped.*` directory for troubleshooting.
Normal drag End keeps the chosen placement. Cancel and orderly shutdown of an
active drag attempt checked restoration of its drag-start state. Closing an
enrolled source or losing its capture can terminate the current session;
automatic window removal/replacement and reconnect remain unfinished. Use
`stop` before starting a new session. Do not treat a successful build as proof
that these manual interaction cases passed.

## General preparation

The desktop-drag tools are intentionally explicit, one-session tools. Nothing
runs at login or changes the main desktop persistently. Running `prepare` reads
monitor state and creates local files only; only `start` creates a temporary
headless output or loads a plugin.

## Build the two Linux plugins and source executable

```sh
cargo build --locked -p viewflowd --bin vf-media-peer --features native-gpu-nvenc
cmake -S platform/viewflow-capture -B build/desktop/capture
cmake --build build/desktop/capture --parallel
cmake -S platform/hyprland-plugin -B build/desktop/input
cmake --build build/desktop/input --parallel
install -D -m 0755 target/debug/vf-media-peer build/desktop/vf-media-peer
```

There are exactly two plugins in this workflow:

- `viewflow-capture.so` supplies the one-shot metadata/capture probe;
- `viewflow-hyprland.so` supplies metadata, edge input, and native window
  control together.

The launcher refuses a plugin path containing `hyprcapture`, does not load a
second plugin with the same registered Hyprland name, and never unloads an
independently loaded Hyprcapture instance.

## Generate a paired policy and fresh TLS identities

Use the selected Linux monitor's real output name. Supply the intended Windows
physical viewport yourself: a noninteractive SSH session can report a
synthetic display and is not evidence of the desktop a user will see.

```sh
tools/desktop-drag-pair.sh prepare \
  --dir /absolute/private/viewflow-desktop-pair \
  --monitor DP-4 --linux-ip LINUX_LAN_IP \
  --windows-host WINDOWS_TLS_DNS_NAME --windows-ip WINDOWS_LAN_IP \
  --windows-resolution 1024x768 --windows-scale 1 --windows-position 3072x0 \
  --native-x 0 --native-y 0 --atlas-width 4096 --atlas-height 4096
```

`prepare` reads `hyprctl -j monitors all` and the current compositor PID. It
creates a new `0700` directory containing `send.json`, `receive.json`, a fresh
seven-day CA, and Linux/Windows leaf identities. Private keys are `0600`.
It rejects an existing pair directory or overlapping display rectangles. The atlas is separate from the displayed Windows
viewport: it defaults to 4096×4096 with a 256 MiB decoded budget, so a full
decorated high-DPI Linux window can fit before it is clipped to the selected
Windows physical viewport. It does not copy credentials or binaries to Windows.

The remote monitor uses the explicit `--windows-position XxY` origin. Its
physical resolution divided by `--windows-scale` gives its logical extent.
The source `desktop.remote_display` and receiver `desktop.display` must match.
The optional receiver `native_x` / `native_y` select a physical origin within
the Windows desktop. See [coordinate-based display configuration](display-layout.md)
for left, upper, negative-coordinate and fractional-scale examples.

Before a separate, explicit provisioning step, make the read-only Windows
target check:

```sh
tools/desktop-drag-pair.sh inspect-windows --host WINDOWS_SSH_HOST
```

It checks exactly `C:\Users\wilf\Viewflow\desktop-test` and makes no remote
change. When provisioning has been explicitly approved, stage these generated
files there with the names referenced in `receive.json`: `receiver.pem`,
`receiver.key`, and `pair-ca.pem`, along with `vf-media-peer.exe` and
`viewflow_windows_composition_preview.exe`. Do not reuse identities from an
older pair directory.

## Start the receiver from a real Windows desktop session

Copy `receive.json` to the verified staging directory and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\desktop-drag-windows.ps1 -Config C:\Users\wilf\Viewflow\desktop-test\receive.json
```

The Windows launcher requires paths under that exact staging root, verifies the
configured physical viewport is contained by a monitor in the current desktop
session, and then runs only `vf-media-peer.exe receive --config …`. It does
not inject input or alter display settings. The native gesture on a displayed
proxy is **Win + left-drag**.

## Start Linux and choose the test window

Start the receiver first. Then either name one Hyprland window address, or
omit `--window` and move exactly one window into the newly created Viewflow
output while the launcher waits:

```sh
tools/desktop-drag-linux.sh start \
  --config /absolute/private/viewflow-desktop-pair/send.json \
  --monitor DP-4 --window 0x0123456789abcdef \
  --peer /absolute/path/build/desktop/vf-media-peer \
  --capture-plugin /absolute/path/build/desktop/capture/viewflow-capture.so \
  --input-plugin /absolute/path/build/desktop/input/viewflow-hyprland.so
```

For the crossing path, omit `--window` (use `--crossing-timeout 30` to bound
the wait). `start` first verifies the generated monitor policy and that the
documented default metadata socket
`$XDG_RUNTIME_DIR/viewflow/hyprland.sock` is unused. It creates one fresh
headless output at the configured global coordinates using `hyprctl output create
headless` plus `hyprctl eval 'hl.monitor(...)'`; it does not use `keyword`.
The output displays the dedicated `special:viewflow` workspace over an empty,
named `viewflow-underlay`, so it does not claim a numbered workspace from the
user's ordinary workspace strip. (Hyprland requires every monitor to retain a
base workspace even while a special workspace is displayed.) The
launcher binds the special workspace through the target monitor object without
moving keyboard focus, and verifies the binding again after plugin-triggered
configuration reloads.

The capture plugin must be loaded for the one-shot probe, so it is the only
plugin loaded before selection. `vf-media-peer probe --compositor-pid …
--window …` then validates the live address/PID/stable ID and observes actual
capture dimensions/geometry. Only after that succeeds does the launcher create
its private effective configuration, seed the candidate/window authorization,
run `vf-media-peer validate-send --config …`, load the input/native-control
plugin, and start the sender. The probe stops its one-shot stream and does not
encode or submit a frame. The Windows launcher likewise runs
`validate-receive` before it listens.

Two local sockets have different roles. `desktop.hyprland_socket` is the
current Hyprland **command** socket
`$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`, used for
authenticated local window-control requests. `pointer.native_socket` is the
Viewflow **metadata/input** seqpacket endpoint
`$XDG_RUNTIME_DIR/viewflow/hyprland.sock`. The plugin reads the latter from
`VIEWFLOW_HYPRLAND_SOCKET` when Hyprland itself starts. The launcher therefore
uses only that documented default and rejects a pre-existing Viewflow
socket/daemon; it never attempts a late environment override.

## Stop and acceptance boundary

Stop with the state directory printed by `start` (the default is
`$XDG_RUNTIME_DIR/viewflow/desktop-drag`):

```sh
tools/desktop-drag-linux.sh stop
```

It sends `TERM` only to the recorded source process after a PID-reuse check,
removes only the recorded headless output, and unloads only plugins loaded by
the wrapper. It then archives the exact private session directory beside the
default state path, preserving `source.log`, the probe JSON, and effective
policy while allowing the next start. It does not kill a pre-existing daemon,
alter physical outputs, or unload Hyprcapture. If the source does not exit, it
retains state and does not escalate to `KILL`.

Builds, generated JSON, a temporary output, and source startup are setup
evidence—not test acceptance. A complete manual run still needs the selected
window to appear on the configured physical Windows viewport, a successful
Win + left-drag return, and confirmation that `stop` restored only owned
resources.

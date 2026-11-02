# Viewflow output workspaces and window recall

## Cause

The old workspace activation code replaced the named normal workspace with the
lowest unused **numbered** workspace. It therefore allocated workspace 7 for the
Mac output. It migrated windows only when the previous workspace had one exact
legacy name. A numbered workspace containing Steam/KSP was left behind.
Additionally, `hl.dsp.window.move({...})()` is invalid on Lua fork e5a03b6a5:
dispatcher objects require `hl.dispatch(action)`. Recall excluded tiled and
fullscreen windows and checked only whether their centre overlapped *any* DRM
screen. A scrolling tile on HEADLESS could therefore evade recall even when its
coordinates overlapped the physical desktop.

The Dock flashing has a separate source failure. Capture intentionally omits
HCGI (native Wayland input geometry) for XWayland. The Linux source required HCGI
and exited with `capture omitted native window binding`. The reverse bridge then
recreated the source/presenter every 500 ms. The task's additional live evidence
reported approximately 430 cycles per Steam/KSP window. This report was supplied
by the user; this task did not read live logs or reproduce that device behaviour.

## Design and migration

- Each route uses `name:viewflow-<route>-underlay` plus
  `special:viewflow-<route>`. The primary legacy route uses
  `name:viewflow-underlay` plus `special:viewflow`.
- The named normal workspace is persistent and monitor-bound because Hyprland
  requires a normal workspace for each monitor. No lowest-unused-number scan or
  numbered allocation remains in Viewflow's workspace controller.
- Activation snapshots the old normal workspace's windows, selects the named
  underlay, activates the special workspace, and moves the snapshot into it with
  `follow=false`. This covers old numbered sessions, legacy named sessions and
  windows stranded on an already-correct underlay. Windows stay on the remote
  output; physical workspaces are not selected during migration.
- Shell and Python launchers share the same Lua generator. It uses
  `hl.dispatch(action)` when available, with a callable-action fallback for older
  Lua lines. Both forms have offline Lua coverage. The current Lua fork has real
  nested coverage; release/main runtime coverage is not claimed.
- Both supervisors reconcile once per loop (normally one second), even when the
  special workspace is already active. Toggle/reload/reset/reconnect therefore
  restores visibility and drains any underlay windows. A reconciliation failure
  is logged and retried without terminating the peer. This interval is recovery
  cadence, not a frame deadline or authorization boundary.
- Ordinary drag/move routing uses the active special workspace. The reconciler
  repairs underlay routing fallbacks. Nested tests exercise an explicit move into
  the underlay, not physical mouse dragging.
- New Mac window enrollment uses the visible special workspace instead of its
  hidden normal underlay. Existing source ownership survives temporary hidden,
  unmapped or out-of-viewport states; no stream is retired just for invisibility.
- An explicit numbered-workspace move by the user is not globally prohibited by
  a workspace rule. While the output remains Viewflow-owned, reconciliation
  migrates its active normal workspace contents into the special workspace.
  Normal numbered selection on a physical monitor remains available. No global
  Super+N bindings or physical workspace rules are changed.

## Recall and shortcut

Recall considers every mapped non-proxy window, including tiled/fullscreen
windows. A non-DRM workspace owner, an inactive/covered workspace, or a centre
outside its **own** physical monitor makes the window eligible. Coordinates on
another physical screen no longer override workspace membership. Without a DRM
destination recall reports `No physical display` and moves nothing.

The destination is the active normal workspace on the most recently observed
physical monitor, falling back to the first DRM monitor. Pointer observations
and ordinary key interactions update this record. Recalled fullscreen windows
leave fullscreen; recalled tiles become floating before placement. This ensures
a scrolling layout cannot immediately put them off-screen again. Unaffected
windows and layouts retain their state. The existing focus restoration rule
remains: only the previously focused recalled window receives focus restoration.
ViewflowReverse-/viewflow-remote- proxies remain excluded.

Linux does not require a `~/.config` bind for Ctrl+Alt+Shift+H. The loaded input
plugin observes physical keyboard events and starts with this default chord.
The GUI applies saved settings through `hl.plugin.viewflow.set_recall_shortcut`
and reads back `hl.plugin.viewflow.recall_shortcut`. The paired-session supervisor
also reads back/logs the active chord after plugin load and on subsequent loops.
Queries use `hyprctl repl`: on this fork `eval` executes the Lua but returns `ok`,
not the Lua return value. This also fixes the GUI's obsolete `viewflow.*` namespace.

## XWayland media and recovery

HCGI is now optional in the Linux source snapshot. If present, its window/PID
identity is still checked. If absent, capture, encoding, native geometry,
keyframes, residency feedback, and geometry acknowledgements continue normally.
No fake Wayland surface binding is published. Binding availability is logged on
transitions. A previously published binding is removed if it disappears.

The existing `viewflow-linux-window-input` helper supplies the best existing X11
path: virtual pointer/keyboard plus compositor geometry/fullscreen/focus/close
operations. Its Lua guard validates the current address, PID and stable ID.
Pointer translation uses HCGF geometry. Without HCGI, resize translation uses the
captured outer rectangle because no separate content rectangle is available.
Exact X11 decoration offsets and actual remote input remain manual checks.
A missing/failing input helper retains media and its existing retry path.

Two bounded retry paths prevent rapid restart cycles after genuine failures:

- The reverse bridge delays retries by 1, 2, 4, 8, 16, then 30 seconds, capped at
  30 seconds. A direction that ran for at least 60 seconds resets its delay.
  Stop/connection changes interrupt the wait. Other directions stay connected.
- The Linux window-share supervisor retains identity ownership for a failed
  child and delays its retries by 2, 4, 8, 16, then 30 seconds. A healthy child
  clears failure history after 60 seconds. Temporary visibility loss does not
  lose that identity during retry.

The missing-HCGI failure no longer restarts a healthy XWayland stream. A genuine
native process exit can still recreate a presenter after backoff; this patch does
not claim to preserve an AppKit process after it exits. No speculative Dock
activation-policy change is included.

## Verification (2026-11-01)

Artifacts are under `/tmp/vf-headlessws`. All compositor mutations targeted a
newly spawned nested instance with an isolated runtime/config/cache. Before each
IPC call the harness checks that the lock PID matches its owned child. No IPC to the user's live
session, focus/input injection, plugin unload, service restart, install, or Mac action
was performed.

| Check | Result and scope |
| --- | --- |
| Desktop app unittest discovery | PASS: 89 tests, 2 intentional skips |
| `tools/tests` offline Python scripts | PASS: 13 existing scripts; workspace Lua and sharing/backoff tests rerun after changes |
| Shell launcher hermetic test | PASS: `bash tools/tests/desktop-drag-launchers-test.sh` |
| Recall policy CMake/ctest | PASS: 1/1 |
| Hyprland plugin CMake build/ctest | PASS: 12/12 |
| Rust Linux GPU source tests | PASS: 3/3; native-feature tests include 500 missing-HCGI snapshots and coordinate translation |
| Rust reverse bridge tests | PASS: 5/5 selected tests |
| Nested production plugin | PASS: two tiled clients migrate from ws7; special-toggle recovery; underlay drain; config reload; ws7 reusable locally; no-DRM recall rejection |
| Nested recall fixture | PASS: two tiles on underlay/special recall to the local workspace, become floating, and retain focus |

The plugin build initially stopped on the existing
`window_keyboard_state_test.cpp` `-Werror=maybe-uninitialized` warning. Reconfigure
used `-DCMAKE_CXX_FLAGS=-Wno-error=maybe-uninitialized`; all plugin tests then
passed. No unrelated test source was modified. A first Rust build attempt reused
another checkout's target and hit its CMake source-path mismatch; the successful
build uses the isolated `/tmp/vf-headlessws/cargo` target instead.

### Reproduce

```sh
cd platform/desktop-app
QT_QPA_PLATFORM=offscreen /tmp/viewflow-hid-ui-venv/bin/python -m unittest discover -p 'test_*.py'
cd ../..
python3 tools/tests/desktop-autostart-config-test.py
python3 tools/tests/macos-window-share-test.py
bash tools/tests/desktop-drag-launchers-test.sh
cmake -S platform/window-recall -B /tmp/vf-headlessws/recall
cmake --build /tmp/vf-headlessws/recall
ctest --test-dir /tmp/vf-headlessws/recall --output-on-failure
PKG_CONFIG_PATH=/var/cache/hyprpm/wilf/headersRoot/share/pkgconfig cmake -S platform/hyprland-plugin -B /tmp/vf-headlessws/plugin -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS=-Wno-error=maybe-uninitialized
cmake --build /tmp/vf-headlessws/plugin -j 4
ctest --test-dir /tmp/vf-headlessws/plugin --output-on-failure
CARGO_TARGET_DIR=/tmp/vf-headlessws/cargo cargo test -p viewflowd --bin vf-hyprland-windows --features native-gpu-nvenc
CARGO_TARGET_DIR=/tmp/vf-headlessws/cargo cargo test -p viewflowd --lib reverse_bridge --features native-gpu-nvenc
c++ -std=c++23 -shared -fPIC tools/tests/nested-headless-formats.cpp -o /tmp/vf-headlessws/formats.so $(pkg-config --cflags aquamarine pixman-1 libdrm)
python3 tools/tests/output-workspace-nested.py --hyprland /home/wilf/.local/lib/hyprland-hdr/Hyprland --input-plugin /tmp/vf-headlessws/plugin/viewflow-hyprland.so --headless-format-preload /tmp/vf-headlessws/formats.so --artifacts /tmp/vf-headlessws/nested-production
```

The nested compositor has no physical DRM output. For recall integration only,
a **separate scratch copy** of the plugin changed the single physical-backend
predicate from `AQ_BACKEND_DRM` to `AQ_BACKEND_WAYLAND`. Build that scratch copy
with the adjacent `window-recall`, `reverse-common`, and `hyprland-compat` folders;
run the harness with its path and `--wayland-physical-fixture`. This exercises real
compositor window moves with a simulated physical destination. It does not prove
physical DRM selection. Never install this fixture. The headless format preload
is likewise a nested-only GPU allocation fixture.

## Unverified and manual checklist

No live deployment is part of this task. Actual Steam/KSP capture, NVENC streaming
to the Mac, Dock behaviour, physical keyboard recall, physical dragging, and
physical monitor history remain unverified. macOS code is unchanged. Current
release/main compositor runtime compatibility remains unverified.

After a separately authorized deployment, the user can:

1. Inspect the output: its normal workspace is named and its special workspace
   is `viewflow-<route>`. Confirm numbered workspaces remain selectable locally.
2. Move Steam and KSP onto the Mac display. Confirm both show without Dock
   flashing or repeated helper exit messages.
3. Toggle the special workspace, reconnect, and reload the authorized config.
   Confirm the special workspace returns and retains both windows.
4. Move a window to the underlay. Confirm reconciliation moves it into the
   visible special workspace within the next supervisor loop.
5. Use each physical monitor, then press Ctrl+Alt+Shift+H. Confirm remote/hidden
   tiles return to the most recently used physical monitor. Confirm proxy windows
   remain untouched and focus follows the existing recall rule.
6. Verify X11 pointer/key input and titlebar resize. Check decoration alignment.
7. If a genuine helper failure occurs, check capped retry delays and continued
   service of unrelated windows/directions. Confirm no rapid Dock recreation.

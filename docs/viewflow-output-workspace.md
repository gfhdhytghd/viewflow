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
leave fullscreen; recalled tiles become floating before placement. For windows
whose floating state Viewflow owns, the float-only policy below restores their
original tiled state after departure. Other recalled windows retain the recall
controller's floating placement. Unaffected
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
physical monitor history remain unverified. macOS code was unchanged in the
original headlessws patch; the float-only follow-up below changes its codec. Current
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


## Float-only follow-up and encoder recovery (2026-11-01)

The supplied observation came from an older installed bundle. This change was
implemented and tested in the `floatonly` checkout, without inspecting or
mutating the live compositor, installing a bundle, restarting a service, or
accessing the Mac during the initial Linux-only phase. The isolated Mac checks
recorded below completed that native validation. The older verification table
above records the earlier headlessws work; the results below apply to this
follow-up.

### Floating ownership and geometry

`hl.plugin.viewflow.float_output(output, special, underlay)` registers the exact
route with the input plugin. Both launchers already use the shared Lua generator,
which now calls this API before workspace migration. Matching requires both the
registered output and either registered workspace; no global class, numbered
workspace, or physical-monitor floating rule is installed.

The plugin handles window open, workspace assignment, floating changes, config
reload, output layout changes and workspace migration events. One compositor
idle callback coalesces each batch after the layout completes its operation.
It does not poll. Repeated registration is idempotent. The existing supervisor
still reactivates/drains the output on reconnect or config reload. The plugin
snapshots the window list before changing floating state because raising a
floating window changes the compositor's list order.

A mapped tile on either workspace becomes floating. A later tile toggle is
reversed at the next compositor idle callback. The plugin records weak window
identities only when it changed a tile to floating. On departure it restores
those windows to tiled. Windows that were already floating stay floating on
departure. Close removes the old identity; address reuse cannot inherit it.
Ownership survives ordinary config reload and session reconnect while the
plugin remains loaded. Plugin unload/replacement does not persist that in-memory
ownership across modules; this task neither unloads nor replaces live plugins.

Before forcing float, the plugin snapshots the visible rectangle. It keeps that
rectangle if it fits the output's logical work area (monitor bounds minus
reserved areas). Otherwise it clamps size and position to that area, including
the window decoration extents. It applies this geometry after enabling float,
so Hyprland's remembered oversized floating geometry does not become the result.
The compatibility adapter is in `platform/hyprland-compat/float_geometry.hpp`.
Lua actions continue to use `hl.dispatch(action)` on the Lua fork.

Fullscreen and maximized modes are not prohibited or cleared. Hyprland retains
the floating layout state underneath either mode. The nested test verifies both
modes survive reconciliation and return to floating on exit. The existing native
fullscreen/input records and proxy fullscreen flag are unchanged. AppKit proxy
fullscreen itself remains a manual cross-device check.

### Encoder limits and coordinate mapping

`platform/reverse-common/encoder_extent.hpp` fits a coded color extent to a
backend ceiling with one aspect-preserving scale and even dimensions. Integer
rounding can change either edge by less than two pixels. Conservative ceilings
are 4096 x 4096 for H.264 and 8192 x 8192 for the already selected HEVC/AV1 codec.
This patch does not switch codecs or claim new negotiation support.

Only **coded color** is reduced. The capture/atlas canvas, full-resolution alpha,
tile rectangles, geometry acknowledgements, residency rectangles and input
coordinates remain unchanged. Receivers reconstruct color over that original
canvas: Linux samples normalized textures; VideoToolbox scales its decoded
pixel buffer; the Windows compositor samples its Y/UV textures or uses its video
processor before compositing the original alpha. This avoids rounding tile
boundaries and changing drag/input coordinates when an atlas is reduced.

Affected paths:

- CUDA DMA-BUF NVENC, including `vf-hyprland-windows` and GPU desktop/atlas streams:
  RGBA-to-NV12 conversion samples the original canvas into the smaller coded
  surface. The full-canvas alpha comparison uses its own original-size grid.
- CPU-input NVENC: color staging is reduced. Oversized legacy paired alpha uses
  full-size software lossless H.264; externally transported alpha is unchanged.
- VA-API color, through both CPU and DMA-BUF entry points: device surface
  constraints reduce the ceiling. If pool/encoder initialization rejects an
  extent, local initialization retries a smaller extent before returning a
  genuine resource/codec failure. Capture geometry stays unchanged.
- VideoToolbox window/atlas sources: color uses a scaled pixel buffer. A failed
  session preparation retries smaller dimensions locally and remembers that
  codec's reduced ceiling for subsequent frames.
- Windows Media Foundation and oneVPL sources: D3D11 video processing takes the
  original capture extent as input and the fitted codec extent as output.

Canvas/protocol resource bounds are unchanged (including existing 8192-dimension
and pixel-count checks where present). This is recovery for encoder limits
inside those admitted canvases, not a new larger-canvas protocol. Reduced color
requires a receiver containing the corresponding reconstruction changes; older
receivers that require exact decoded/canvas dimensions must be upgraded together.

`vf-hyprland-windows` now catches encoder creation failure after releasing its
capture lease. It retains the source process and connection and retries after
1, 2, 4, 8, 16, then 30 seconds. Successful creation clears this local delay.
The reverse-direction supervisor uses the same tested backoff policy for native
exits, retains unrelated directions, and clears its delay after a healthy minute.
Its wait remains interruptible by stop/disconnect. Identical repeated failures
therefore cannot create a 500 ms restart loop. No performance deadline becomes
a session-exit condition.

### Follow-up verification

Artifacts and isolated builds are under `/tmp/vf-floatonly`; command logs use
`/tmp/vf-float-*.log`. The nested harness checks its child PID and isolated IPC
socket before every compositor command. All GPU tests use generated pixels,
not desktop capture. No mouse/keyboard injection or explicit focus dispatch was
used. Native Windows checks were not executed because this Linux environment has no
Windows SDK. Mac compilation/testing runs only in
`/Volumes/MoveDATA/viewflow-wifi-test/codex-floatonly/`. The Ethernet SSH endpoint
uses `HostKeyAlias=10.42.0.125` to verify the existing known host key. The native
build and all 33 CTest checks passed on arm64 macOS 27.2 (2026-11-02 UTC).

| Check | Result and scope |
| --- | --- |
| Lua-fork plugin build and CTest | PASS: 14/14, including float fitting and shared work-area/echo policy |
| System Hyprland 0.57 plugin build and CTest | PASS: 14/14; runtime on main/release unverified |
| Nested Lua-fork production plugin | PASS: tile migration, map, retile reversal, departure restores tiling, original user float preserved, fullscreen/maximize, underlay drain, config reload, no-DRM recall, numbered local workspace |
| Linux media CTest | PASS: 10/10, including extent fitting and existing native DMA-BUF integration |
| Oversized NVENC DMA-BUF, 4512 x 1032 and 1032 x 4512 | PASS: coded color 4096 x 936 and 936 x 4096; persistent IDR/P/P/IDR sequence; color/VUI software decode; full-canvas alpha and last-edge alpha cache invalidation; no restart |
| CPU-input oversized NVENC smoke | PASS: persistent paired color/alpha; full-size alpha matches software decode exactly |
| Linux reverse build and CTest | PASS: 17/17; normalized reduced-color presentation on a real peer unverified |
| Rust native Linux source tests | PASS: 3/3; existing input geometry and missing-HCGI checks |
| Rust retry/backoff test | PASS: 500 identical failures retain capped retries; successful recovery resets delay |
| Rust reverse bridge tests | PASS: 6/6, including atomic work-area record relay |
| Shared workspace generator and mocked launcher tests | PASS: Python autostart, Mac viewport selection, hermetic shell launcher |
| VideoToolbox native build/runtime | PASS: native arm64 build and 33/33 CTest checks; H.264/HEVC, oversized H.264 color/full-canvas alpha, async ownership and resize checks |
| Windows MFT/VPL/D3D11 native build/runtime | UNVERIFIED: no Windows SDK/device actions |
| VA-API hardware runtime | UNVERIFIED: available test encoder is NVIDIA; portable backend compilation and extent policy tests passed |

Builds use separate directories for the fork and system headers. The pre-existing
keyboard-test `maybe-uninitialized` warning uses the same
`-Wno-error=maybe-uninitialized` build workaround as the earlier report. The new
geometry/extent tests keep assertions enabled in release builds.

Reproduce the new checks (from the repository root):

```sh
PKG_CONFIG_PATH=/var/cache/hyprpm/wilf/headersRoot/share/pkgconfig cmake -S platform/hyprland-plugin -B /tmp/vf-floatonly/plugin -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS=-Wno-error=maybe-uninitialized
cmake --build /tmp/vf-floatonly/plugin -j 4
ctest --test-dir /tmp/vf-floatonly/plugin --output-on-failure
cmake -S platform/hyprland-plugin -B /tmp/vf-floatonly/plugin-main -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS=-Wno-error=maybe-uninitialized
cmake --build /tmp/vf-floatonly/plugin-main -j 4
ctest --test-dir /tmp/vf-floatonly/plugin-main --output-on-failure
cmake -S platform/linux-media -B /tmp/vf-floatonly/media -DBUILD_TESTING=ON -DVIEWFLOW_ENABLE_CUDA=ON
cmake --build /tmp/vf-floatonly/media -j 4
ctest --test-dir /tmp/vf-floatonly/media/encoder --output-on-failure
LD_LIBRARY_PATH=/tmp/vf-floatonly/media/encoder /tmp/vf-floatonly/media/encoder/viewflow-gpu-dmabuf-encoder-integration-test --oversized
LD_LIBRARY_PATH=/tmp/vf-floatonly/media/encoder /tmp/vf-floatonly/media/encoder/viewflow-gpu-dmabuf-encoder-integration-test --oversized-tall
/tmp/vf-floatonly/media/encoder/viewflow-nvenc-encoder-smoke --oversized
cmake -S platform/linux-reverse -B /tmp/vf-floatonly/reverse
cmake --build /tmp/vf-floatonly/reverse -j 4
ctest --test-dir /tmp/vf-floatonly/reverse --output-on-failure
CARGO_TARGET_DIR=/tmp/vf-floatonly/cargo cargo test -p viewflowd --bin vf-hyprland-windows --features native-gpu-nvenc
CARGO_TARGET_DIR=/tmp/vf-floatonly/cargo cargo test -p viewflowd --lib recovery_backoff --features native-gpu-nvenc
CARGO_TARGET_DIR=/tmp/vf-floatonly/cargo cargo test -p viewflowd --lib reverse_bridge --features native-gpu-nvenc
python3 tools/tests/output-workspace-nested.py --hyprland /home/wilf/.local/lib/hyprland-hdr/Hyprland --input-plugin /tmp/vf-floatonly/plugin/viewflow-hyprland.so --headless-format-preload /tmp/vf-headlessws/formats.so --artifacts /tmp/vf-floatonly/nested
```

The preload is the earlier nested-only allocation fixture described above; it
is not installed or used by the live compositor.

### Follow-up manual checklist

After a separately authorized coordinated deployment, the user can:

1. Open a tiled application directly on the Viewflow special workspace. Move a
   tile there by dispatcher, physical cross-output drag and Super+drag. Confirm
   it floats and its complete rectangle fits the logical work area.
2. Toggle that window to tiled. Confirm it re-floats. Move it back to a normal
   workspace and confirm its original tiled state returns. Repeat with an
   originally floating window and confirm it remains floating.
3. Repeat through the named underlay, reconnect and config reload. Confirm other
   outputs and numbered workspaces retain their layout. Test oversized remembered
   float geometry and output scale/reserved-panel changes.
4. Enter/exit app fullscreen, app maximize and macOS proxy fullscreen. Confirm
   geometry, resize, key/button release and unrelated windows remain functional.
5. Stream an admitted canvas wider/taller than the selected codec ceiling in
   both directions and in desktop/atlas mode. Confirm reduced color covers the
   entire original canvas, transparent edges align, and pointer/resize/drag and
   residency use the original coordinates.
6. Run native Mac codec self-tests and Windows encoder/presentation probes.
   Repeat on a VA-API device with smaller driver limits. Inspect encoder-size
   logs and confirm continuous frames across supported size changes.
7. Trigger a genuine repeated encoder initialization failure in a controlled
   test environment. Confirm capped retries retain the connection, input helper
   and unrelated windows/directions. Restore the resource and confirm recovery.


## Mac visible work area and constrained geometry (third item)

The Mac presenter reports each non-parking display's `NSScreen.frame`,
`visibleFrame`, and `safeAreaInsets`. The reserved edges are the maximum of
visible-frame exclusion and safe-area exclusion, in top/right/bottom/left order.
Coordinates use the existing presenter origin, scale and top-left source-pixel
plane. No menu-bar or Dock size is guessed. Dock magnification/preferences
changes trigger a refreshed snapshot even when AppKit's visible frame remains
unchanged. Transient empty/disconnected screen rectangles are omitted until the
next valid snapshot rather than ending the stream.

The presenter observes `NSApplicationDidChangeScreenParametersNotification` and
Dock preference notifications on its main queue. A 500 ms common-mode timer also
compares screen geometry and the Dock, global menu-bar, and Control Center
preference-file versions. This catches OS changes without a delivered
notification, including while AppKit runs a native drag loop. The timer reads
preferences; it never writes them. Queue backpressure retains the previous
published state so the next callback retries the update.

`viewflow/1+activity/1+workarea/1` is the new optional ALPN. New endpoints still
offer the previous activity and base ALPN values. Only the new ALPN exchanges
one work-area capability byte in the reverse-direction handshake. The Linux source must advertise `workarea-source-v1` and the Mac presenter must
advertise `workarea-presenter-v1`; otherwise reporting stays disabled. The Mac
source role does not advertise an applier capability.
Old activity/base peers receive no new negotiation bytes or work-area records.
The transport test negotiates new/new and both directions of each old protocol.
No separate socket, pairing secret, or authentication rule is added.

A work-area record has tag 7, version 1, revision, count and a reserved-zero word,
followed by at most 16 display entries. Each entry contains a stable display ID
and eight finite doubles: source-pixel x/y/width/height and top/right/bottom/left
insets. Each snapshot is atomic in the existing reliable input direction. An
empty snapshot removes the peer's reservation. Input records remain 40 bytes;
the Linux source consumes this separate snapshot type before its input helper.
The activity relay also preserves these snapshots.

The Linux source passes the snapshot and capture scale to the plugin's
`workarea(window, snapshot)` entry point. The plugin matches the source-pixel
screen rectangle to that window's registered Viewflow output. It scales edges
to the output's logical dimensions. Physical outputs are never selected by
this API. The most recently received applicable snapshot wins once per output;
stale snapshots from other window streams do not repeatedly reset the edges.

`platform/hyprland-compat/work_area.hpp` applies the native equivalent of
`addreserved`: it updates the monitor's static reserved area and recalculates
its layout. It preserves the configured static base and dynamic layer-shell
reservations. Config reload/output layout events reapply the cached snapshot.
Output teardown/plugin teardown restores the configured static base. This path
builds against both the Lua-fork and system main headers without generating or
rewriting user configuration.

Floating placement uses `logicalBoxMinusReserved()`, as recall placement already
does. Existing floating windows are fitted after an inset change. Remote window
geometry and desktop drag operations request a fit after their ordered move.
Physical drag release requests a fit through an event listener without posting
or cancelling input. Active compositor drags and fullscreen modes keep their
owner; fitting resumes after release/fullscreen exit. Fitting an existing float
uses its geometry goal, because a dispatcher may update that goal before its
current animated rectangle. This prevents an old visible rectangle from masking
an out-of-work-area move during the same compositor turn.

On the Mac, source-driven placement uses AppKit's constraint result for the
intersecting display. Off-display windows are not pulled back from an adjacent
viewport. An AppKit-constrained frame is sent once as authoritative ordinary
geometry. A per-window record remembers the rejected requested frame, actual
frame and work-area revision. Repeated captures/ACKs of that same rejected target
neither reapply it nor send another correction. A new target, local movement or
work-area revision permits a new correction. Accepting the actual source
geometry clears the rejection. Duplicate native notifications do not generate
extra corrections, and a later genuine user move can override a different
source frame even if it returns to an earlier local position.

Superdrag remains proxy-first. The Mac follows the local drag and ignores source
placement during that drag; crossing into an adjacent viewport remains possible.
After release, the work-area fit and authoritative geometry settle the window.
No focus dispatch or synthetic mouse/key test was introduced.

### Third-item verification and manual acceptance

| Check | Result and scope |
| --- | --- |
| Shared C++ work-area policy | PASS: scaled/negative-origin mapping, visible/safe insets, preference/visible-frame change detection and 10,000 repeated rejected-frame checks without a second correction |
| Nested fork plugin | PASS: real monitor reserved edges, float clamping, explicit remote-geometry fit, reload reapplication, then a Dock auto-hide-style zero-inset update |
| Rust snapshot decoder | PASS: finite geometry, revision updates, malformed/truncated record rejection |
| Rust reverse relay | PASS: an atomic snapshot reaches the native source in both relay directions, including the distinct source-event parser |
| Paired QUIC ALPN loopback | PASS: new/new, legacy/new, new/legacy, activity-only/new and new/activity-only; mutual TLS identity remains present |
| Linux input helper | PASS: build and 2/2 tests; no input was injected |
| Native Mac build and tests | PASS: isolated arm64 build on macOS 27.2, initial selected tests 7/7, full CTest 33/33; no code fixes required |
| Native Mac Rust peer | PASS: `vf-window-peer` build and QUIC compatibility test covering five new/old ALPN combinations |
| Actual Dock/menu-bar/notch changes and proxy jitter | UNVERIFIED: no preference changes or physical interaction; native initial-screen snapshot and policy tests passed, but do not prove interactive jitter acceptance |

The source bundle used for isolated verification is `/tmp/vf-floatonly/macos-source.tar.gz`, with
its adjacent SHA256 file. It contains only source and an isolated
`verify-mac.sh`. The script uses the requested tools-venv313 and Cargo paths,
places source/build/logs/temp files inside the specified new directory, builds
the Mac native backend, runs work-area/codec/geometry/placement/gesture tests,
and builds the Rust peer. It does not install, launch the normal presenter,
change preferences, inject input, or access `/Applications/Viewflow.app`.
Extracted source, build, temporary files and logs are inside the isolated Mac
directory. `/Applications/Viewflow.app` and the running app were not modified,
installed, relaunched, or signed. No input or focus operations were performed.

The verified native test output includes:

- `PASS Mac work area snapshot displays=1 scale/origin and preference change; no window/input/pref mutation`
- `macos-window codec self-test passed: H264/HEVC, NV12/BGRA color, full-canvas alpha, oversized color, resize, async ownership/order; no capture/input`
- `100% tests passed out of 33`

Logs are in the Mac directory under `logs/`; full native output is also in
`build/Testing/Temporary/LastTest.log`. Read-back copies are under
`/tmp/vf-floatonly/mac-native/` on Linux.

Reproduce with the existing host key and isolated directory:

```sh
cat /tmp/vf-floatonly/macos-source.tar.gz | ssh -o BatchMode=yes -o HostKeyAlias=10.42.0.125 linhaikuo@2604:fa00:130:a69:7:6664:90bc:ef6f 'cd /Volumes/MoveDATA/viewflow-wifi-test/codex-floatonly && tar -xzf - && bash verify-mac.sh'
ssh -o BatchMode=yes -o HostKeyAlias=10.42.0.125 linhaikuo@2604:fa00:130:a69:7:6664:90bc:ef6f 'cd /Volumes/MoveDATA/viewflow-wifi-test/codex-floatonly && export PATH="$PATH:/Volumes/MoveDATA/viewflow-wifi-test/tools-venv313/bin:$HOME/.cargo/bin" && export TMPDIR="$PWD/tmp/" && ctest --test-dir build --output-on-failure'
```

The native `--workarea-self-test` only reads screen/pref state and checks change
detection; it creates no windows or input. The physical checklist after an
independently authorized deployment adds these checks:

1. Move/resize a Linux window against each Mac menu-bar, notch and Dock edge.
   Confirm one final placement and stable source/proxy geometry.
2. Change Dock position, auto-hide and magnification, then menu-bar auto-hide.
   Confirm the corresponding output's reserved edges update without disconnects.
3. Rearrange/add/remove a display. Confirm its output changes independently and
   the old display reservation clears on a snapshot without that display.
4. Superdrag across display boundaries and release at a reserved edge. Confirm
   the proxy follows the pointer first, then settles once; unrelated windows and
   physical Linux outputs retain their geometry and layout.

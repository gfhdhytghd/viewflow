# macOS / Hyprland / Windows window sharing

`vf-window-peer` runs a native window source and a native presenter over the
existing mutually authenticated QUIC transport. One connection carries one
direction of video and the corresponding ordered return input. Either role can
listen. Use a second connection/port for simultaneous sharing in both directions.

| Direction | Source backend | Presenter backend |
| --- | --- | --- |
| macOS → Hyprland | `viewflow-macos-windows source` | `viewflow_linux_reverse` |
| Hyprland → macOS | `vf-hyprland-windows` | `viewflow-macos-windows present` |
| macOS → Windows | `viewflow-macos-windows source --codec h264` | `viewflow-windows-windows` |
| Windows → macOS | `viewflow_windows_reverse` | `viewflow-macos-windows present` |

macOS uses ScreenCaptureKit, VideoToolbox and Core Image/Metal. Color is H.264 or
HEVC Annex B; a separate lossless alpha plane preserves transparency. The Windows
presenter currently accepts H.264. macOS and the Hyprland presenter accept both.
The Hyprland source uses the existing Viewflow DMA-BUF capture plugin and NVENC.
No raw color pixels cross QUIC.

The native Mac backend supports `--performance-mode frame-rate|latency` for
both source and presenter roles. The source admits one color/alpha/encode job
on a dedicated thread; captures continue replacing the latest unsubmitted image
while the main thread processes input. Its output queue holds three pending
records in frame-rate mode and one in latency mode. ScreenCaptureKit retains
three capture buffers in both modes so a replacement can arrive while an older
IOSurface is retained. The presenter permits three Metal commands in frame-rate
mode; latency mode uses one command and two drawables. Only captures or draw
requests that have not started are coalesced. Both modes use hardware-only real-time
VideoToolbox with no frame reordering, a two-second GOP, 24 Mbit/s target rate,
an interactive-QoS capture queue and Metal-compatible IOSurfaces. Unsupported
optional VideoToolbox properties are reported rather than treated as active.
Neither mode expires an accepted frame or closes a session for missing 33 ms.
Use `viewflow-macos-windows --performance-status latency` for a side-effect-free
configuration readback.

Single-window sources retain the captured pixel buffer directly, avoiding an
intermediate atlas render. Metal extracts the original alpha bytes into a shared
buffer while Core Image renders opaque color. The source waits for extraction
completion before CPU compression and reuses its buffers only afterward. Failed
GPU extraction falls back to exact CPU extraction; `VIEWFLOW_MACOS_GPU_ALPHA=0`
selects that fallback for diagnostics. Exact image comparison runs on the capture
worker, and VideoToolbox completion and record packing run on the dedicated encode
thread. VideoToolbox still completes one frame at a time; this is not a claim of
two simultaneous encoder jobs. See the [source pipeline record](evidence/mac-source-pipeline-20260912/README.md)
for stage measurements and deployment evidence.

The window peer is independent of the Linux/Windows desktop-atlas launcher. It
does not replace `vf-media-peer` or create virtual displays. macOS can share up
to 32 selected window IDs; the Hyprland source shares one selected window per
connection. A listening peer serves multiple connections concurrently, so a
window closing or recovering does not block another window. Windows uses its
existing WGC selection inside a configured desktop rectangle.

`tools/macos-window-share-linux.py` discovers visible Linux windows that overlap
the current Mac viewport, including partial crossings from the local display.
It supervises one source connection per window and retires it when the window
leaves the viewport or closes. It reads the active cursor route and compositor
session; it does not move windows or synthesize input. Captured windows retain
their source desktop coordinates. Configure the Mac presenter with the negative
viewport origin and matching scale (currently `--origin-x -3072 --origin-y -390
--scale 2`). The existing cursor/HID connection remains separate. Continuous
held-button drag handoff across both native window managers still needs physical
acceptance; automatic capture is not proof of that input behavior.

The Linux supervisor is installed as `viewflow-macos-windows.service`, attached
to `viewflow-macos-input.service`. The Mac presenter runs in its GUI LaunchAgent
`org.viewflow.window-presenter` on paired QUIC port 44220. Native GPU binaries
are installed separately from Cargo's test outputs because integration tests can
rebuild executable targets without the capture feature. Live setup and evidence:
[Linux to Mac deployment](evidence/linux-macos-window-sharing-20260910/README.md).

## Background blur and buffer reuse

Mac windows presented on Linux crop the atlas to the native body before drawing
the complete body into the Wayland surface. `xdg_surface.set_window_geometry`,
viewport, EGL buffer, configure sizes and bidirectional geometry all use body
units. The Linux presenter draws only the native body. Viewflow's
`IHyprWindowDecoration` uses Hyprland's shadow renderer to approximate the Mac
shadow with two broad lobes and a thin contact edge. It allocates no extra
Wayland shadow surface and needs no per-frame shadow swap or surface-pass hook.
The white-background fit uses the current Hyprland shadow render power of 4;
parameters and screenshot comparison are in the
[shadow calibration record](evidence/mac-hyprland-shadow-20260912/README.md).
Captured framing metadata and the original alpha still cross the wire; this
change does not yet crop shadow padding at the source or reduce encoded extent.
Mac proxies consume input across the body surface and discard letterbox
button-downs locally. Rendering and input share the same aspect-fit rectangle.
Button releases return to the window that received the press, including when a
drag ends outside the body.

On Linux Mac proxies, two-finger touchpad scrolling uses native HID back to
macOS. Three or more fingers remain with the Linux compositor. Adding a third
finger releases the active Mac scroll, and forwarding stays off until all
fingers lift, so the tail of a Linux gesture cannot restart a Mac scroll.
Single-finger pointer motion and clicks continue through Wayland.

IME discovery includes client-owned IME panels: modern macOS can
publish a visible candidate strip under Messages at level 20 while keeping the
inputmethod-owned counterpart off-screen. These panels use the same parent
window association and transient lifecycle as menus, so the candidate strip
joins the corresponding window stream.

The Mac presenter explicitly raises only the clicked proxy. Source focus changes
are carried in tile flag 64 and raise the corresponding proxy on the transition;
unchanged video frames do not repeatedly reorder windows. This does not implement
the Windows presenter's complete cross-process stacking snapshot/owner graph.

Linux full-screen state (excluding maximization) is carried in tile flag 32.
The Mac presenter uses AppKit native full screen with a dedicated Space;
ordinary geometry synchronization pauses during that transition and while full
screen. Exiting native full screen sends input kind 15 back to the Linux window.
The presenter waits for both receipt and matching source state before resuming
remote state changes. Pointer coordinates are mapped through the full-screen
view. This requires the updated Mac helper and Linux input helper together.
Native Space transitions remain user-operated acceptance tests.

The Mac presenter ports the Windows SDR backdrop pipeline to ScreenCaptureKit
and Metal. Per-proxy display captures exclude the proxy and overlapping windows
above it, retaining the real host desktop and lower proxies. Layer changes
update the capture filter in place. Capture and GPU work run on a private queue
at up to 30 Hz; background publications redraw even when remote video is static.

Linux sources publish the current effective Hyprland `decoration:blur` settings:
enabled, size, passes, contrast, brightness, noise, vibrancy, and
vibrancy_darkness. An independent worker polls every 500 ms and attaches the
recipe as H.264 user-data SEI, preserving the existing VFRV framing and decoder
compatibility. The Mac selects the Hyprland Metal kernel when this recipe is
present, updates it without reconnecting, and reblurs retained captures even
when the host background is static. Query failures retain the last valid recipe.
These are kernel settings; Hyprland-specific scene flags such as xray and
ignore_opacity are not reproduced by this alpha-based composition protocol.

For older sources without a recipe, the fallback matches the Windows
host-backdrop Gaussian path: sigma 12 physical
pixels, without an extra Retina/DPI multiplier, contrast, tint, vibrancy, or
noise. Metal Performance Shaders supplies the Gaussian implementation. Both
platforms accept `VIEWFLOW_ATLAS_BLUR_SIGMA=0..64`; zero disables the backdrop.

Windows' optional `VIEWFLOW_ATLAS_BACKGROUND_CACHE=1` selects its custom Hyprland
kernel; the Mac honors the same opt-in for older sources. Its fallback uses prepare, four downsample/four
upsample, and finish passes: radius 5, contrast 0.8916, brightness 1, vibrancy
0.1696, vibrancy darkness 0, and noise 0.0117. Noise coordinates stay anchored to
each physical display. The shared Windows region planner supplies kernel
support (50 pixels for the default Gaussian, 182 for Hyprland) plus at least
128 pixels (or two update periods) of motion reserve.
Old valid pixels remain at their screen position while another region warms;
uncovered pixels retain ordinary transparency rather than stretching stale
background. Each intersected display has its own scale and cache.

Foreground GPU alpha supplies SOURCE_IN coverage for the blurred background,
followed by foreground-over, matching the Windows conservative coverage
`a * (1 - a)`. Clear corners stay clear and faint shadows receive weak coverage.
There is no second CPU-generated backdrop mask or AppKit material/tint. Opaque
and empty tiles skip capture. Scratch textures are recycled only after GPU
completion; published background textures remain immutable for foreground draws.
The wire does not carry a distinct blur mask, so neither presenter can infer
full-strength blur independently of source alpha.

ScreenCaptureKit's replayd client identity requires a distinct executable path
for simultaneous unbundled capture clients. Each presenter executes an isolated
signed helper copy, as source helpers already do. Capture errors and a missing
initial sample retry locally; they do not close the stream or other proxies.
`present --evidence-dir PATH` optionally exports one foreground/background/result
PNG set per proxy for diagnostics. It is off by default.

Alpha reconstruction uses one-channel `L8` data, and source pixel buffers use
CoreVideo pools. Hardware decoders return NV12 IOSurfaces directly to Core Image,
which performs color conversion during composition. Unchanged encoded alpha and
geometry reuse the decoded plane and Core Image mask; crop changes still refresh
the appropriate backdrop. Alpha decompression and
image reconstruction run on the serial input worker before a synchronous AppKit
handoff in common run-loop modes with an explicit wakeup; frame and alpha vectors
are not copied into that handoff. The
`macos-window-render-stats` log counts completed window GPU submissions and
replaced pending draws, not physical scanout or end-to-end latency. The command budget applies across all proxy windows, with fair
pending-window scheduling after GPU completion. Linux window sources also accept
`--performance-mode frame-rate|latency`; the supervisor can select it with its
matching option or `VIEWFLOW_WINDOW_PERFORMANCE_MODE` environment variable.

See the [Mac blur and performance record](evidence/macos-blur-performance-20260910/README.md)
for stage measurements, deployed hashes, reconnect recovery, and remaining visual
acceptance boundaries. The replacement Metal pipeline is documented in the
[Windows backdrop port record](evidence/mac-windows-backdrop-port-20260912/README.md).

## Build

On each peer:

```sh
cargo build --locked -p viewflowd --bin vf-window-peer
```

On macOS with Xcode command-line tools and CMake:

```sh
cmake -S platform/macos -B build/macos -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
cmake --build build/macos
ctest --test-dir build/macos --output-on-failure
```

Single-configuration CMake builds default to Release. For an explicit build, add
`-DCMAKE_BUILD_TYPE=Release`; use `cargo build --release` for deployed peers.

The native binary targets macOS 13+. On macOS 14+, it explicitly captures
unclipped window content without the system shadow, keeps transparency and fits
the configured pixel extent. macOS 13's older ScreenCaptureKit framing and
offscreen behavior still need native acceptance. The receiver needs no Screen
Recording or Accessibility authorization. The source needs Screen Recording;
return input additionally needs Accessibility/event-post authorization for the
actual executable and its launch context. Launch from the logged-in GUI session;
SSH can have a different permission identity. Grant OS permissions manually.

On Hyprland with the Viewflow capture plugin, NVIDIA/CUDA, FFmpeg, Wayland and
xkbcommon development dependencies:

```sh
cargo build --locked -p viewflowd --features native-gpu-nvenc --bin vf-hyprland-windows
cmake -S platform/linux-reverse -B build/window-presenter
cmake --build build/window-presenter
cmake -S platform/linux-window-input -B build/window-input
cmake --build build/window-input
```

`viewflow-linux-window-input` uses the native Wayland virtual keyboard/pointer
and the installed Hyprland 0.56 Lua API. It pins the selected address, PID and
stable window ID; keyboard layout comes from the current seat. It is a supervised
helper, not a program to invoke with arbitrary incoming network commands.

On Windows using the Visual Studio CMake environment:

```powershell
cmake -S platform/windows-window-presenter -B build/window-presenter -A x64
cmake --build build/window-presenter --config Release
cmake -S platform/windows-reverse -B build/window-source -A x64
cmake --build build/window-source --config Release
```

## Pair configuration

Use certificates from the intended device pairing, with the other device's
certificate name in `server_name`. Paths must be absolute. Do not deploy the
repository's test TLS fixtures as production identities.

Example macOS source connecting to a Windows presenter:

```json
{
  "bind": "0.0.0.0:0",
  "remote": "192.0.2.20:44220",
  "server_name": "windows-peer",
  "certificate": "/Users/me/viewflow/pair/mac.pem",
  "private_key": "/Users/me/viewflow/pair/mac.key",
  "certificate_authority": "/Users/me/viewflow/pair/ca.pem",
  "role": "source",
  "backend": {
    "native": "/Users/me/viewflow/build/macos/viewflow-macos-windows",
    "args": ["source", "--window", "12345", "--codec", "h264", "--scale", "1"]
  }
}
```

List native Mac IDs with the **same executable or app bundle** used for capture,
`viewflow-macos-windows --list-windows`, after granting Screen Recording, then
replace `12345`. `--permissions` reports its current OS authorization without
requesting or changing permission. Add another `--window ID` for each selected
window. Closing a selected window withdraws that tile; a new native window needs
a new explicit selection.

Windows presenter configuration:

```json
{
  "bind": "0.0.0.0:44220",
  "certificate": "C:/Users/me/Viewflow/pair/windows.pem",
  "private_key": "C:/Users/me/Viewflow/pair/windows.key",
  "certificate_authority": "C:/Users/me/Viewflow/pair/ca.pem",
  "role": "presenter",
  "backend": {
    "native": "C:/Users/me/Viewflow/build/window-presenter/Release/viewflow-windows-windows.exe",
    "args": ["--scale", "1", "--origin-x", "0", "--origin-y", "0"]
  }
}
```

Validate and run on both devices:

```sh
vf-window-peer validate --config /absolute/path/window-peer.json
vf-window-peer --config /absolute/path/window-peer.json
```

For other directions, change the native backend and arguments:

| Backend | Example `args` |
| --- | --- |
| Mac presenter | `["present", "--scale", "1", "--origin-x", "0", "--origin-y", "0"]` |
| Hyprland presenter | `["0", "0", "1"]` (origin x/y in logical points, source pixels per point) |
| Hyprland source | `["--window", "0x123456", "--compositor-pid", "1234", "--input-native", "/absolute/build/window-input/viewflow-linux-window-input"]` |
| Windows source | `["0", "0", "1920", "1080"]` (left, top, right, bottom of its capture rectangle) |

Obtain the Hyprland address and compositor PID from the intended compositor
session. Omit `--input-native` for view-only Hyprland sharing. The helper starts
only when return input is received. Keep that session's `XDG_RUNTIME_DIR`,
`HYPRLAND_INSTANCE_SIGNATURE` and `WAYLAND_DISPLAY` in the source environment.

Window positions use source desktop coordinates. The presenter's `origin` adds
a local placement offset; `scale` divides source pixels into local points (Mac
and Hyprland) or pixels (Windows). Use scale 2 on the presenter when the Mac source
uses scale 2. Offset negative source coordinates into a visible receiver area.
Mac proxy Command-drag and Windows proxy Alt-drag move the native source window;
the Hyprland proxy retains its existing Super-drag behavior. Normal clicks and
keys operate the remote application.

Mac proxy shortcuts use a native-first fallback: AppKit's menu/responder chain
gets the shortcut first, and an unhandled shortcut is forwarded to the Linux
application. Add repeatable `--linux-shortcut` backend arguments to bypass the
native attempt for selected combinations. Rules are case-insensitive; examples
are `Command+Q` for one exact shortcut and `Ctrl+*` for every chord containing
Control (including Control+Shift chords). Unmodified typing is always forwarded
directly. A native-handled shortcut releases any remote held-key state so its
modifier tail cannot leak into the Linux application.

Append `["--performance-mode", "latency"]` to a backend's arguments for the
bounded low-latency schedule. Omit it, or select `frame-rate`, for the throughput
schedule. The mode changes scheduling only; geometry, codec quality, alpha,
pairing, ordered input and recovery remain unchanged.

## Recovery and verification boundary

Backpressure skips unencoded Mac captures; it does not discard a dependent
encoded P-frame. Native backend failures recover on the same paired connection.
Capture failures on one Mac window retry locally while retaining other tiles.
Geometry acknowledgments report request processing, including unavailable native
operations, so the proxy can return to observed source geometry. Disconnect and
focus loss release held input. A 33 ms miss is a performance observation, never
an authorization check or session-exit condition.

Generated-image tests cover H.264/HEVC encode/decode, alpha reconstruction,
orientation, size changes and end-of-stream draining. QUIC tests cover ordered
return input delayed beyond 33 ms, either TLS role as source, native restart and
EOF cleanup. These tests never inject input or change desktop focus.

Native mouse/keyboard, live ScreenCaptureKit framing, mixed-display scale,
drag/resize and multiwindow application acceptance remain user-operated.
Automatic popup/menu-family enrollment, application audio and IME integration
are not implemented by this window backend. Clipboard
can use the independent [clipboard peer](clipboard-sync.md).

Build and generated-video results: [validation record](evidence/macos-window-sharing-20260907.md).


## Mac source enrollment and three-system preparation

`tools/macos-window-source.py` enrolls visible layer-zero Mac windows from the
native JSON inventory, with one supervised paired connection per window. Its
source template has the normal peer configuration above, without `--window`.
Run it from the Mac GUI login session:

```sh
python3 tools/macos-window-source.py --template /absolute/source-template.json \
  --peer /absolute/vf-window-peer --runtime /absolute/source-runtime
```

`--validate` checks the template without capture. `--max-windows` defaults to 8.
Existing selections survive enumeration reordering; temporary inventory errors
retain established sources. Window ID plus owner PID identifies a selection.
Viewflow bundle IDs and native presenter process names are excluded to prevent
received proxy windows being captured back into a three-device loop. Windows
also excludes its Viewflow proxy window classes; Linux selection must keep its
existing proxy exclusion. Enrollment does not synthesize input or change focus.

Each window transport sends keepalive probes during an unchanged/empty desktop;
normal inactivity therefore does not restart capture every transport idle period.
Actual disconnects still release held input and reconnect normally.

The deployed Windows/Mac link, common three-device pairing preparation, endpoint
scales and remaining Screen Recording requirement are recorded in
[the mesh deployment record](evidence/macos-blur-performance-20260910/window-mesh.md).


### Launch the authorized source app

Use `tools/macos-window-app.py` as the native source backend when capture is
provided by the installed app bundle. It forwards normal native arguments, such
as `source --codec h264 --scale 2`, and also supports `--permissions` and
`--list-windows`. The default app is `~/Applications/Viewflow Window Sharing.app`;
`VIEWFLOW_MACOS_SOURCE_APP` can select a different installation.

This launcher uses background Launch Services activation and bounded FIFO stdio.
Direct execution from SSH or underneath another executable can have a different
macOS permission identity even when the app binary path is identical. Verify
permissions through the launcher used for actual capture. The wrapper preserves
the installed app's signature and does not grant permissions itself.

Real Mac-to-Windows verification after the user's grant is recorded in
[the authorized capture record](evidence/macos-authorized-capture-20260910/README.md).


## Native HID scrolling in Mac proxies

In Mac shadow mode, the Linux presenter reads physical evdev multitouch slots
without an exclusive grab. Two or more fingers are encoded into VFTP ABI 2
reports, retaining contact identity, position, pressure, diameters and orientation.
Size is approximated from the diameters, as in the standalone native forwarder.
Single-finger movement and buttons keep their existing Wayland input path.

Mac proxies enable this capture alongside Windows proxies. The GUI HID server
accepts concurrent ordered streams, so the persistent desktop HID connection
does not block a proxy's two-or-more-finger stream. An idle stream does not
acquire the driver; an all-up frame releases its ownership while keeping the
connection open. Temporary ownership contention retries on the next physical
snapshot, without closing the socket or the window stream. Disconnect releases
only input owned by that producer. Native socket/stream tests use an injected
fake driver and never post OS input (`stream_receiver_test.swift`).

A `touchpad_frame` record with zero dimensions/count and `d=2` requests native
HID capability. Updated Mac sources advertise tile flag `8` only after this
request and while the GUI-owned HID socket is available. Older Mac sources
ignore the request and retain wheel scrolling; Windows presenters receive no
additional flags. Reports use six kind-13 chunks and a kind-14 commit, preserving
the existing 40-byte input payload and the paired, ordered QUIC input lane.
The presenter refreshes the native pointer position before a multiframe gesture.

The Mac source writes reports to the running Viewflow app's `run/hid.sock`.
That app owns the DriverKit connection. Nonblocking writes preserve partial
reports, while socket failure or backlog releases the HID connection and returns
the proxy to wheel fallback without closing its window stream. A socket indicates
host availability, not proof that macOS accepted a gesture. Host exit is detected
and withdraws capability; reconnect attempts recover locally.

Finger-origin Wayland wheel events are suppressed only with both physical
capture and advertised native HID availability. Leaving the proxy, ending the
multifinger gesture or disconnecting releases remote contacts. This window route
does not require enabling desktop cursor capture or the standalone SSH HID
forwarder. Real scrolling and macOS gesture interpretation remain user-operated
acceptance checks.


## Native decoration, HiDPI and demand-driven capture

Mac app destinations named `linux` now request `--native-decorations 1` and a
capture scale of at least 2. The virtual parking display keeps its logical
geometry and advertises a 2x pixel backing with `hiDPI = 1`. The source records
the actual display/content scale from ScreenCaptureKit; configuring a 2x output
alone is not evidence of a HiDPI virtual display.

Tile flag 16 adds the pixel body rectangle, logical body size and coordinate
scale. ScreenCaptureKit's bounding rectangle includes framing: a live Settings
sample reported 786x672 points for a 740x626-point window. The actual body size
comes from `screenRect`; its location is found from paired alpha edges inside
the framing. This handles asymmetric shadows without a fixed inset or an
opaque-only threshold. The full native frame, including its shadow, uses the existing encoded-color
and lossless-alpha transport.

The Linux presenter sets `xdg_surface.set_window_geometry` to the body rectangle
and consumes input within the body surface, including non-forwarded letterbox
areas. Surface allocation and rendering use the body only. Geometry synchronization uses the logical body size,
and scale comes from frame metadata. `ViewflowReverse-MacNative-*` windows retain
native titlebar controls and use only the Viewflow Hyprland shadow decoration.
They do not add a Linux titlebar or border.

Inventory includes separate physical and remote display rectangles. Capture
selection requires overlap with the remote area and excludes windows fully
covered by the union of physical displays, including windows spanning multiple
physical screens. Missing layout metadata retains current selections rather
than pretending all windows closed. The native decorated source also suspends
ScreenCaptureKit when a window returns to the Mac, releases its retained image,
and resumes when it re-enters the remote area. Idle transport is not capture.
The updated main app additionally retires idle window workers, so fully local
windows do not occupy the capture pool.

Deployment and remaining physical acceptance checks:
[native decoration and demand-driven capture](evidence/mac-native-hidpi-demand-20260911/README.md).

### Passive native popup backdrop diagnostic

The signed Viewflow main executable embeds `--menu-backdrop-probe`. Launch it
through Launch Services so capture uses Viewflow's screen-recording permission:

```sh
open -n -g -o /tmp/viewflow-backdrop.log --stderr /tmp/viewflow-backdrop.err \
  /Applications/Viewflow.app --args --menu-backdrop-probe \
  --watch /absolute/background.png /absolute/output-directory
```

`--watch` waits up to 60 seconds for an existing layer-101 menu or small layer-20
panel. The user opens and holds the popup; the diagnostic does not post input or
activate a window. It captures `before-window.png` and `before-display.png`,
places a mouse-transparent background window immediately below the popup, then
captures the corresponding `after-*` images and removes the background window.
The image is stretched across the popup bounds plus a 64-point sampling margin;
this is a material/capture experiment, not a coordinate-correct background feed.
Compare both capture paths before claiming native backdrop support. `--list`
prints visible window IDs and geometry; an explicit window ID replaces `--watch`.

The diagnostic also compares display `includingWindows:[popup]` capture with
independent-window capture, and records display capture excluding the popup as
`*-behind.png`. `*-material.png` combines the native screen color with window
alpha, subtracting the background contribution at antialiased edges. This is a
sequential still-image experiment; it is not enabled in the live source and
cannot establish synchronization or animation quality. Recomposition should be
compared against the original display image before adopting it for streaming.

### Mac window center crossing (2026-09-26)

Mac-origin windows follow display ownership by their center. A remote proxy is
eligible only once the window center is strictly inside a remote viewport and
outside every physical Mac display. Touching the seam, or moving only a corner
across it, does not display a remote proxy. Returning the center to the physical
Mac side withdraws that proxy. The application inventory, native capture scope,
and per-peer destination selection use the same rule. This does not change
Linux-origin partial-window sharing.


## Mac → Linux 平铺点击映射修复（2026-10-30）

### 原因与被动证据

部署目录 `~/.local/lib/viewflow/linux-20261018-keyboard1/` 的
`bundle-manifest.json` 记录 `build.revision=c5a3062169e11b4ad7b7b4d55456eea0b540e19c`，
`build.dirty=true`。该提交日期为 2026-09-22；目录日期不代表完整源码版本。
`keyboard_hotfix.revision=762fcc9c9d1827e3adda9fc07e09a3129b8c411b` 只对应键盘插件。
清单的 provenance 明确记录其他组件复用混合源码构建。因此不能把全部二进制归到
`762fcc9c` 或 `c5a30621` 的干净源码。只读进程列表确认接收器来自该目录，参数为
`viewflow_linux_reverse 3072 299 2`。这些是 Linux 视口原点与缩放，不是 Mac
停车显示器的原点。Mac 的 `window-parking.log` 最后一条记录显示器 17 位于
`-3072,-299`，逻辑大小 `3072x1728`。

工作起点与 `robustness-hardening` HEAD 同为 `02571fde`。该 HEAD 与清单所指
`c5a30621` 都仍有以下路径：Linux 用帧中的旧窗口位置构造桌面绝对坐标，
Mac 收到 `pointer.c=1` 后用当前 `WindowPlacement` 把该坐标映射到停车窗口。
几何请求先更新逻辑位置，画面可以随后到达；旧帧位置与新逻辑位置混用会产生偏移。
按下前没有重新按实际窗口范围定位。Mac 又把鼠标事件送入全局 HID 命中测试，
因此越界坐标会命中桌面，而不是消息指定的应用。修复前还把画面独立拉伸到代理宽高，
没有保留原比例，也没有合并密集平铺几何请求。

Mac 日志 `~/Library/Logs/Viewflow/source-2052-66920-a4834581f2f870e013ee2802762a5160.log`：

- 第 1852 行：`window-geometry-applied window=2052 sequence=1393 requested=-3062.0,478.0,2239.0,825.0 backing=-3062.0,478.0`。
- 第 1911 行：`window-input button window=2052 pid=66920 button=272 down=1 native=-1878.0,-160.5 posted=1`。
- 第 1917 行：相同位置的按钮释放。
- 两段之间反复出现 `window encode recovering: create encoder: -12903`。

点击 y 坐标在最后一次几何记录之外。日志没有逐点击的实际 WindowServer 边界，
也没有「显示桌面」状态，因此它支持偏移路径的判断，但不是桌面动画的实机证明。
编码器恢复失败会延长旧画面停留；本次不改编码器或服务生命周期。

### 修复与决定

- Linux 使用当前保留画面的主体像素，不再用 Mac 的全局桌面位置映射点击。
  Wayland 提供表面内坐标，Hyprland gaps、border 和显示器原点不参与计算。
- Linux 对当前画面等比缩放并居中。绘图、点击范围和可见区域需求共用同一矩形。
  留白区按下在本地丢弃，释放仍返回原来接收按下的窗口。拖动允许超出主体。
- 固定 40 字节输入记录保持不变。`pointer.c=0` 的 `a/b` 是主体像素坐标；
  `d` 的低/高 16 位分别带发送画面的主体宽/高，源端用实际当前窗口大小重建比例。
  `d=0` 保留旧像素坐标语义，`c=1` 仍接受旧桌面坐标。
  旧 Mac 接收端忽略 `d`，不能获得本修复的主体尺寸与目标事件保证；完整验收必须
  同时更新 Linux 接收器和 Mac 源端。没有新增版本握手或拒绝旧连接。
- 几何同步继续使用 Hyprland 主体大小。Mac 几何请求在本地变化停止 100 ms 后发送最新值。
  这只是合并窗口调整，不是输入期限或会话退出条件。全屏期间取消普通几何请求，
  退出后恢复原有几何同步。浮动与平铺转换继续由原来的几何所有权状态控制。
- AX 返回实际最小/最大尺寸时，继续显示实际主体并等比缩放。明确不支持调整大小时，
  确认该次请求并保留实际尺寸，不以每秒 60 次重复请求同一个不支持的操作。
  暂时失败仍保留重试。浮动窗口仍按原有规则同步远端实际尺寸。
- Mac 使用实际窗口边界重建窗口坐标。按下前重新读取边界，避免激活造成窗口移动。
  `NSEvent` 携带窗口 ID 和左下角原点的窗口坐标；对应 Quartz 事件保留全局坐标，
  并携带目标 PID 与两个 window-under-pointer 字段。按钮和滚轮按 PID 投递，
  不再向全局 HID 流发送普通按钮。移动时同步系统光标，供独立原生触控板路径使用。
  Apple 的 [位置说明](https://developer.apple.com/documentation/coregraphics/cgevent/location)
  定义 Quartz 全局坐标；[窗口字段说明](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventwindowundermousepointer)
  列出窗口 ID 字段。具体应用接收行为仍须实机验收。

### 验证范围

- `cargo test --workspace`：通过。
- `cargo clippy --workspace --all-targets -- -D clippy::unwrap_used`：通过；其他现有 lint 警告保留。
- `cd platform/desktop-app && QT_QPA_PLATFORM=offscreen /tmp/viewflow-hid-ui-venv/bin/python -m unittest discover -p "test_*.py"`：76 项，跳过 2 项，通过。
- `cmake -S platform/linux-reverse -B /tmp/viewflow-m2l-build -DCMAKE_BUILD_TYPE=Release` 与
  `cmake --build /tmp/viewflow-m2l-build -j 8`：通过，包含 Linux 接收器。
- `ctest --test-dir /tmp/viewflow-m2l-build --output-on-failure`：17 项通过。
  新增可移植测试覆盖负原点、Retina 主体尺寸、留白区、尺寸变化、受限窗口、全屏比例、
  拖动越界与 100 ms 合并；EGL pbuffer 测试检查缩放位置和留白像素。
- Mac 隔离目录 `/tmp/viewflow-m2l-check`：`xcrun clang++ -std=c++20 -fobjc-arc -Wall -Wextra -Werror -fsyntax-only platform/macos/window_source.mm`
  通过；新可移植测试在 Mac 编译并运行通过。没有构建或替换运行中的 App。
- 未验证：端到端点击、原生触控板、窗口标题栏拖动及各应用的 PID 事件接收。
  调查只读日志和进程状态；没有截图、输入注入、焦点切换或服务重启。

### 用户手工验收清单

由用户在两端更新后的构建上执行：

1. 在浮动 Mac 代理的中心、四角和标题栏点击，确认应用收到对应位置。
2. 切换平铺并调整分割比例；调整期间点击，确认位置随当前画面且不触发「显示桌面」。
3. 用有最小尺寸或不可调整大小的窗口重复测试；点击留白，确认远端没有点击。
4. 切换浮动、平铺、全屏并恢复；改变 Hyprland gaps 和 borders 后重复中心与边缘点击。
5. 拖动标题栏与应用内容，跨越代理边缘后释放；确认拖动结束且按钮没有滞留。
6. 验证双击、右键菜单、滚轮和原生双指手势；覆盖 Settings、Finder 和常用浏览器。
7. 在 scale 2、负停车原点及多显示器之间重复检查；确认其他代理和会话持续工作。

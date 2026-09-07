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

The window peer is independent of the Linux/Windows desktop-atlas launcher. It
does not replace `vf-media-peer`, create virtual displays, or automatically hand
windows across monitor boundaries. macOS can share up to 32 selected window IDs;
the Hyprland source currently shares one selected window per connection. Windows
uses its existing WGC window selection inside a configured desktop rectangle.

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

List native Mac IDs with `viewflow-macos-probe --list-windows` after granting
Screen Recording, then replace `12345`. Add another `--window ID` for each selected
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
Automatic popup/menu-family enrollment, application audio, IME integration and
native touchpad contacts are not implemented by this window backend. Clipboard
can use the independent [clipboard peer](clipboard-sync.md).

Build and generated-video results: [validation record](evidence/macos-window-sharing-20260907.md).

# macOS native backends

Target: macOS 13+, Apple Silicon and Intel. `viewflow-macos-windows` provides
ScreenCaptureKit window capture, VideoToolbox codecs and AppKit/Metal proxy
windows. See [window-sharing setup](../../docs/macos-window-sharing.md) for
macOS ↔ Hyprland/Windows pairing and the remaining manual acceptance boundary.
The daemon now has a Quartz keyboard/mouse receiver; see
[setup and validation](../../deploy/macos/README.md).

```sh
cmake -S platform/macos -B build/macos -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
cmake --build build/macos
ctest --test-dir build/macos --output-on-failure
./build/macos/viewflow-macos-probe
./build/macos/viewflow-macos-probe --list-windows
```

Requires Xcode command-line tools and CMake 3.24+. The default invocation emits
JSON describing current screen-recording/accessibility authorization and the
default Metal device. It does not prompt, capture pixels, activate applications,
or inject input. Window enumeration is optional and reports `permission_required`
when screen-recording access is absent. Grant OS permissions manually in System
Settings when ready, then rerun the tool. Missing accessibility permission does
not prevent enumeration. Titles may be sensitive; review output before sharing.

Exit codes: 0 = report completed (permissions can still be absent), 1 = native
query/output failure, 2 = invalid arguments, 3 = enumeration needs permission,
4 = diagnostic query watchdog expired. The 15-second watchdog bounds this
standalone query only and defines no streaming deadline or security boundary.

`schema_version: 1` identifies this diagnostic JSON, not the network protocol.
Window IDs are native process-session observations, not persistent Viewflow IDs.
`frame_points` is the unmodified ScreenCaptureKit frame (x, y, width, height);
do not treat it as backing pixels or normalized Viewflow topology coordinates.
The probe does not exercise the daemon input backend; use the separate
`viewflowd input-status` command to inspect event-post permission.

## Window sharing

`viewflow-macos-windows source --window ID` publishes selected windows;
`viewflow-macos-windows present` reconstructs native proxies. Run these through
`vf-window-peer` for authenticated QUIC and ordered return input.
`--codec-self-test` checks generated color/alpha pixels and codec resize without
capture, input injection or focus changes. `present --validate` decodes a VFRV
stream without opening windows.

Mixed Retina displays, live capture framing, drag/resize and native input still
require user-operated acceptance. Popup-family enrollment, audio and IME remain
future work; clipboard uses its independent peer.

Follow [the availability policy](../../docs/security-and-availability-policy.md):
33 ms/two refresh periods is a performance target; focus changes, congestion and
recoverable per-window failures must not terminate unrelated windows or sessions.

## Verification boundary

The macOS workflow checks portable Rust and builds universal native binaries.
Native tests cover CLI, Annex B, key mapping and generated pixel/codec round trips.
They require no desktop capture or input permissions and do not establish live
visual or input acceptance. See the [validation record](../../docs/evidence/macos-window-sharing-20260907.md).

API references: [SCShareableContent](https://developer.apple.com/documentation/screencapturekit/scshareablecontent),
[CGPreflightScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()).

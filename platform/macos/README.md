# macOS foundation

Initial native discovery target: macOS 13+, Apple Silicon and Intel. This is a
development baseline, not a claim of a working macOS streaming backend.

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
All implemented-backend flags remain false until integration is actually present.

## Next implementation slices

1. Map display points/backing pixels and native window lifetimes into existing
   topology, window IDs and geometry epochs. Validate mixed Retina scales,
   negative display origins and window close/reopen handling.
2. Add ScreenCaptureKit SCStream capture, retaining IOSurface/CVPixelBuffer
   ownership until GPU consumers complete; then VideoToolbox encoding and the
   existing authenticated QUIC media path. Measure alpha and decorations rather
   than assuming support from window enumeration.
3. Add VideoToolbox decode and Metal presentation in AppKit proxy windows.
   Preserve geometry epochs and drop obsolete frames without closing sessions.
4. Implement ordered native input and held-key/button cleanup; verify target
   routing and OS permissions. All live mouse/keyboard acceptance is user-operated.
5. Integrate lifecycle, reconnect, clipboard and application audio independently;
   no fake backend should advertise these as native capabilities.

Follow [the availability policy](../../docs/security-and-availability-policy.md):
33 ms/two refresh periods is a performance target; focus changes, congestion and
recoverable per-window failures must not terminate unrelated windows or sessions.

## Verification boundary

The macOS workflow checks the portable daemon, tests foundation crates and builds
the universal native probe. Its only native test is `--help`, which needs no
desktop permissions. CI does not establish capture, input or visual acceptance.
Linux cross-checks can check Rust target compilation, but cannot compile or run
Apple frameworks without an Apple SDK. Native probe compilation and runtime
acceptance must be confirmed on macOS.

API references: [SCShareableContent](https://developer.apple.com/documentation/screencapturekit/scshareablecontent),
[CGPreflightScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()).

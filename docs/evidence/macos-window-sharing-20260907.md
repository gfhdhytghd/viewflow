# Native window sharing verification — 2026-09-07

Implementation and setup: [macOS / Hyprland / Windows window sharing](../macos-window-sharing.md).
This record covers generated video, compilation and protocol recovery, not live
window capture or interactive acceptance. No mouse/keyboard input was injected
and no application focus was changed by these checks.

| Check | Result |
| --- | --- |
| macOS native universal arm64/x86_64, deployment target 13.0 | Built with Xcode beta clang++, ARC, C++20, `-Wall -Wextra -Werror` |
| macOS portable `vf-window-peer` | Native `cargo build --locked` passed |
| VideoToolbox generated frames | H.264 and HEVC encode/decode, resize passed |
| Core Image/Metal color and alpha | Asymmetric quadrants, alpha 255/128/64/0 and orientation passed |
| Windows x64 presenter | Visual Studio 2022 Release build passed |
| Mac-generated H.264 on Windows | Four frames decoded, including 64→80→64 width changes and EOF drain |
| Same H.264 on Linux/NVIDIA | All four frames decoded in `--validate` mode |
| Linux native input helper | Build and help test passed; no native event execution |
| Linux reverse presenter | Build and two wire/geometry CTests passed |
| QUIC bridge | Both TLS role assignments, ordered input after 80 ms delay, native restart on same paired connection, EOF cleanup passed |
| Rust wire codec | Three serialization/alpha tests passed |
| Hyprland native source | Build with `native-gpu-nvenc`; scaled negative-origin and decoration coordinate test passed |

Mac builds used an isolated `viewflow-window-share.O2SjgD` directory on the Mac
mini. Windows builds used an isolated `window-share-20260907` directory. Linux
native builds used `/tmp/viewflow-linux-window-input-build` and
`/tmp/viewflow-linux-window-presenter-build`. Existing desktop services were not
replaced. Rust emitted existing unused-code/style warnings; this was not a clean
workspace-wide lint run. The universal Intel slice was compiled, not executed on
Intel hardware.

The source-generated fixture contains synthetic pixels only. Linux and Windows
validation decode it without creating visible proxies. Portable QUIC tests use
loopback test identities and a generated fake native process; they do not prove
live LAN rendering latency. The implementation supports all four documented
directions, but live capture-to-proxy acceptance for each remains pending.

Compact logs: [macOS](macos-window-sharing-20260907/macos.txt),
[Rust](macos-window-sharing-20260907/rust.txt),
[Hyprland](macos-window-sharing-20260907/hyprland.txt),
[Linux decoding](macos-window-sharing-20260907/linux-decode.txt),
[Windows decoding](macos-window-sharing-20260907/windows-decode.txt).
[Source hashes](macos-window-sharing-20260907/source-sha256.txt) identify the local
implementation snapshot; the workspace also contains unrelated concurrent work.

Remaining user-operated checks: ScreenCaptureKit live framing and permissions,
transparent/decorated windows, Retina/mixed-display scale, moving/resizing,
close/reopen, focus changes and held-input release across disconnect/reconnect.
Application audio, automatic popup-family enrollment, native touchpad contacts
and IME integration are outside this backend's implemented scope. No 33 ms miss
is used as an authorization boundary or session shutdown condition.

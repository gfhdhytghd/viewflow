# Native iMessage popup backdrop probe — 2026-09-12

User opened and held the Messages filter popup (window 9339). The signed
Viewflow main app ran its embedded diagnostic through Launch Services. No
mouse/keyboard input or focus changes were injected. A passive mouse-transparent
image window was placed immediately below the popup and removed after capture.

All four captures are 244 × 234 pixels. `shouldBeOpaque = NO`; shadows ignored.
The test image was a magenta checkerboard, stretched over the popup plus a
64-point margin. This proves backdrop response, not real-time Linux background
transport or its coordinate mapping.

- Independent window capture: 0 changed pixels; pixel arrays identical.
- Display-region capture: 57096 of 57096 changed pixels.
- Display RGB mean absolute difference: 24.856 / 255.
- Window alpha: 438 transparent, 1882 translucent, 54776 opaque pixels.

`comparison.png`: top row independent-window before/after; bottom row display
before/after. The native screen composition changes color with the backdrop,
while independent-window capture omits that response. For this popup, returning
a backdrop alone cannot fix the current independent-window source. A display
region capture path is a viable next experiment; accurate remote background
mapping, shape/alpha extraction, shadow preservation, occlusion and latency
were unimplemented/unverified at the time of this probe. Do not treat display cropping as transparent
window capture or infer that every macOS popup uses the same material.

## Subsequent live implementation

The macOS source now combines display-region color, a display capture excluding
the popup, and the independent window's alpha mask. A persistent display preview
supplies initial popup color while the independent streams start. Linux captures
the scene immediately before the popup's surface render, sends a PNG over the
ordered reverse channel, and macOS places that image in a passive backing window.
This path is enabled for the supported popup tiles; it is not a general solution
for arbitrary overlapping windows. The Linux capture currently supports normal
monitor transform and a maximum 2048 × 2048 capture region.

The receiver keeps a new popup transparent until its initial position is applied.
The source reserves atlas space for popups to avoid rebuilding the video format
on each input-method appearance. Repeated application/AX classification is cached,
and independent capture startup is deferred until the first preview is published.

Before the final cache/startup changes, three observed preview-to-publication
records measured discovery-to-preview at 37.88, 110.98, and 135.34 ms, and
discovery-to-publication at 81.52, 199.74, and 176.41 ms. These are source-side
measurements, not end-to-end visible latency. There are no new popup samples yet
after the final deployment, so its latency improvement remains unverified.

The Linux hook produced a 502 × 582 background PNG for popup 9669. That alone
does not prove matching native background composition at the receiver. Final
background transport/caching changes and absence of a visible placement jump
still require a user-operated popup test. Builds and protocol tests passed;
they do not establish those visual outcomes.

### Safari live correction

A user screenshot exposed an inverted, enlarged Safari image in the popup.
The live CG window order confirmed that the same-level passive backing window
was above Safari's layer-101 menu. It now uses level 100, and live ordering
confirmed Safari above the backing. Both active Safari and Messages capture
helper copies were updated and restarted; the main signed app also contains it.

Linux capture now reads the current DRAW framebuffer explicitly, preserves
Hyprland's intermediate framebuffer row order, and samples before the first
Mac proxy surface in the render pass. This excludes Mac proxy content from
its returned underlay. A live shared-memory PNG after the change showed upright
Linux local content with neither Safari nor its menu. The user closed the menu
before the final receiver screenshot, so final visual acceptance remains open.

## Full virtual-desktop backdrop (supersedes the per-popup backing above)

The source now owns a passive desktop-level window on the Viewflow virtual
screen only (`kCGDesktopWindowLevelKey + 1`). Its image contains the Linux
wallpaper, Linux application windows and layer surfaces, excluding all
`ViewflowReverse-*` windows. It retains the coordinate mapping; it is not
stretched to hide differences between the two displays' origins.

Linux now renders into a separate full-monitor framebuffer, with its own
stencil attachment and live blur, at a 200 ms cadence. Reading before the first
Mac surface had omitted Linux surfaces drawn later. The separate render fixes
that omission and does not reuse the monitor's cached blur containing Mac
proxies. An event-loop timer drives updates even when desktop animation stops.
The live 6144 x 3456 shared-memory image showed both complete Linux Codex
windows and the status bar with no Safari proxy or rectangular missing areas.
The signed Mac helper logged receipt of a 9,879,284-byte full background PNG.
Only normal Linux monitor transform is currently supported; rotated outputs
and alternate fullscreen/special-workspace stacking are not validated.

Two user-operated Safari openings produced a separate concrete defect:
window 293's scene was 484 x 1050, while its independent capture mask was
4 x 4 (body 2 x 4). Before the independent stream existed, a resize request to
nil left `updating` permanently set because no completion callback ran.
The fix sizes the stream from current CG bounds before creation and never
updates a nil stream. Material composition now waits for the matching full-size
mask, retaining the preview during the opening animation instead of shrinking
the scene to the tiny mask. This fix compiled with warnings as errors and was
signed, installed in the app and active isolated Safari helper, and restarted.
A new user-operated opening is still required to validate the final material
resolution and repeated-opening visual behavior.

The two legacy all-window source LaunchAgents were disabled and stopped.
Process inspection after deployment found only the main app's selected Safari
source. Persistent display preview is restricted to Viewflow's virtual display;
local-only window suspension exists in the source, but a physical-display drag
was not injected to test it. Mouse and keyboard tests remain user-operated.

Validation: plugin build and protocol/popup-scope CTests passed; Mac clang++
build and deep/strict signing verification passed. A broad plugin build also
hit an existing `window_keyboard_state_test.cpp` maybe-uninitialized warning;
that unrelated test was not changed. Physical menu appearance, end-to-end
latency, and real local-only drag behavior remain explicit acceptance gaps.

### Popup input beyond parent bounds (2026-09-12)

The reported boundary is inside the display but outside the parent window.
The `viewflow-windows-reverse-ime` rule set `no_focus=true`; Hyprland
`ViewHitTester.cpp` excludes noFocus windows from pointer hit testing, so
input fell through to the parent or the local desktop beneath the popup.
Changed the presenter startup rule and the active HyprV rule to explicit
`no_focus=false`, retaining `no_initial_focus=true`. Explicit false also
updates the existing named Lua rule, whose omitted effects remain installed.
Applied the same rule through `hyprctl eval` without restarting the stream.
Live matching-popup `hyprctl getprop ... no_focus` changed from true to false.
The Linux presenter rebuilt successfully; Lua syntax validation, live config
error check, and `git diff --check` passed. The no_initial_focus field is
preserved in both definitions; getprop does not expose that field. No input
or focus was injected. User-operated clicks in the portion beyond the parent
remain the end-to-end acceptance check.

### Bottom window, half resolution, 15 fps (2026-09-12)

Replaced the desktop-level (`kCGDesktopWindowLevelKey + 1`) background
window with a fixed `NSNormalWindowLevel - 1` window. It remains passive,
non-key, non-main, and scoped to the virtual display. The image keeps its
source logical coordinates and is clipped by the display; it is not stretched
to erase source/display geometry differences.

The independent Linux scene still includes local windows and excludes all
Viewflow proxies. GPU linear downsampling halves each pixel dimension before
PBO readback and PNG encoding. Logical dimensions are unchanged. Capture
deadlines advance at 66,667 microseconds with a 4 ms nonblocking timer/fence
poll. PNG encoding uses the fast compression flag; unchanged frames remain
suppressed. Late work skips missed deadlines rather than queueing frames.

Live capture measured 15.19 fps across 62 samples in about four seconds,
3072x1728 pixels with a 3072x1728 logical extent (previously 6144x3456
pixels). The captured image was inspected and is upright with the full local
scene. This is the capture cadence, not a measured Mac scanout cadence.
Linux plugin and presenter builds passed; the protocol and popup-scope CTests
passed (2/2). Mac clang++ with Werror and deep/strict signature validation
passed. Installed and isolated helper hashes match; the running Linux
presenter hash matches the rebuilt binary. Mac runtime logged
`desktop-backdrop level=-1 display=9 bounds=-3072,-264 3072x1728` and received
a 3,472,707-byte PNG after reconnect. No mouse or keyboard input was injected.

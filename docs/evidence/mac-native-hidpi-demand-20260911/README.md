# Native Mac decoration, HiDPI and capture scope — 2026-09-11

## Implemented

- Native shadow/frame transport; separate body rectangle, logical dimensions
  and pixel scale in tile flag 16. Linux xdg geometry/input regions exclude
  shadow pixels. A distinct MacNative app class bypasses the Linux shadow.
- 2x virtual parking display backing; logical placement is unchanged.
- Main-app and Python-supervisor selection by remote overlap minus the union of
  physical displays. Native sources also suspend capture while outside the
  remote region and can resume from metadata when the window returns.
- Existing ordered HID window input and its fallback are retained.

## Validation

Linux Release build and wire/geometry CTests: 2/2 passed. Strict C++ tests cover
native geometry roundtrip, logical size independent of buffer size, asymmetric
translucent body detection, input exclusion and physical-display union/gaps.
Mac native CTests: 11/11 passed. Swift configuration/selection tests passed.
Python source-scope tests passed; unified app tests passed (9 run, 1 skipped).
Strict GUI signing and git diff --check passed.

A real ScreenCaptureKit Settings sample showed a 1992x1764 output, scale factor
2, contentScale 1, boundingRect 786x672 points, and screenRect 740x626 points.
This exposed that boundingRect includes shadows. Final geometry uses screenRect
for the body dimensions and alpha edges for its in-frame offset. No physical
mouse, keyboard, focus or gesture input was synthesized. Final shadow alignment
and cross-boundary resume still require user-operated acceptance.

## Current runtime

All three current windows (151, 179, 227) were outside the remote region at
readback. Updated native helpers report `capture idle: outside remote region`,
`samples=0`, and `windows=0`. Hyprland reports no Mac proxy clients and no config
errors. Main App PID 67987 remains running. Whole-desktop input and Windows
sharing remain paused.

Mac runtime helper and staged app helper both hash:
5b7d7b31804918e4a0d55994a3694441f2aac6cadd1083756d75449ca1d6724d.
Linux installed presenter hashes:
3a8f41c2b770f8edae60f14faed11b3d8225048fb1c796287096a5806b992c16.
The three existing Mac Linux-worker configurations request scale 2 and native
decorations; their previous configurations were backed up.

## Installation still required

Signed complete bundle and zip:
~/viewflow-unified-20260910/mac-native-hidpi-demand-r3/Viewflow.app.
Latest app staged at ~/Viewflow-Install/Viewflow.app.

The user's manual-install preference is preserved: /Applications/Viewflow.app
was not overwritten. The currently running parking display remains its old
mode. Installing the staged bundle and restarting the app is required to apply
the 2x HiDPI parking display and the main-app worker-selection changes. Do not
claim that the current virtual display has already switched to HiDPI.
Local network permission has already been allowed by the user; live QUIC
connections were confirmed. A separate diagnostic process lacked screen-capture
authorization, so no permission prompts were bypassed or re-requested.


## Verified after user installation and launch

The user installed and launched the staged build. Installed App PID 88809 and
its native helper hash match the final build; strict bundle signature verification
passes. Its parking helper PID 88814 owns display 6. Direct CoreGraphics readback
confirms logical 3072x1728 and backing pixels 6144x3456 (2x), at (-3072,-390).
The physical display remains logical 1920x1200, pixels 3840x2400.

Read-only accessibility inspection of the actual app shows the Mac window-share
component as `等待可共享窗口`, with HID waiting for a touchpad connection. There
are zero source capture workers and zero Mac proxy clients in Hyprland; config
errors are empty. Thus the updated main app has retired the old idle workers.
Standalone SSH helper enumeration reports its separate capture permission as
unavailable, while the actual GUI app reports normal waiting-for-windows state;
no new permission request was made. Native shadow alignment and crossing/resume
still await user-operated movement of a window into the remote region.

## Follow-up: native framing, focus changes and capture controls

User reported right/bottom clipping, upper-left artifacts, displaced clicks,
focus-dependent shaking and apparent duplicate Messages windows. Read-only
screenshots confirmed surface clipping at the body rectangle. Linux now presents
the complete framed surface as xdg geometry, translates its outer position back
to the native body for AX geometry, and maps surface input through body offsets
and displayed scale. GeometrySync compares actual outer rectangles, so a changed
asymmetric shadow inset is not treated as a local user move. Regression tests
cover focused/unfocused frame changes and resized pointer edges; Linux CTest 2/2
passes. A post-deploy screenshot shows complete rounded edges and shadows.
Physical focus/drag/click acceptance remains user-operated.

Mac AX inspection also identified 66x20 `AXDialog` windows whose child is
`WindowSharingSessionButton`. Those OS capture controls were being recursively
captured. Discovery and native source now exclude this exact AX identity, not
ordinary dialogs. A live helper logged `window 1179 ignored: macOS sharing-session
control`. `includeChildWindows=NO` avoids duplicating independently shared child
content. Two separate native standard Messages windows, IDs 871 and 1017, were
also present; neither was closed by the agent.

The signed full Mac build is `~/viewflow-unified-20260910/mac-frame-scope-r2/Viewflow.app`
and is staged at `~/Viewflow-Install/Viewflow.app` for user installation. Existing
capture helpers were updated; the running main app still uses its prior discovery
binary, so installation is required to persist the control-window exclusion and
apply it before worker selection. Linux deployed presenter and launcher match
these changes. No physical input or focus was synthesized.

Secondary-click diagnosis remains open: Linux `tap-to-click=true`,
`clickfinger_behavior=false`, default tap button mapping. Presenter logging now
records BTN_RIGHT (273) down/up separately. Existing Mac logs did not distinguish
button codes, so their generic `posted=1` lines cannot establish right-click
acceptance. User clarification requested: two-finger tap versus physical press.

## Finder secondary-click root cause (05:42 UTC)

A user-operated secondary click was observed by a listen-only annotated-session
CGEvent tap: types 3/4, button 1, target PID 433, window/handler 151. Independent
read-only CG inventory then showed Finder menu windows 1464 and 1466 at level
101. Thus input delivery to Finder succeeded; the ordinary-window-only selector
omitted the context menu. A BetterDisplay overlay was present but the event's
actual handler was Finder, so it is not evidence of interception.

The new Mac app selects level-101 menus belonging to selected application PIDs
with a separate transient reserve of eight; menu creation cannot evict its parent
from the normal window budget. The native source marks menus transient for the
existing non-focusing popup presenter path. Swift tests verify inclusion with a
full normal-window budget and exclusion when its owning application is not
selected. Configuration tests, native build tests and strict signature checks
passed. Signed bundle: `~/viewflow-unified-20260910/mac-popup-menu-r2/Viewflow.app`;
staged installation: `~/Viewflow-Install/Viewflow.app`. The running app was not
replaced; user installation/restart and actual menu display/click acceptance are
still required. Both bounded read-only observers have completed.

# Windows popup shadow geometry investigation

Research only, 2026-10-08. No renderer/configuration changes or injected input.

## Confirmed implementation behavior

- `platform/hyprland-plugin/src/macos_shadow.cpp` attaches the same analytic
  shadow to every WindowsNative proxy. It has no popup/native-shadow policy.
  The two broad lobes use ranges 88/74 logical pixels and offsets 17.5/19.
- Its rectangle expansion is NOT, by itself, a double-expansion bug. The running
  Hyprland `renderRoundedShadow` shader expects an expanded rectangle and uses
  `range + round` to recover the shape; the built-in decoration does the same.
- Hyprland then subtracts the current window's `surfaceLogicalBox` from the
  shadow draw region. Our receiver declares its full body surface as window
  geometry. Any transparent margin inside that rectangle is excluded too.
- The source sets body_x/body_y to zero and body_width/body_height to its crop
  dimensions. Ordinary popup crops use Win32/DWM rectangles, not an observed
  visible-body mask. `source-shadow=0` is an unconditional log label, NOT a
  measured proof that source pixels contain no custom shadow.
- `shadow_corner` only attempts to fit four corners at the current tile edges.
  `rX` means no reliable fit; the plugin still draws the two broad lobes.
- Logs identify Word's toolbar as `Net UI Tool Window` (638x135 source pixels)
  and the other popup as `Chrome_WidgetWin_1` (818x152). The actual alpha/body
  extents of these two examples have NOT yet been captured. The screenshot
  alone cannot distinguish transparent padding from an embedded soft shadow.

Thus the implementation supports the reported detached-shadow mechanism,
but per-popup native-shadow/padding attribution still requires a live sample.

## Recommended implementation

1. Introduce an explicit per-window shadow mode: source-provided, generated,
   or none/unknown. Do not attach the main-window shadow solely because a
   window has WindowsNative in its class. Separate helper effects owned by an
   application must not themselves acquire another shadow.
2. Keep the full captured visual extent separate from the actual window body.
   Preserve native shadow pixels when source-provided; do not synthesize a
   second shadow. Use the body rectangle for XDG window geometry and layout,
   with visual padding outside it and a non-interactive shadow area. The
   protocol already has body offsets; the current receiver crops to them,
   so setting those fields alone would discard the exterior pixels. Both
   presentation and geometry/input mapping need updating together.
3. Generate a missing shadow from the body alpha mask, not the capture's
   bounding rectangle. Use a rounded-rectangle analytic fast path only when
   validated against that mask. For other shapes use an A8 mask and separable
   GPU blur; cache by shape, dimensions and scale, not by document RGB changes.
   Draw behind the source with premultiplied-alpha source-over. Do not reuse
   the current whole-rectangle cutout for a mask-based pass. Keep compositor
   transforms, Stage clipping, damage and stacking applied to the same shape.
4. Geometry updates must be atomic with frame metadata. Convert surface input
   coordinates through the visual/body offset back to the unchanged guest
   coordinates. Do not resize a guest popup because its visual padding was
   discovered. Leave main-window resize and tiling semantics intact.

A single alpha threshold is not a universal body detector: translucent UI and
native soft shadows can have the same alpha. Alpha > 0.01 bounds are useful
for eliminating empty transport margins, not for proving a body/shadow split.
Prefer validated native geometry/class behavior; otherwise preserve the
source appearance and avoid adding a knowingly oversized rectangular shadow.
Do not infer popup status from size alone.

## Verification before deployment

- Capture each reported popup's source alpha, Win32/DWM bounds, crop, owner and
  Linux geometry together. Read-only sampling must not claim coherent frame
  evidence without validating the slot/sequence; never take the live reader's
  shared-memory slot ownership.
- Synthetic cases: opaque rounded toolbar, asymmetric transparent padding,
  source soft shadow, translucent body, asymmetric corners, and partial
  resident texture. Check that classification cannot silently cut content.
- At scales 1/2 and negative monitor origins: verify body/input coordinates,
  shadow attachment, and atomic geometry during resize. A shadow should fade
  continuously out from the body, with no transparent gap or rectangular seam.
- Verify cached mask updates only on shape/scale changes and measure GPU cost;
  do not add a synchronous full-frame readback or per-frame 16K alpha scan.
- User operates selection/hover/menu tests, including Hymission Stage and
  floating/tiling transitions. Build proof is not visual acceptance.

## Primary references

- Microsoft GetWindowRect: invisible resize borders and differing DPI semantics:
  https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowrect
- Microsoft Direct2D Shadow effect: shadows generated from image alpha:
  https://learn.microsoft.com/en-us/windows/win32/direct2d/drop-shadow
- Installed xdg-shell.xml `set_window_geometry`: visible window geometry may
  exclude drop shadows. Upstream protocol:
  https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/stable/xdg-shell/xdg-shell.xml
- Running compositor source: `/home/wilf/data/Hyprland/src/render/OpenGL.cpp`,
  `renderRoundedShadow`, and `render/shaders/shadow.glsl.inc`.

## Implemented correction (2026-10-08)

Deployed a scoped correction to the detached synthetic shadow rather than
heuristically cropping a translucent popup or claiming to recover a unique
body/native-shadow split from RGBA:

- Windows publishes `windows_popup_flag` (4096) for native tool windows and
  captionless transient/non-resizable popup surfaces. It does not use a size
  threshold. Main Word window read-back remains WindowsNative-rX.
- Linux encodes popup shadow policy in WindowsNative-p<radius-or-X>. It checks
  the existing corner fit plus the full straight perimeter's opaque coverage.
  Padding, soft translucent edges, incomplete resident data and contour gaps
  cannot authorize a rectangular synthetic popup shadow.
- The compositor preserves source pixels and adds no synthetic shadow for pX.
  A validated tight popup body gets a 12-point zero-offset shadow plus the
  existing 2-point contact edge; no main-window broad lobes or body offset.
  Main windows retain their existing policy. Captured pixels, input geometry,
  focus and Start-menu behavior are not changed by this correction.
- The source's unconditional `source-shadow=0` diagnostic now correctly says
  `source-shadow=unclassified`.

This does not implement arbitrary-mask GPU blur or claim to classify every
native shadow. An unclassified popup with no embedded shadow is deliberately
shown without an additional generated shadow, rather than a detached one.

Validation: Linux CTest 10/10, Windows CTest 19/19, plugin build and scoped
reload passed. Added tests cover popup flag round-trip, tool/main Win32 styles,
opaque tight/square/rounded silhouettes, translucent perimeter, padding,
contour gaps and partially resident pixels. Tests assert source alpha remains
unchanged. Both native binaries deployed together because old validators do
not accept the new flag. Transport read-back is still IVSHMEM BGRA; compositor
config errors empty. User visual acceptance of the popup change is pending.

User accepted the deployed popup shadow correction with “没啥问题” before
requesting retained snapshots for non-transmitted regions. That later change
is documented separately in `retained-surface.md`.

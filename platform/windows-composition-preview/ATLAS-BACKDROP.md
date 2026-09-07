# Atlas host-backdrop fallback

The actual atlas proxy tree contains a host-backdrop Gaussian effect underneath
the decoded premultiplied foreground. Each HWND enables the documented
`DWMWA_USE_HOSTBACKDROPBRUSH` attribute. The foreground is never fed into the
Gaussian effect, so source text, icons, and borders remain sharp.

This is independent of the legacy single-window `--blur-rect` diagnostic. Atlas
VFGP currently does not carry a source-selected blur region or blur recipe.
Consequently this implementation uses a local fallback, not a reproduction of
the source compositor's requested blur region or radius.

## Configuration

The receiving process reads `VIEWFLOW_ATLAS_BLUR_SIGMA` once before live frame
admission. The default is `12` physical pixels (Gaussian standard deviation).
Finite values from `0` through `64` are accepted; `0` disables the backdrop and
retains the alpha-only path. The value does not scale with DPI. Changing it
requires starting a new receiver process. No protocol fields or deadlines are
changed. This is an environment setting on the Windows receiver process, so a
launcher must explicitly preserve it if the launcher filters its environment.

The enabled path requires Windows support for the documented DWM attribute
(Windows 11 build 22000 or later). Attribute/effect creation failure aborts
initialization instead of reporting a working blur. Windows transparency and
power policies can also affect host-backdrop appearance.

## Coverage and geometry

`CompositionMaskBrush.Mask` references the exact same GPU surface brush as the
foreground for that frame. Its source is the blurred host backdrop. Alpha is
used as continuous coverage; no threshold, CPU readback, second pixel upload,
or blur of the mask is performed. Both visuals have identical size and offset,
including desktop scaling and off-viewport cropping.

Fully transparent corners have zero backdrop coverage. Low-alpha shadows have
correspondingly weak backdrop coverage, instead of creating a solid rectangular
blur panel. At opaque pixels the foreground covers the backdrop completely.
For foreground alpha `a`, the additional backdrop contribution behind the
foreground is proportional to `a * (1 - a)` (and to the host brush's own alpha).
Thus this conservative fallback does not produce full-strength blur through
every translucent surface. It also cannot distinguish a shadow from an intended
translucent blur region when both have the same alpha. Source-authored blur
coverage is still needed for exact shadow exclusion and source-exact results.

## Startup and deadline behavior

Reserved proxy warmup creates the effect, mask, and hidden visual tree ahead of
live presentation. The mask and backdrop visual brush remain null; warmup never
binds pixels or exposes the backdrop. Without reserved proxies, resource
creation remains inside the existing live deadline and may expire unbound.

All frame copies remain unreachable from the visual tree until the existing
final admission check. Foreground bind begins the mutation interval; same-frame
mask bind, backdrop size/offset/brush updates, and subsequent HWND operations
remain inside it. An additional absolute-QPC check precedes the backdrop changes
and another follows them. Once mutation starts, deadline failure tears down the
receiver; it cannot emit `expired-unbound` for that frame. The existing final
commit check and two-refresh-cycle budget are unchanged. Submission still is
not a physical presentation receipt or a measurement of DWM effect latency.

When a previously admitted identity disappears from a submitted layout (including
an empty layout), its proxy is hidden and both foreground and backdrop are
unbound. Its HWND and effect resources remain reserved under that identity, so
repeated oversized-window suspension and re-entry do not exhaust the proxy pool.
Input frame history is invalidated before hiding. A held application button/key,
pending keyboard recovery, active desktop drag, or mouse capture makes removal
terminal rather than silently discarding input. The source must also invalidate
the removed window's grant. Re-entry grants native input only after a fresh
visible candidate commits. Permanently retired input is never revived by this
path. The bound remains the stream's admitted identity capacity; this does not
permit unlimited new identities through one reserved slot.

## Verification status and receiver checks

The change requires a Windows build and visual verification; no live Windows
success is claimed by this document. With a high-contrast local background and
a translucent source window, compare sigma `0` and `12`: the background should
soften through the window while source lettering stays sharp. Check transparent
rounded corners, soft shadows, tile resize, and partially offscreen desktop
placement. Check that startup remains hidden and deadline failures after any
bind fail closed rather than returning an unbound disposition. A successful
build alone does not establish these visual or timing results.

API references: [host-backdrop sampling](https://learn.microsoft.com/en-us/uwp/api/windows.ui.composition.compositor.createhostbackdropbrush),
[composition opacity masks](https://learn.microsoft.com/en-us/windows/apps/develop/composition/composition-brushes),
[DWM window attributes](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute).

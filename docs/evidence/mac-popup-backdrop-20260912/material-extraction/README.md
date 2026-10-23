# Native material extraction experiment

2026-09-12 14:45 EDT; same user-held Messages filter popup, window 9339.
Embedded signed Viewflow diagnostic; no injected input or window activation.

## Capture variants

Display `includingWindows:[menu]` and independent-window capture produce
identical pixel arrays, before and after inserting the test background. Merely
switching ScreenCaptureKit filter styles does not preserve backdrop response
for this popup.

A display region retains native material. A second display filter excluding the
popup supplies the background, and independent-window capture supplies alpha.
For each premultiplied color channel, extraction computes
`clamp(display - behind * (1 - alpha), 0, alpha)` with 8-bit rounding.
This removes background contamination at antialiased edges. It does not
reimplement the glass shader.

## Measured recomposition

Recomposed extracted RGBA over the corresponding captured background using PIL.
Compared against display RGB in the same sRGB PNG space:

| Capture | RGB mean absolute error / 255 | Max error | Opaque-body MAE | Edge MAE |
|---|---:|---:|---:|---:|
| Before | 0.006247 | 21 | 0 | 0.189515 |
| After | 0.005926 | 1 | 0 | 0.179773 |

Both material alpha arrays exactly equal independent-window alpha. Maximum
before error is localized; sequential screenshots and quantization do not prove
perfect edge reconstruction. `materials.png` shows extracted transparent RGBA
before/after. `*-recomposed.png` permits independent comparison with display PNGs.

## Scope

The main application contains this diagnostic. Production source still uses
independent-window capture; do not report live glass forwarding as fixed.
Real-time integration requires frame/geometry pairing, recovery when one stream
lags, original shadow handling, correct z-order background export from Linux,
and remote background placement. Transparent interiors beyond this popup may
require a different coverage mask; this method is verified only for this popup.

Apple filter reference:
https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:including:)

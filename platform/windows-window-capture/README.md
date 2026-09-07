# Windows window capture source

This is a bounded source-side `Windows.Graphics.Capture` (WGC) backend slice.
It is deliberately independent from `../windows-composition-preview`, which is
a destination preview/composition diagnostic.

`WindowCapture::start` accepts an `HWND` and creates its capture item only with
`IGraphicsCaptureItemInterop::CreateForWindow`. There is no monitor, desktop,
GDI, `PrintWindow`, or Desktop Duplication fallback. An invalid HWND is
rejected before WGC is initialized. It does not turn a failed window capture
into a screen capture.

## What this slice provides

- a D3D11 hardware device and a free-threaded WGC frame pool carrying
  `B8G8R8A8` surfaces;
- a borrowed `ID3D11Texture2D` callback for the current window frame, including
  WGC's original QPC-relative `SystemRelativeTime` and exact `ContentSize`.
  C++/WinRT exposes the time as `std::chrono::duration`; its raw `.count()` is
  retained in 100 ns units, while a negative count is terminally rejected.
- generation-numbered geometry: every output contains pixel `ContentSize` and
  the unmodified DWM extended-frame bounds when available (otherwise the
  unmodified `GetWindowRect` fallback);
- resize handling that discards the transitional WGC frame and recreates the
  pool before publishing a new geometry epoch, avoiding clipped/undefined
  allocation tails; and
- target lifetime and failure callbacks. `GraphicsCaptureItem::Closed` ends the
  stream, including applications that replace the target window seamlessly.

WGC's BGRA format alone does not promise a straight or premultiplied alpha
mode. The backend preserves its alpha byte without conversion and labels it
`bgra8_alpha_preserved_unknown_mode`; consumers must not infer a blur/shadow
mask or alpha semantics from this slice.

`E_ACCESSDENIED` is reported as `access_denied_or_protected` and never falls
back to a broader source. This deliberately expresses an access/protection
boundary without pretending it can identify every protected-content rendering
behavior (for example a compositor-supplied blank frame). Any such visual
behavior needs a separately authorized owned-window acceptance test.

## Build and test requirements

The portable contract test runs without the Windows SDK:

```sh
cmake -S platform/windows-window-capture -B /tmp/viewflow-wgc-build
cmake --build /tmp/viewflow-wgc-build --parallel 2
ctest --test-dir /tmp/viewflow-wgc-build --output-on-failure
```

It also statically rejects monitor, Desktop Duplication, `PrintWindow`, and
`BitBlt` fallback symbols in the native source. That is a source-boundary
guard, not a substitute for a real owned-window capture trial.

`CreateForWindow` itself requires Windows 10 version 1903 / build 18362 or
newer. This slice also unwraps its WGC surface through
`IDirect3DDxgiInterfaceAccess`, for which Microsoft lists build 20348 as the
minimum supported client; treat 20348 as this backend's runtime floor. Build
from an x64 Visual Studio Native Tools prompt with a Windows SDK that includes
C++/WinRT, `windows.graphics.capture.interop.h`, and
`windows.graphics.directx.direct3d11.interop.h`, plus D3D11 hardware support:

```powershell
cmake -S platform/windows-window-capture -B build-wgc -G Ninja
cmake --build build-wgc --config Release
ctest --test-dir build-wgc --output-on-failure
```

The host must enter a WinRT apartment before calling `start` and must not call
`stop` synchronously from a frame/geometry/terminal callback; the callback
should signal its owner to stop instead. The library is intentionally not wired
to Viewflow's shared protocol, encoder, or process lifecycle yet. Native
compilation only establishes the API boundary; it does not constitute a live
window-capture, alpha, protected-content, or presentation acceptance result.

## Bounded verification

On the isolated WindowsVM, a clean Release configure/build with Windows SDK
`10.0.26100` and MSVC `19.44` compiled the native static library and ran the
two CTests successfully (`2/2`, `0.10 s`). The resulting static library SHA-256
was `F3BD84B8B1858D38383FE76F4D53ECDAC6041FFCE848A6A2FCF79F1386A00D52`.

That build also resolved two C++/WinRT projection mistakes found by the first
two compile passes: WGC's `SizeInt32` is `Windows.Graphics.SizeInt32`, and
`SystemRelativeTime` is a `std::chrono::duration`, whose raw 100 ns value is
read with `.count()` rather than an ABI `Duration` member.

No `WindowCapture::start` call, real HWND capture, user-content capture, UI
inspection, alpha/protected-content behavior, resize/lifetime callback, or
destination presentation was run in this checkpoint. Those remain separate
owned-window acceptance work.

## References

- Microsoft: [CreateForWindow](https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createforwindow)
- Microsoft: [screen capture frame-pool guidance](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)
- Microsoft: [GraphicsCaptureItem.Closed](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscaptureitem.closed)

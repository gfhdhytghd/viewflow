# Windows composition backdrop diagnostic

Atlas native-input proxies use source-side text composition: the destination
forwards physical input, not locally composed text. With atlas pointer events
enabled, startup disables IME only on the dedicated proxy UI thread, before
creating its windows, and fails if that policy cannot be established. This does
not change the system input language, other application threads, or the source
application's IME. Preview-only launches retain their normal IME behavior unless
the explicit diagnostic no-IME flag is set. Native keyboard forwarding and
source IME candidate/commit behavior still require their own end-to-end tests;
this startup policy is not proof that those paths are implemented.

Atlas wheel input requires `--atlas-wheel-v1` alongside the atlas pointer and
disposition flags. It emits distinct signed 1/120-detent wheel records with the
original OS QPC and event-time visual identity. It does not round fractions,
deduplicate unchanged-coordinate wheel actions or synthesize button transitions.
Missing identity, outside-client position, expiry, coalesced/ambiguous records or
keyboard modifiers retire the input route. Both receiver and source must opt in
with `pointer.wheel`; native capture and forwarding build tests are not live
application acceptance. See [wheel evidence](../../docs/window-wheel-input.md).

Button input is an explicit diagnostic opt-in: `--emit-pointer-buttons` requires
`--emit-pointer-motion` and its compressed/deadline mode. The Rust receiver uses
`--forward-pointer-buttons` alongside `--forward-pointer-motion`; the source
independently requires `--authorize-pointer-buttons`. These are not defaults.
Transitions retain native QPC deadlines and use the same committed visual identity
as motion. Failure/capture loss retires the stream; output remains synchronous
diagnostic stdout. Real cross-host click/drag cleanup has not yet been accepted.

This is an isolated, opt-in diagnostic. It does not alter Viewflow's GDI
presenter, protocol, deployment, or any Windows setting.

It is intended to prove only this narrow visual-layer route:

1. a bounded, premultiplied-BGRA VFBG frame is loaded locally (or supplied as
   a bounded stdin record for the explicit stream diagnostic);
2. a `DesktopWindowTarget` owns a composition tree for a local HWND;
3. a `CreateHostBackdropBrush` Gaussian effect is drawn only in an explicitly
   supplied rectangular diagnostic region; and
4. the source frame is drawn above that effect as a premultiplied BGRA surface.

`--blur-rect` is **not** inferred from source alpha. For the inspected Dolphin
artifact the temporary diagnostic rectangle is `9,9,760,626` within the full
`778x650` frame. It must not be reused as a generic decoration or blur rule.

## Deliberate limitation

The legacy single-window preview is rectangle-only. The current protocol supplies an optional
`blur_radius_dip`, but no source-selected blur mask bound to a frame and geometry
epoch. Window alpha includes shadows and transparent decorations, so it cannot
serve as that mask. Therefore this executable cannot establish arbitrary-mask
or source-exact blur support. The atlas path now has a local alpha-masked
host-backdrop fallback, described in [ATLAS-BACKDROP.md](ATLAS-BACKDROP.md);
that fallback also does not claim source-exact blur regions.

The required follow-up protocol is an explicit, source-produced 8-bit blur
coverage plane (in full decorated-frame coordinates), atomically bound to the
matching color frame and geometry epoch, plus a versioned blur recipe. A
destination must decline the capability if it cannot compose that mask with a
host-backdrop effect; it must not substitute a source wallpaper or enable an
undocumented window attribute.

## Build only

Use an x64 Visual Studio Native Tools prompt with the Windows SDK C++/WinRT
headers installed:

```powershell
cmake -S . -B build -G Ninja
cmake --build build --config Release
```

No run is implied by the build. A later, separately authorized visual test may
run the output with a staged VFBG file:

```text
viewflow_windows_composition_preview.exe --file C:\path\dolphin.vfbg \
  --logical-width 778 --logical-height 650 \
  --blur-rect 9,9,760,626 --radius 18
```

The radius is logical DIPs and is converted at the preview HWND's current DPI.
System transparency/power policy can suppress host-backdrop transparency; that
is an observed unsupported/disabled result, not a reason to change settings.

## Bounded stdin frame diagnostic

`--stdin-frames` is an opt-in Windows anonymous-pipe mode for exercising real
composition updates without creating a capture protocol. It is mutually
exclusive with `--file`; the window, compositor device, and HWND are created
once. The producer writes consecutive ordinary VFBG records to stdin, each
consisting of its existing 20-byte header followed immediately by exactly the
header-declared premultiplied BGRA payload:

```text
producer.exe | viewflow_windows_composition_preview.exe --stdin-frames \
  --logical-width 778 --logical-height 650 \
  --blur-rect 9,9,760,626 --radius 18 --visible-ms 60000
```

Every record is independently bounded to 16 MiB of pixels. Empty, malformed,
oversized, non-premultiplied, or partial-at-EOF records are rejected. The UI
thread uses `PeekNamedPipe` and bounded `ReadFile` work per tick, so it keeps
dispatching Windows messages instead of waiting for the producer. At most one
complete frame is retained: newer completed input replaces older unsent input.
Same-sized frames reuse the D3D/D2D device and composition surface; a changed
size safely replaces only the foreground surface while retaining the HWND and
DPI-derived logical layout.

`stdout` prints `submitted_frames=N width=W height=H` after each composition
submission, which is the acceptance evidence for dynamic updates. It is not a
display-present acknowledgement, continuous capture implementation, generic
blur-mask mechanism, or permission to hot-reload/run the diagnostic. EOF exits
cleanly after the final complete record; the existing 60-second `--visible-ms`
maximum remains the session deadline.

## Compressed GPU stdin diagnostic

`--stdin-compressed` is mutually exclusive with both VFBG modes and consumes
the versioned VFGP records defined in [VFGP-CONTRACT.md](VFGP-CONTRACT.md): one
Annex-B H.264 access unit plus one tightly packed Gray8 alpha plane per
identity. It reads only currently available bytes from one anonymous stdin
pipe in bounded UI ticks and dispatches Windows messages between ticks.

```text
producer.exe | viewflow_windows_composition_preview.exe --stdin-compressed \
  --logical-width 778 --logical-height 650 \
  --blur-rect 9,9,760,626 --radius 18 --max-frame-bytes 16777216
```

`--max-frame-bytes` defaults to 16 MiB. In compressed mode it bounds the
complete VFGP header plus payload before allocation; it can be raised for a
larger alpha plane. The H.264 hardware decoder, video conversion, alpha
premultiplication, and copy into the Composition drawing surface remain on one
D3D11 device. There is no CPU color readback. Every decoded display-order frame
is copied, `Flush`ed, then emits `submitted frame_identity=…` on stdout; this
is a submission acknowledgement, not proof that a monitor presented it. Clean
EOF first drains Media Foundation and submits every delayed identity; a partial
record or unmatched decoded frame is terminal.
# Explicit atlas mode

`--stdin-atlas-v5` selects the multi-proxy diagnostic path instead of the legacy
single-window CLI. It accepts only deadline-bearing VFGP v5 atlas records on an
anonymous stdin pipe, creates separate native windows by tile ID, and shares one
hardware decoder. EOF closes all proxies. The current atlas path supports
negotiated input and three decode-only startup warmups. It also prepares an
alpha-masked host-backdrop blur per proxy, with a local configurable sigma;
see [ATLAS-BACKDROP.md](ATLAS-BACKDROP.md) for behavior and limitations.

Its `atlas-submitted` output is a visual-submission result, explicitly marked
`physical_present_receipt=false`; it must not authorize input or stand in for a
physical presentation measurement. See `docs/atlas-layout.md` for the immutable
frame binding, resource limits, wire layout and remaining integration gates.

## Atlas timing diagnostics

`VIEWFLOW_ATLAS_TIMINGS=all` enables per-frame QPC/identity records and GPU
queries. Set `VIEWFLOW_ATLAS_GPU_QUERIES=0` alongside it to keep the QPC records
while disabling the native GPU timestamp and surface-copy completion queries.
Leaving the new variable unset preserves the existing behavior. The switch
does not disable surface submission or its existing context flush, and it does
not change frame admission or session recovery. Neither QPC records nor GPU
query results are physical presentation receipts.

The [six-run diagnostic overhead comparison](../../docs/evidence/performance-20260908/trace-controls/README.md)
measures these controls separately from reduced socket/source logging. It did
not establish 4K60 or display latency within two frames.

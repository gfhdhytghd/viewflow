# GPU RGBA preparation, 2026-09-05

`gpu_rgba_prepare.cuh/.cu` provides a reusable caller-stream operation over
disjoint pitched device buffers. It crops, optionally reverses the crop's row
order, repairs the first qualifying top seam and emits straight RGBA plus a
separate alpha plane. Unpremultiplication commutes with the seam's pixel copy,
so it is fused into the initial copy. Source pixels are not overwritten.

Root corrected asynchronous scratch initialization/lifetime and argument
validation: initialization is a kernel rather than a host-stack async copy,
all launch-error paths attempt stream-ordered scratch release, dimensions use
overflow-safe subtraction checks, and overlapping buffer extents are rejected.
Caller buffers must remain alive until stream completion, including on error.

Root independently ran `/tmp/viewflow-rgba-build/viewflow-gpu-rgba-prepare-test`
with exit 0 after correcting the test oracle's reversed continue condition.
The suite covers all 65,536 alpha/channel combinations, asymmetric crop/flip,
padded strides, first-only selection among two seams, insufficient seam
columns, narrow windows, exact separate alpha, device-source readback unchanged
and unchanged output padding. Runtime checks are not disabled by NDEBUG.

`gpu_shadow_math.cuh` separately transcribes per-pixel shadow math using a
render-time snapshot. Its host fixtures pass as a third normal encoder CTest.
The subsequent `gpu_shadow_repair.cuh/.cu` preserves the four outer and four
corner passes, including overlapping visits, and updates the independent alpha
plane after each pixel repair. Root independently ran
`/tmp/viewflow-gpu-shadow-repair-build/viewflow-gpu-shadow-repair-test` with exit
0. Seven scenarios (soft/sharp, black/colored, transparent configuration,
reconstructed alpha, clipped/fractional rounding, overlapping corners) matched
the independent CPU oracle exactly, including zero maximum alpha difference.
Invalid/overflow/alias checks also passed, including very large finite rounding
without an unchecked double-to-int conversion.

Render-time snapshot production and integration with the capture/encoder are
still pending. Separate kernel tests do not prove a complete live frame path.

No HyprCapture plugin or Windows runtime was changed by this slice. These
primitives are not yet a live decorated-window capture/encode implementation.

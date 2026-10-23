# Standalone KVMFR / EGL DMA-BUF import probe

This is an opt-in diagnostic, not the production receiver. It neither loads
`kvmfr`, allocates a backing device, changes QEMU, writes shared pixels, nor
connects to Wayland. An explicit hardware run initializes the selected EGL
GPU device and attempts a real import, so do not run it while preserving the
research jobs' GPU workload.

## Build and CPU validation

```sh
cmake -S platform/linux-reverse -B /tmp/viewflow-kvmfr-probe-build \
  -DVIEWFLOW_BUILD_KVMFR_PROBE=ON \
  -DVIEWFLOW_KVMFR_UAPI_DIR=/tmp/viewflow-lookingglass-reference/module
cmake --build /tmp/viewflow-kvmfr-probe-build --target viewflow_kvmfr_import_probe -j2
/tmp/viewflow-kvmfr-probe-build/viewflow_kvmfr_import_probe --self-test
```

The option defaults OFF; the hardware diagnostic is not a CTest test.
The CPU self-test opens no device and does not initialize EGL. It checks 6K,
16K arithmetic, page rounding, undersized capacity, misalignment, invalid pitch,
offset overflow and strict integer parsing. On 2026-10-09 build and this CPU
self-test passed. **Hardware export and EGL import have not been run.**

## Explicit hardware invocation (not executed)

```text
viewflow_kvmfr_import_probe --run /dev/kvmfrN OFFSET WIDTH HEIGHT PITCH EGL_DEVICE_INDEX
```

All numeric arguments are decimal. The path must name a character device
`/dev/kvmfrN`, not a symlink. OFFSET must be host-page aligned. WIDTH/HEIGHT
are 1..16384 BGRA pixels, PITCH must be a multiple of four and at least
WIDTH*4. The exported byte extent covers the last pixel row and is rounded up
to pages. It is checked against the actual GETSIZE response before export;
no entire-device export is inferred from the maximum image size.

The code uses `syscall(SYS_ioctl)` for GETSIZE because the module returns its
capacity directly as `long`; the libc `ioctl` declaration returns `int`, which
would truncate successful large capacities. A DMA-BUF exported at the supplied
device offset is imported with plane offset zero. BGRA is described by
`DRM_FORMAT_ARGB8888`; a linear modifier is supplied when import-modifiers is
available, otherwise the implicit-layout import is attempted.

The explicit EGL device index selects `EGL_PLATFORM_DEVICE_EXT`. This needs
no compositor or desktop window. Success means the actual `eglCreateImageKHR`
call and image destruction succeeded, not merely that EGL lists an extension.
The probe does not create a GL texture, sample pixels, validate producer fences,
exercise synchronization/reuse, measure latency or prove direct scanout.
Export success and later import failure are reported separately. All owned
image/display/FD resources are released on completion or error.

## Upstream reference and production boundary

The build includes the unmodified external Looking Glass `module/kvmfr.h`
UAPI. It is copyright The Looking Glass Authors, GPL-2.0-or-later, as declared
in that header. No upstream implementation is copied into this probe. The
inspected official-source checkout is
`/tmp/viewflow-lookingglass-reference` at
`cdba29f2f6bcae3ded26369fc231a067cbca3752`:

- `module/kvmfr.h:27-36`: create flags, ABI struct and ioctl numbers.
- `module/kvmfr.c:203-211`: page alignment and device bounds.
- `module/kvmfr.c:288`: GETSIZE returns the backing capacity.
- `client/renderers/EGL/texture_dmabuf.c:340-369`: DMA-BUF image attributes,
  zero plane offset and linear/implicit modifier handling.

Current Viewflow `platform/linux-reverse/shared_mapping.hpp` maps ordinary
shared files and separate slot files; it does not export DMA-BUFs. Its recovery
and reader ownership operations must not run against this independent probe.
`gpu_decoder.cpp` currently provides a CUDA host-memory upload path. Neither
production mechanism is replaced by building this executable. Integrating
KVMFR requires matching host/guest backing and explicit lifetime/completion
handling before importing frames into the real renderer.
# Current-kernel module build evidence (2026-10-09)

The unmodified upstream module at commit
`cdba29f2f6bcae3ded26369fc231a067cbca3752` built with `make -j2` against the
installed `7.2.8-zen1-2-zen` headers. `modinfo` reports matching vermagic and
module version 0.0.12. The build emitted a missing MODULE_DESCRIPTION warning;
compilation/linking completed successfully. Hash and metadata are recorded in
`evidence/6k60-20261008/kvmfr-module-build.json`; the candidate binary is retained
under `build/ivshmem-backup/kvmfr-7.2.8-zen1-2-zen/`.

The module was not installed or loaded, and no `/dev/kvmfr*` existed at the
observation. No GPU import was run. Static creation uses `vmalloc_user(kdev->size)`
in upstream module/kvmfr.c, so startup allocation of four maximum 1 GiB banks
must not be presented as demand-grown backing. Runtime loading and a small
isolated import remain necessary before deployment or performance claims.

# Raw DMA-BUF production candidate: owned 4 MiB validation

2026-10-09. Built the candidate `viewflow_reverse_decoder` and standalone
`platform/linux-reverse/raw_dmabuf_upload_test.cpp`; executed:

```text
/tmp/viewflow-raw-dmabuf-upload-test --run 0
sampled snapshot BGRA swizzle+alpha full bytes=4194304 mismatches=0
slot retained before poll and released after completed GL fence passed
resident_total=4194304 beyond_allowed=0 image_bytes=4194304 allowed_extent=4194304 CPU_source_access=own-pattern-write
```

This path invokes the actual candidate `GpuDecoder::upload()` with
`VIEWFLOW_RAW_DMABUF=1` and asserts `last_upload_raw_dma()`; CPU/CUDA fallback
would fail this test. Input was an owned sealed 1 GiB sparse memfd with only
4 MiB of generated pixels. Real EGL import and external-OES draw copied those
pixels into the existing swizzled raw snapshot texture. A subsequent ordinary
2D sampling pass and complete RGBA readback verified every color/alpha byte.

The test sets culling, empty scissor and disabled color writes before upload,
then checks their restoration. Caller/frame references are released; a weak
slot owner must remain live until the completed GL fence is retired via
`poll_raw_dma()`, then expire. No desktop/window/input/focus action occurred.

The subsequent existing Windows-produced 6K scratch image used the same helper
and snapshot convention, with a PROT_NONE source mapping so the Linux test
cannot read/write source pixels on CPU. Its persisted results are
`dma-memfd-production-helper.log` and `.json`: 84,934,656 compared bytes,
zero mismatches, slot lifetime checks passed, 128 MiB total residency and no
resident tail beyond the two 64 MiB segments. The inherited mode calls the
helper directly rather than allowing a fallback that could access source RAM.
Windows producer completion was separately recorded in
`dma-memfd-6k-windows.log`. This is one completed synthetic frame, not production
stream, scanout, sustained 60 fps or latency acceptance.

## Resource costs to measure before caching

The candidate currently creates an EGLImage, external GL texture and GL fence
for each accepted frame, plus one host list node. Shader, FBO and VAO are reused;
the local snapshot texture is reused at fixed geometry. Descriptor import and
resource creation/destruction may therefore be significant at 60 fps, but this
correctness test contains no isolated timing evidence for their cost.

A later cache should key on stable bank/export ownership plus offset, extent,
pitch, format and modifier; integer FD alone is unsafe because descriptor
numbers are reused. Reusable image/texture ownership may retain the export and
mapping, but must never retain the shared-slot lease after its copy fence ends.
Each in-flight submission must still separately hold the slot lease. Geometry,
new export identity and stream reset need invalidation, and EGL/GL resources
must be deleted with their owning context current after queued sampling drains.
No cache was added in this change.

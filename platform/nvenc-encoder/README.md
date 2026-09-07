# Viewflow NVENC encoder shim

This Linux-only C++20 shim keeps two `h264_nvenc` contexts alive: straight-RGBA
color and a paired full-range grayscale alpha stream. It accepts caller-owned
pixels and frame metadata, returning bounded H.264 Annex-B access units with
the same frame ID, timestamp, and geometry epoch. It does not capture a screen,
create a window, or provide a transport integration.

The alpha stream is deliberately explicit. `Required` emits it for every frame;
`OpaqueMayOmit` may omit it only after checking every input alpha byte is 255,
and marks the result as `OpaqueOmitted`. Alpha is split before any color
conversion/premultiplication. Lossless alpha requests NVENC's lossless tune,
QP 0, High 4:4:4 Predictive, and JPEG/full range. Lossy alpha requires an
explicit bounded-QP `max_quantizer` in 1..51; that is a rate-control bound,
not a claim of a particular per-pixel error bound. After an opaque alpha AU is
omitted, the next alpha frame is forced IDR so it has no dependency on a stream
the receiver never received.

The exposed `StreamDescriptor` identifies color as 8-bit H.264 High and alpha
as 8-bit H.264 High 4:4:4 Predictive, full-range, with alpha in luma and
neutral chroma. A Windows receiver must negotiate/probe a decoder for this
High 4:4:4 stream; Media Foundation hardware H.264 decode support is not
assumed. Do not substitute a lossy alpha mode for the lossless configuration.

Frame IDs must strictly increase; timestamps and geometry epochs may not
regress, and frame IDs/epochs cannot be zero. Once an error occurs after NVENC
has accepted color bytes, the shim fail-closes that encoder instance because a
paired output is no longer certain; recreate it rather than retrying the same
frame. Pre-admission validation failures leave the instance reusable.

Build and run synthetic tests:

```sh
cmake -S platform/nvenc-encoder -B /tmp/viewflow-nvenc-build -DBUILD_TESTING=ON
cmake --build /tmp/viewflow-nvenc-build
ctest --test-dir /tmp/viewflow-nvenc-build --output-on-failure
```

The tests do not initialize NVENC. One manual bounded GPU smoke uses generated
(not captured) pixels at the verified 1556x1300 geometry and software-decodes
the alpha access unit to prove exact luma/chroma recovery:

```sh
/tmp/viewflow-nvenc-build/viewflow-nvenc-encoder-smoke
```

Transport pairing and receiver integration remain pending.

## Prepared GPU atlas composition

`gpu_atlas_compose.cuh` provides a stream-ordered composition primitive for
prepared straight-RGBA device tiles. It validates nonoverlapping placements,
pitch/size arithmetic and output aliases before enqueueing any writes, clears
the active atlas area each frame, and copies color and alpha from the same source
pixel. Row padding is untouched. Caller-owned device buffers must remain valid
until stream completion, including after an error. Empty layouts clear the atlas.

The manual `viewflow-gpu-atlas-compose-test` target (enabled by
`VIEWFLOW_BUILD_GPU_DMABUF_ENCODER=ON`) checks against a CPU pixel oracle, including
tile retirement, source immutability, padded pitches and rejection without writes.
It can also run under `compute-sanitizer --tool memcheck --error-exitcode 1`.
The native C++ `GpuDmabufEncoder::encodeAtlas` entry point imports each DMA-BUF,
prepares its crop and optional shadow independently, retains prepared device
pixels, and calls this primitive before one NVENC submission. The batch deadline
is the minimum of its caller deadline and every tile's original lease deadline.
Imports are cleaned before composition. A full-size single tile uses the original
direct path without extra tile allocations. An empty layout encodes a clear atlas.
The integration test exercises cropped tile colors through H.264 software decode,
exact alpha placement/retirement, overlap rejection and expired tile leases.
The additive `vf_gpu_dmabuf_encoder_encode_atlas_recoverable` C ABI accepts a
size/version checked batch and per-tile original deadlines. Rust exposes it as
`GpuEncoder::encode_atlas_recoverable`, borrowing authenticated `GpuFrame`s and
checking the returned atlas identity, IDR, color bounds and exact alpha shape.
The integration fixture also exercises the C ABI using two independent exported
images and confirms malformed batch headers terminally fail the handle. A manual
Rust owned-empty-atlas test crosses the Rust/native boundary without capturing
the desktop. Transported layout metadata, sender orchestration and receiver
routing remain pending; this is not yet an end-to-end multiwindow application.

## C ABI

`nvenc_encoder_cabi.h` exposes an exception-safe C ABI for the upcoming Rust
wrapper. Every input configuration carries `struct_size` and v1 `version`; all
reserved config bytes must be zero. `vf_nvenc_encoder_submit` borrows RGBA only
for its synchronous call. It writes an initialized, empty `vf_nvenc_output_list`
with opaque output AUs; use `vf_nvenc_output_list_take`, then copy either plane
with `vf_nvenc_output_au_copy_*` and free ownership with the matching destroy
functions. A null destination/capacity zero query sets the required byte count
and returns `VF_NVENC_BUFFER_TOO_SMALL` for a nonempty plane.

The C ABI preserves frame metadata, stream descriptors, and actual IDR flags.
If output ownership allocation fails after NVENC accepts media, it marks that
handle terminally failed rather than risking a later unpaired/referenced frame.
The `viewflow-nvenc-encoder-cabi-smoke` target is a generated-pixel manual GPU
smoke; it is compiled but not run by CTest.

## Optional EGL/OpenGL to CUDA capability probe

`viewflow-nvenc-gl-cuda-interop-probe` is deliberately separate from the
encoder shim and disabled by default. It creates its own 2x2 offscreen EGL
GLES3 pbuffer/context and texture; it neither discovers nor uses a compositor
context, a Wayland window, screen capture, NVENC, or Viewflow transport.

The probe registers that GL texture through CUDA graphics interop, maps it as a
CUDA array, and only then performs a test-only CUDA-to-host copy for an exact
RGBA comparison with distinct non-opaque alpha bytes. Thus a pass proves the
GL-texture-to-CUDA boundary has no `glReadPixels`, PBO map, or CPU frame copy;
it is a prerequisite, not proof of a decorated-window/blur/alpha streaming
pipeline or NVENC input compatibility.

It is an explicit capability gate because the normal build intentionally has
no CUDA or EGL dependency:

```sh
cmake -S platform/nvenc-encoder -B /tmp/viewflow-nvenc-interop-build \
  -DVIEWFLOW_BUILD_NVENC_GL_CUDA_INTEROP_PROBE=ON
cmake --build /tmp/viewflow-nvenc-interop-build --target viewflow-nvenc-gl-cuda-interop-probe
/tmp/viewflow-nvenc-interop-build/viewflow-nvenc-gl-cuda-interop-probe
```

When enabled, configuration fails clearly if CUDA runtime/OpenGL interop
headers or `libcudart` are absent. A runtime failure reports the failed EGL or
CUDA call; notably, GL and CUDA must resolve to compatible GPUs. Do not add it
to CTest: it initializes the installed display and CUDA driver.

## Optional GPU-resident CUDA to NVENC probe

`VIEWFLOW_BUILD_NVENC_GL_CUDA_ENCODE_PROBE=ON` additionally requires `nvcc`.
It builds `viewflow-nvenc-gl-cuda-encode-probe`, a manual prerequisite that
uses an owned EGL/GLES texture, maps it through CUDA graphics interop, copies
the mapped GL array to CUDA device memory, converts RGBA to NV12 in a CUDA
kernel, and submits an `AV_PIX_FMT_CUDA`/`AV_PIX_FMT_NV12` hardware frame to
`h264_nvenc`. Its FFmpeg CUDA device is explicitly initialized from the same
current CUDA primary context as the GL interop resource.

The probe emits three real H.264 Annex-B access units with frame identities
101, 202, and 303 to a temporary `/tmp/viewflow-gl-cuda-nvenc-*.h264` artifact.
It software-decodes that artifact and checks 256×256 BT.601 limited-range YUV
samples against the known input colors within a QP10 tolerance of four per
component, while packet PTS must equal the corresponding identity.
Its independent alpha check uses separate test-only CUDA array readback with
known non-opaque alpha values. H.264/NV12 does **not** encode alpha; this is
only preservation proof for the source interop boundary.

```sh
cmake -S platform/nvenc-encoder -B /tmp/viewflow-nvenc-gpu-encode-build \
  -DVIEWFLOW_BUILD_NVENC_GL_CUDA_ENCODE_PROBE=ON
cmake --build /tmp/viewflow-nvenc-gpu-encode-build --target viewflow-nvenc-gl-cuda-encode-probe
/tmp/viewflow-nvenc-gpu-encode-build/viewflow-nvenc-gl-cuda-encode-probe
```

The default is 256×256. Pass an even test geometry up to 8192×8192 to exercise
the same probe at a relevant physical size, for example:

```sh
/tmp/viewflow-nvenc-gpu-encode-build/viewflow-nvenc-gl-cuda-encode-probe 1936 1732
```

The result reports the mean host elapsed time for its two steady frames. That
measurement includes this probe's synthetic GL upload/finish, CUDA map/copy,
conversion/synchronization, and NVENC packet collection; it is not a
compositor-frame or cross-host latency claim.

It is intentionally not CTest and is not a decorated-window, blur, alpha-video,
or transport implementation. Any unsupported CUDA frame mapping or NVENC
runtime configuration fails the probe rather than reporting a substitute path.

## Optional cross-process DMA-BUF import to CUDA/NVENC gate

When `VIEWFLOW_BUILD_NVENC_GL_CUDA_ENCODE_PROBE=ON`, CMake also builds
`viewflow-dmabuf-cuda-import-probe`. Its producer exports one owned RGBA EGL
texture as DMA-BUF and keeps every exported FD open until its exec'd consumer
has terminated. The consumer imports the FD as a new EGL texture, registers
that imported GL texture with CUDA graphics interop, does the CUDA device copy
and NV12 conversion, then submits an `AV_PIX_FMT_CUDA` frame to NVENC.

```sh
/tmp/viewflow-dmabuf-cuda-build/viewflow-dmabuf-cuda-import-probe
/tmp/viewflow-dmabuf-cuda-build/viewflow-dmabuf-cuda-import-probe 1936 1732
```

This first IPC gate intentionally encodes one frame (PTS 101) containing three
known-color horizontal partitions. It proves the imported-DMA-BUF GL texture is
accepted by CUDA/NVENC; it is not yet the three-frame decoded-YUV/independent
alpha acceptance suite, nor a compositor or HCSF transport implementation.

### Optional EGL DMA-BUF capability probe

```sh
cmake -S platform/nvenc-encoder -B /tmp/viewflow-egl-dmabuf-build \
  -DVIEWFLOW_BUILD_EGL_DMABUF_PROBE=ON
cmake --build /tmp/viewflow-egl-dmabuf-build --target viewflow-egl-dmabuf-probe
/tmp/viewflow-egl-dmabuf-build/viewflow-egl-dmabuf-probe
```

This manual probe owns its EGL context and texture; it never attaches to
Hyprland or changes recording. Driver extension availability and actual export
are checked at runtime. It is disabled by default and not an automatic CTest.
Successful export alone does not establish cross-process import, production
synchronization, or the live window's decoration and alpha processing.

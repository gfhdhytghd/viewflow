# Linux media backends

The Linux source and reverse receiver now have two runtime implementations:

| Backend | Color encoding | Reverse decoding / texture import | Capture and alpha / atlas preparation |
| --- | --- | --- | --- |
| `nvidia` | Existing NVENC, H.264 or AV1 as negotiated | Existing CUDA/NVDEC H.264 or HEVC; CUDA to GLES textures | Existing CUDA pipeline |
| `vaapi` | FFmpeg VA-API hardware H.264 or AV1, when the selected driver supports the codec | VA-API H.264 or HEVC surfaces exported as DRM PRIME and imported into GLES R8 / GR88 textures, retaining plane modifiers | EGL DMA-BUF crop readback, CPU unpremultiply/seam/shadow/atlas processing, NV12 upload to hardware encoding |

VA-API is implemented but **AMD/Intel hardware operation is not validated on the
current development machine**. Its only accessible render node is NVIDIA;
Intel `00:02.0` is bound to `vfio-pci`. Driver initialization, compiler support,
and package presence are not proof of media operation. There is no silent
software color encoding/decoding fallback.

The portable sender is a compatibility implementation with CPU readback and
upload costs, not a zero-copy or 4K60 performance claim. Alpha still uses the
existing lossless side channel and immutable snapshots. The legacy CPU-input
paired-H.264 path uses VA-API color with CPU libx264 for full-range lossless
4:4:4 alpha, when that legacy protocol is requested. Normal compatible/atlas
streams keep their existing raw-alpha side channel instead. No frame/protocol
version or Mac/Windows implementation changes are needed.

## Device selection

The GUI's media settings persist in its existing settings file and are passed
into every new worker and its children. They can be changed while the GUI's
connection is stopped; setting a preference does not restart any external
service. CLI/service users can set these environment variables directly:

```sh
VIEWFLOW_MEDIA_BACKEND=vaapi \
VIEWFLOW_MEDIA_RENDER_NODE=/dev/dri/renderD129 \
/path/to/vf-window-peer ...
```

`VIEWFLOW_MEDIA_BACKEND` accepts `auto`, `nvidia`, or `vaapi`.
`VIEWFLOW_MEDIA_RENDER_NODE` accepts a DRM render-node path, including a stable
`/dev/dri/by-path/...-render` symlink. Device identity is compared by the device
number, not by brand or enumeration index. Automatic selection uses the current
EGL render node when available, or the sole accessible render node. An encoder
with multiple nodes and no current renderer requires an explicit selection.
The selected device's actual encoder/decoder initialization can still fail for
an unsupported codec, resolution, modifier or cross-GPU import.

The NVIDIA capture context is created on the explicit EGL render device; the
CPU-input NVENC path resolves that node's PCI identity to its CUDA ordinal.
NVIDIA reverse texture sharing requires the selected device to match its EGL
renderer. VA-API can use a separate media device only when that device's exported
surfaces can be imported by the receiver's actual EGL renderer.

## Hardware checks

The GUI provides a bounded synthetic-media check, also available as:

```sh
/path/to/viewflow-media-probe --backend vaapi --render-node /dev/dri/renderD129
```

This uses owned offscreen textures and native fences, sends eight H.264 frames
through actual encoding and decoding, imports decoded textures and samples
pixels, and checks alpha and ordinary/stable sparse atlas output. Success is
reported only after all those stages pass. It creates no desktop windows,
captures no desktop content and injects no input. It proves this fixture and
codec on the selected device; it does not prove production capture modifiers,
all codecs/resolutions, mixed-GPU presentation, or cross-device interaction.
The GUI displays successful checks in green and keeps failed/unchecked hardware
states distinct from installed dependencies.

## Build and packaging

The compatibility Cargo feature is still `native-gpu-nvenc`; the new descriptive
alias is `native-gpu-media`. CUDA is optional at build time:

```sh
VIEWFLOW_ENABLE_CUDA=OFF cargo build --features native-gpu-media -p viewflowd
cmake -S platform/linux-media -B build/media -DVIEWFLOW_ENABLE_CUDA=OFF
cmake --build build/media --target viewflow-media-probe
```

For a combined build, the CUDA implementation is an optional
`libviewflow-cuda-encoder.so` loaded only when NVIDIA is selected. Linux reverse
resolves the CUDA driver lazily. Neither the daemon's nor the receiver's ELF
startup dependencies require `libcuda`. The bundle builder rebuilds all native
payloads, copies this module explicitly, and includes its userspace dependency
closure (including libcudart). GPU drivers remain host components. A VA-only
build does not require CUDA headers, nvcc, libcudart or the NVIDIA driver.

The GUI only inventories dependencies and runs the synthetic check. It does
not install system components or use pkexec. The pacman package's mandatory
base dependencies remain glibc and gcc-libs; GPU driver packages are optional
hints, not forced NVIDIA dependencies.

Scheduling deadlines retire obsolete work before hardware submission after
capture reads have completed. A portable frame submitted to hardware is drained
and returned even if it misses its performance target. No new 33 ms connection
cutoff, focus gate or input restriction is introduced.

## Validation on the development host

- Desktop GUI tests: 26 passed, including settings propagation, no live-worker
  mutation, translations and refusing incomplete synthetic-check reports.
- Portable/no-CUDA native build and seven non-hardware encoder tests passed.
- NVIDIA-enabled native encoder tests: eight passed, including actual NVENC
  DMA-BUF/GOP/alpha/atlas integration. All four native sparse modes passed.
- Linux reverse: nine tests passed. A synthetic HEVC stream decoded and imported
  all 60 frames with no GL errors.
- Full H.264 synthetic media check passed on NVIDIA `/dev/dri/renderD128`,
  including shader-sampled luma/chroma and the portable EGL capture readback.
- Portable preparation matched the existing CUDA kernels byte for byte in eight
  flip/seam/shadow/sparse-composition cases.
- VA-API H.264 and HEVC decoding and DRM/EGL import on the NVIDIA VA driver produced all
  60 frames per codec; shader samples matched the red fixture (NV12 81,90,240). The
  NVIDIA EGL RG88 plane convention is handled explicitly. This does not validate
  the AMD/Intel drivers or mixed-GPU imports.
- VA-API on this NVIDIA node correctly failed because its VA driver exposes no
  usable H.264 encode entrypoint. This is not an AMD/Intel test result.

AMD/Intel encode/decode/import, production performance and user-operated
cross-device mouse/keyboard acceptance remain to be run on accessible hardware.

The pre-existing unified-apps Mac helper-count test still fails (7 versus 6);
Mac packaging was not changed for this work. Installed apps and forwarding
services were not replaced or restarted.

API references: [FFmpeg DRM frame descriptors](https://ffmpeg.org/doxygen/trunk/hwcontext__drm_8h_source.html)
and [FFmpeg VA-API export synchronization](https://github.com/FFmpeg/FFmpeg/blob/master/libavutil/hwcontext_vaapi.c).

# Isolated GL-to-CUDA capability, 2026-09-05

The optional `VIEWFLOW_BUILD_NVENC_GL_CUDA_INTEROP_PROBE` target creates its
own 2x2 EGL/GLES pbuffer and texture, uploads known non-opaque RGBA, registers
that texture with CUDA, and verifies exact bytes via a final test-only host
copy. It does not attach to Hyprland, load plugins, change recording behavior,
or transmit a window. Normal encoder builds do not require CUDA/EGL additions.

Agent and root independently ran the built probe successfully; root exit 0:

```text
PASS EGL 1.5; GL vendor=NVIDIA Corporation;
renderer=NVIDIA RTX PRO 6000 Blackwell Workstation Edition/PCIe/SSE2;
CUDA devices=1; exact 2x2 RGBA (including alpha) mapped GL texture -> CUDA array.
```

Executable: `/tmp/viewflow-nvenc-interop-build/viewflow-nvenc-gl-cuda-interop-probe`.
The normal encoder build and two CTests also passed in agent validation.
Root's current workspace library tests passed independently.

This establishes only an interop prerequisite. The current live HCSF path
still reads RGBA back into CPU memory and sends sealed memfds. GPU-resident
capture/encoding, decoration/shadow processing, alpha transport and the actual
two-frame cross-host display requirement remain to be integrated and tested.
An opaque recording-only implementation would not satisfy the window goal.

## GPU hardware-frame encode prerequisite

The separate default-OFF `VIEWFLOW_BUILD_NVENC_GL_CUDA_ENCODE_PROBE` now
submits a CUDA/NV12 hardware frame to NVENC. Root independently ran
`/tmp/viewflow-nvenc-gpu-encode-build/viewflow-nvenc-gl-cuda-encode-probe`
with exit 0. Its artifact is `/tmp/viewflow-gl-cuda-nvenc-HjxP7Q.h264`.

The 256x256 synthetic test emits three Annex-B access units, verifies packet
PTS identities 101/202/303 and decodes the three changing colors, comparing
center Y/U/V samples against BT.601 limited-range expectations within four
levels per component. A separate final readback verifies known non-opaque
alpha bytes exactly. Alpha is **not** carried by the H.264 bitstream.

Between the owned GL texture and the encoder, pixels remain on the GPU:
mapped CUDA array -> device copy -> CUDA NV12 conversion -> AV_PIX_FMT_CUDA
NVENC input. Synthetic texture upload and final verification are host-side;
this is not an end-to-end zero-copy claim. The original 64x64 test was rejected
by NVENC's minimum dimensions, so no capability claim is based on that run.
Root also re-ran the normal encoder's two CTests successfully.

Cross-process export, actual decorated-window processing, full-size timing,
alpha transport and live receiver acceptance remain outstanding.

The probe now accepts optional validated even width/height (test-only bounds
2..8192; this is not a product resolution cap). Root independently ran
1936x1732 successfully: the reported mean for steady frames 202/303 was
2.53554 ms. This includes synthetic GL upload/finish, CUDA map/device copy/
conversion/synchronization and NVENC submission/packet collection. It excludes
real window rendering, decoration repair, alpha transport, networking and
Windows composition, and only samples two steady frames. It is not a latency
percentile or a two-frame end-to-end result. Odd width 1935 was rejected.

## DMA-BUF process boundary

Root built and ran `viewflow-egl-dmabuf-probe` using the default-OFF
`VIEWFLOW_BUILD_EGL_DMABUF_PROBE` option. The parent exported an owned 2x2
RGBA texture, passed its DMA-BUF via SCM_RIGHTS, and a separately exec'd
consumer created a fresh EGL context and imported it. Consumer readback
matched all 16 compiled-in test bytes, including alpha 0/63/127/254. CPU pixel
data was not sent over IPC. The parent kept its texture alive until the child
exited. Both initial and root cleanup-hardened runs exited 0.

Observed export: fourcc `0x34324241`, one plane, modifier
`0x300000000606010`, stride 64, offset 0. Exported handles were marked
close-on-exec so the child's import relied on SCM_RIGHTS rather than inherited
producer descriptors. Rejected receive paths close the received descriptor.

This first process-boundary result used producer `glFinish` for test-only
synchronization. It does not prove explicit-fence operation or CUDA/NVENC
registration of the imported EGL texture; those are separate remaining gates.

The follow-up default path replaced `glFinish` with an exported native fence:
`eglCreateSyncKHR` -> `glFlush` -> `eglDupNativeFenceFDANDROID`. SCM_RIGHTS
carries exactly the DMA-BUF and fence descriptors; the consumer polls the
fence with a five-second bound before import. Root rebuilt and independently
passed the exact RGBA comparison, including a subsequent cleanup correction
for fork/fcntl failures. Both descriptors are close-on-exec in the producer.
Missing native-fence support fails rather than selecting the legacy wait.
This proves the isolated explicit-fence process boundary, not live capture or
the still-pending imported-texture CUDA/NVENC path.

## Imported texture to CUDA/NVENC

Root added a single-access-unit software decoder check to the separate
`viewflow-dmabuf-cuda-import-probe`. The 1936x1732 run exited 0 and produced
`/tmp/viewflow-dmabuf-cuda-nvenc-wai4Au.h264`: three color bands in one frame,
PTS 101, exact sampled source/imported/CUDA alpha, and decoded Y/U/V within
four levels at the center of each band. A standalone verifier accepted that
artifact and rejected the unrelated three-frame solid-color artifact
`/tmp/viewflow-gl-cuda-nvenc-FcO55v.h264` with actual YUV mismatches.

An initial texture-setup variant failed alpha checks before CUDA. Matching the
successful export probe's texture parameters and requesting preserved image
contents restored exact source/imported RGBA. Several parameters changed, so
this is not a single-variable diagnosis of the driver. The explicit preserved
image attribute is required to retain defined existing pixel contents by the
[KHR_image_base contract](https://registry.khronos.org/EGL/extensions/KHR/EGL_KHR_image_base.txt).

This combined encoder probe still uses test-only `glFinish` synchronization;
the separate fence-enabled EGL probe proves the explicit-fence path. Neither
test yet proves their integrated production lifecycle, continuous frame reuse,
render-time decoration repair, orientation/crop, alpha transport or live
cross-host presentation.

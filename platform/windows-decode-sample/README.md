# Windows GPU H.264 sample decode probe

This is a deliberately small execution probe for the inbox
`CLSID_CMSH264DecoderMFT`, not an MFT inventory tool. It creates an Intel
D3D11 video device and Media Foundation DXGI device manager, sends it to the
decoder, submits one Annex-B access unit per input sample, then requires each
output buffer to implement `IMFDXGIBuffer`. A system-memory output is reported
as a failure to establish the GPU presentation boundary.

It takes two directories:

```text
viewflow_windows_decode_sample.exe <color-au-dir> <alpha-au-dir> <expected-alpha.gray>
```

The sample looks for `color-1.h264` through `color-3.h264` and likewise for
`alpha`. It prints negotiated input/output types, each output frame's size,
DXGI format, and whether it was GPU-backed. For alpha, it copies only an
`IMFDXGIBuffer` texture to a staging texture and compares luma against the
provided expected gray bytes when the negotiated format is NV12 or AYUV.

No software output is counted as a hardware/GPU decode success. This does not
implement the application decoder, alpha composition, rendering, or blur.

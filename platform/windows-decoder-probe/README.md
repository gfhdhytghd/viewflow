# Windows H.264 hardware decoder probe

This is a dependency-free native probe. It calls `MFTEnumEx` with
`MFT_ENUM_FLAG_HARDWARE` and an H.264 input type, then reports each decoder's
friendly name, CLSID, D3D11-awareness attribute, and the input/output media
subtypes exposed by the activated transform.

It also creates a D3D11 video device for every DXGI adapter and checks the
standard H.264 VLD decoder profiles against NV12 and packed 4:4:4 formats
(AYUV/Y410/Y416). The D3D11 profile list and format check are capability
evidence, not a decoded High444Predictive sample: D3D11 does not expose a
separate High444Predictive profile GUID, so that profile remains unknown until
a real sample is negotiated and decoded.

The result intentionally reports `h264_profile=unknown`: enumerating an H.264
decoder does not prove that it accepts the High444Predictive profile. That
requires a real sample decode (and, where relevant, checking the negotiated
media type) before claiming support.

Build from a VS x64 developer environment:

```text
cl /nologo /EHsc /std:c++20 decoder_probe.cpp /Fe:decoder_probe.exe
```

The checked-in result from the Windows host is in
`RESULT-2026-09-04.txt`.

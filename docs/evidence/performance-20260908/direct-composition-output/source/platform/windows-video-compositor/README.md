# Windows GPU video compositor foundation

`GpuVideoCompositor` accepts one H.264 High-profile Annex-B access unit and a
separately supplied, tightly packed `RawGray8Alpha` plane bearing the same
nonzero frame identity. It requires a non-software D3D11 device, the inbox MF
H.264 decoder to return `IMFDXGIBuffer` NV12, and planar NV12 shader views.
There is no CPU color path or software fallback.

The decoder texture is sampled directly when it exposes planar NV12 views, or
copied GPU-to-GPU into a shader-bindable NV12 texture. If the adapter rejects
shader-bindable NV12, `ID3D11VideoProcessor` converts the decoder NV12 surface
to BT.709 limited-range BGRA entirely on the GPU, and a pixel shader applies
the uploaded R8 alpha plane. Both paths emit premultiplied
`B8G8R8A8_UNORM`. `CompositedFrame` exposes that same-device texture for a
Composition drawing-surface bridge.

`headless_test.cpp` is deliberately the only readback: it reads output alpha
solely to compare it byte-for-byte with the supplied fixture. It is not part of
the production API.

Build in an x64 VS 2022 Native Tools prompt:

```bat
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
build\Release\viewflow_windows_video_compositor_test.exe C:\path\to\fixture
```

# Windows atlas-region verification — 2026-09-06

Fresh source staging on the previously used Windows VM was verified live via
SSH (`WindowsVM`, `wilf@172.16.105.70`). Existing Visual Studio 2022 BuildTools
MSVC 19.44.35228 compiled both native projects in Release. No installed binary,
service, task or firewall configuration was replaced. No visible window ran.

Windows staging:
`C:\Users\wilf\AppData\Local\Temp\viewflow-atlas-region-20260906-Dmv3DQ`.
Local logs/scripts:
`/tmp/viewflow-atlas-region-20260906.Dmv3DQ`.

Commands (each build uses a separate directory below the staging root):

```text
cmake -S platform/windows-video-compositor -B windows-video-compositor-build -G "Visual Studio 17 2022" -A x64
cmake --build windows-video-compositor-build --config Release --parallel 2
ctest --test-dir windows-video-compositor-build -C Release --output-on-failure --timeout 20
cmake -S platform/windows-composition-preview -B windows-composition-preview-build -G "Visual Studio 17 2022" -A x64
cmake --build windows-composition-preview-build --config Release --parallel 2
ctest --test-dir windows-composition-preview-build -C Release --output-on-failure --timeout 20
```

Results: compositor 2/2 and preview 13/13 passed. The hardware-only D3D11 test
reported `gpu_atlas_region_exact=true` and exited successfully. It creates one
8x8 premultiplied BGRA texture, retains a 3x5 tile at (3,1) without copying the
texture, rejects invalid/nested crops and an overflowing destination, then uses
the production copy helper to copy the tile into a larger target at (1,1).
Test-only readback verifies every BGRA channel plus untouched zero padding.
The test explicitly requests `D3D_DRIVER_TYPE_HARDWARE`, with no WARP fallback.

The preview executable built successfully with the shared copy helper. Its CTest
suite tests parsers, deadlines, recycle/warmup, timer and pointer logic; it does
not open proxy windows. MSBuild emitted MSB8029 warnings about temporary output
directories; this is not a warning-free build claim.

SHA-256 provenance (source hashes matched when read back from Windows):

| Artifact | SHA-256 |
| --- | --- |
| Source archive | `93c68d286795293cdcde17f4de8c6e4d4117eefb25d3753f49c1737cb00426de` |
| `video_compositor.h` | `b2c9502ab279cbbed6192bb01fe01b74ae70d566a6d6faee5ffb8862ff145bb6` |
| Preview `main.cpp` | `1a2687f2cb10673f96b2c271dd71ad828820d7866a4ddf1d112c50a9b8b9fabb` |
| GPU region test EXE | `71f017898b81accdb6a4ee1eade066bef2a4aa9379e08d45c7f535c51571e0a3` |
| Preview EXE | `46598fb12a47d18eb4cc6ca9ad187c757fce6464805d8a8eb9ce9b019129ffdb` |
| Local `build.log` | `936712708da4aacf72f1043f0299a9ee0192e87a70b80e000dd948191fe05980` |
| Local `gpu-ctest.log` | `998bea6e97dc8da93916ba6fc0636b1d933fabd6c60bfd0aed6853ae86496692` |

This proves the native GPU region-copy boundary, not decode-to-multi-window
dispatch, physical presentation, latency, input routing or present receipts.
Those remain required integration and acceptance work.

# Mac → Linux: toward 3840×2160, 60 fps, 60 ms

The final HEVC source-stage benchmark exceeds 60 fps. This is not a measured
60 ms capture-to-display result: capture scheduling, network delivery and actual
Wayland presentation/scanout are outside that benchmark.

## Final measurements

`pipeline-4k.mm` precomputes four changing checkerboard images, then exercises
the real pixel split, exact alpha encoding, VideoToolbox submission and ordered
completion/packing with at most two frames in flight. It discards ten warm-up
frames and checks all delivered frames with the Mac hardware decoder afterward.
Input generation and that validation decode are outside the timed source stage.
The normal Mac window stream and other desktop workloads remained running.

| Full source-stage run | Delivered fps | Dropped frames | Median source ms | P95 source ms |
| --- | ---: | ---: | ---: | ---: |
| H.264 (`pipeline-4k-rate`) | 44.02 | 0 | 46.58 | 47.44 |
| HEVC A (`pipeline-4k-final-a`) | 62.48 | 0 | 34.85 | 36.70 |
| HEVC B (`pipeline-4k-final-b`) | 62.26 | 0 | 34.63 | 36.82 |

Each final HEVC measurement contains 170 warmed frames; all 180 generated
frames decode in order. Percentiles use the sorted floor index. These are short
synthetic runs, not an all-content or sustained thermal guarantee.

The Linux offscreen GPU probe decoded and uploaded all 180 HEVC frames at
3840×2160 with GL error 0. It synchronizes upload completion with `glFinish`:
median 1.91 ms, P95 3.34 ms (`linux-decode.log`). It does not present a window.
These separate stage percentiles must not be added and called an end-to-end P95.

The live Safari body is 2418×1650 pixels, 1209×825 logical. Before removing
capture shadows, it occupied a 2930×2162 encoded canvas and used 2,323,686 alpha
bytes per frame. Afterward alpha uses 2,576 bytes and periodic output backpressure
is effectively gone. Typical final live preparation/alpha/encoding is around
2/0.1/7 ms. Actual content changes at about 49–50 fps in the sampled scene;
cadence statistics show 60 ticks/s with most remaining skips marked unchanged.
This live scene is not the 4K benchmark and does not prove a 60 fps display rate.

## Implementation

- A bounded two-frame encoder pipeline overlaps preparation and hardware work;
  a separate ordered completion worker packs and enqueues results.
- Pixel inputs remain retained through native callbacks, including resize.
  Frames already encoded wait for output capacity instead of being discarded
  and breaking prediction references. Disconnect wakes that wait before drain.
- One Metal operation extracts exact alpha and creates straight opaque sRGB
  color. ScreenCaptureKit requests sRGB explicitly; other input color spaces
  retain the Core Image path. GPU failure has the existing CPU/CI fallback.
- Capture excludes native shadow and its 512-pixel padding. Linux continues
  using the Hyprland shadow decoration, with the same logical window/body size.
- Cadence keeps absolute deadlines and skips missed slots without a catch-up
  queue. Logs distinguish idle content, preparation, encoder and output pressure.
- Current Mac→Linux runtime is HEVC at 60 fps. Bitrate has the prior 24 Mbps
  floor and scales at 0.125 bits/pixel/frame, capped at 80 Mbps: 62.208 Mbps at
  4K60. The earlier fixed 24 Mbps low-latency stress run dropped complex frames.
- HEVC bootstrap/small-window canvases are padded to at least 144×144. Actual
  NVDEC rejected the former 64-pixel bootstrap height; the 144×144 probe now
  decodes all 180 frames. Tile and body geometry remain independent of padding.

## Validation and deployment

Strict native arm64 Release build passed. GPU-enabled and GPU-disabled codec,
color, all-alpha-byte and orientation tests passed. Async tests cover both
codecs, retained buffers, ordering, resize and a final static frame without an
extra submission/flush. Portable tests cover cadence drift, worker ordering and
output shutdown under a full pipe. Linux GPU probes pass at 144×144 and 4K.
Screenshots verified the final HEVC window, title bar, body and logical size.
No mouse/keyboard test input or focus command was issued.

Final installed and live helper SHA-256:
`627d9fdb5202135ac8e57c665220a2d9e6338cc38312db3b872a7e374d677b8d`.
The app passed deep strict signature verification. Source PID 43192 and Linux
presenter PID 2520827 were verified after the final switch with stable HEVC
delivery. Subsequently the native window returned to the Mac and its source
closed normally; it was not moved back by this task.

Mac build/rollback artifacts are in `~/viewflow-mac-pipeline-20260912/`.
`candidate-r11.app` is final; `pre-r11.app` is the prior bundle. To roll back
HEVC on the current NVIDIA receiver, restore H.264 in the source config as well:
the earlier helper's 64-pixel HEVC bootstrap is incompatible with this decoder.
The saved connection profile now has 60 fps and HEVC for the Linux destination.
The old app's cached profile recreated a 30 fps worker during the final check,
so the app was relaunched in the background to load the saved configuration for
future workers as well. Its graceful shutdown drained children but did not exit
within 20 seconds; the remaining GUI process was terminated before relaunch.
Final app PID 44959, Windows receiver PID 44968 and HID relay PID 45021 were
observed running afterward. Physical input acceptance remains user-operated.

Early `4k-final-serial-*`/`4k-final-pipeline-*` files use `benchmark-4k.mm`, whose
main thread also generates each input and consumes completions. They helped
locate costs but are superseded by the source-like `pipeline-4k.mm` results above.
The NV12 conversion and shorter pipe-poll experiments were not retained.

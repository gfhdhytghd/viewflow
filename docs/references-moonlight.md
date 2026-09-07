# Moonlight Qt implementation notes

Source inspected: `moonlight-qt` commit
`1da6ff434c7a4afa206d3215a5559ccc4c9df3c5` (2026-08-26). Its
`moonlight-common-c` dependency is pinned to
`874ac9548f1bd6f095ef2b435c42cdde460e7821`, but that submodule is not populated
in the inspected checkout. Therefore, this note distinguishes code visible in
Moonlight Qt from transport, packet recovery, input serialization, and host
control implemented by `moonlight-common-c` or the GameStream-compatible host.

## Reuse boundary

| Area | Useful client-side pattern | GameStream-specific dependency |
| --- | --- | --- |
| Decode | Probe real decoders/renderers, prefer hardware zero-copy, keep decode and render queues bounded, drop stale frames | `DECODE_UNIT`, `LiWaitForNextVideoFrame()`, `LiCompleteVideoFrame()`, IDR/RFI requests, codec-capability negotiation |
| Input | SDL capture lifecycle, event coalescing, coordinate mapping, stuck-key release | Every `LiSend*()` call, host feature flags, controller feedback callbacks, remote-input key/IV |
| Fullscreen | SDL desktop/exclusive/windowed state machine and display-mode selection | None for local window management; decoder recreation requests an IDR through GameStream |
| HDR | Test the actual decoder + renderer path, propagate color metadata, select 10-bit formats | Host codec-mode advertisement, asynchronous HDR metadata/mode callbacks, stream profile negotiation |
| Alpha | Local overlays can alpha-blend | The streamed video has no alpha plane or alpha-capable negotiated format |
| Statistics | Timestamp each local stage, count frame-number gaps, expose a rolling overlay | RTT, host encode latency, connection status, receive/reassembly timestamps come from `moonlight-common-c`/GameStream |

## Low-latency decode and stale-frame dropping

### Decoder and renderer selection

- `app/streaming/session.cpp` — `Session::chooseDecoder()`,
  `Session::getDecoderAvailability()`, `Session::populateDecoderProperties()`:
  probe the real codec/renderer pair before starting the stream. The populated
  callback capabilities are fed into stream negotiation. A pull renderer sets
  `m_VideoCallbacks.submitDecodeUnit = nullptr`; the decoder then pulls frames
  itself.
- `app/streaming/video/ffmpeg.cpp` — `FFmpegVideoDecoder::initialize()` tries,
  in order, explicitly requested decoder hints, top-tier FFmpeg hardware
  acceleration, nonstandard hardware decoders with zero-copy output, copy-back
  hardware paths, then software decode. `completeInitialization()` sends an
  embedded test frame through `avcodec_send_packet()` / `avcodec_receive_frame()`
  and calls the renderer's `testRenderFrame()` before accepting the pair.
- `app/streaming/video/ffmpeg.cpp` —
  `FFmpegVideoDecoder::getDecoderCapabilities()` always advertises
  `CAPABILITY_PULL_RENDERER`; software decode additionally advertises up to four
  slices and HEVC/AV1 reference-frame invalidation support. These capability
  bits affect what the GameStream host sends, so they are not a generic decoder
  API.
- `app/streaming/video/ffmpeg-renderers/renderer.h` — `IFFmpegRenderer` separates
  backend decode surfaces from frontend presentation, including renderer
  attributes such as `FULLSCREEN_ONLY`, `HDR_SUPPORT`, `NO_BUFFERING`, and
  `FORCE_PACING`. This interface separation is reusable.

### Pull/decode/render flow

1. `FFmpegVideoDecoder::decoderThreadProc()` in
   `app/streaming/video/ffmpeg.cpp` blocks in `LiWaitForNextVideoFrame()`, sends
   the assembled access unit to FFmpeg, and reports `DR_OK`/`DR_NEED_IDR` via
   `LiCompleteVideoFrame()`.
2. `FFmpegVideoDecoder::submitDecodeUnit()` rejects a non-IDR first frame,
   linearizes the `DECODE_UNIT` buffer list, calls `avcodec_send_packet()`, and
   queues only a metadata copy in `m_FrameInfoQueue`.
3. `decoderThreadProc()` drains `avcodec_receive_frame()`, timestamps the decoded
   frame in `AVFrame::pkt_dts`, attaches presentation time in `AVFrame::pts`, and
   submits it to `Pacer::submitFrame()`.
4. `app/streaming/video/ffmpeg-renderers/pacer/pacer.cpp` — `Pacer` owns separate
   pacing and render queues. Its V-sync thread is time-critical, its render
   thread is high priority, and `renderOnMainThread()` supports renderers whose
   graphics API must run on the main thread.

The portable lesson is bounded latest-frame presentation, not Moonlight's
GameStream pull calls. `MAX_QUEUED_FRAMES` is three per queue. `Pacer::handleVsync()`
and `Pacer::renderFrame()` use a rolling 500 ms queue history and discard older
frames when sustained backlog develops. `Pacer::dropFrameForEnqueue()` also
evicts the oldest frame at the hard queue cap. One important accounting caveat:
that hard-cap eviction does **not** increment `pacerDroppedFrames`; only the
catch-up loops do. Viewflow should count every eviction at the single place
that enforces latest-frame semantics.

Recovery is protocol-coupled. Twenty consecutive FFmpeg failures push
`SDL_RENDER_DEVICE_RESET`; decode errors return `DR_NEED_IDR` or call
`LiRequestIdrFrame()`. Recreating the renderer after resize/device loss also
calls `LiRequestIdrFrame()`. Viewflow needs equivalent keyframe recovery in its
own media protocol rather than copying these functions.

## Input path

- `app/streaming/session.cpp` — the SDL event loop dispatches keyboard, mouse,
  wheel, controller axis/button/sensor/touchpad/battery/device, joystick arrival,
  and touchscreen events to `SdlInputHandler`.
- `app/streaming/input/input.cpp` — `setCaptureActive()`,
  `updateKeyboardGrabState()`, `updatePointerRegionLock()`, `notifyFocusLost()`,
  and `raiseAllKeys()` manage relative/absolute pointer capture, compositor/system
  key grab, confinement, and stuck-key prevention. These local policies are
  reusable, though Viewflow should keep them behind its existing input-lease
  owner rather than in the media decoder.
- `app/streaming/input/mouse.cpp` — `handleMouseMotionEvent()` coalesces all
  pending SDL motion events before sending one update. Absolute mode maps the
  cursor into the letterboxed video rectangle; relative mode sums deltas.
  `handleMouseWheelEvent()` uses high-resolution horizontal and vertical wheel
  events where SDL provides precise values.
- `app/streaming/input/keyboard.cpp` — `handleKeyEvent()` suppresses SDL repeats,
  maps SDL scan codes to Windows virtual-key values, tracks pressed keys, and
  preserves selected non-normalized keys. `performSpecialKeyCombo()` reserves
  local control chords for ungrab, fullscreen, stats, mouse mode, minimize, and
  clipboard text.
- `app/streaming/input/gamepad.cpp` — `sendGamepadState()` merges controllers in
  single-controller mode; other handlers forward sensors, touchpads, battery,
  capabilities, and arrival/removal. Host-to-client callbacks in
  `Session::k_ConnCallbacks` return rumble, trigger rumble, motion reporting,
  LEDs, and adaptive-trigger state through SDL main-thread events.
- `app/streaming/input/abstouch.cpp` — `handleAbsoluteFingerEvent()` checks
  `LI_FF_PEN_TOUCH_EVENTS`; capable hosts receive native pen/touch packets and
  older hosts get mouse emulation.

All transport calls in these files (`LiSendKeyboardEvent2()`,
`LiSendMouseMoveEvent()`, `LiSendMousePositionEvent()`, scroll variants,
`LiSendMultiControllerEvent()`, `LiSendTouchEvent()`, `LiSendPenEvent()`, etc.)
serialize GameStream remote-input messages. The AES key/IV generated in
`Session::initialize()` and placed in `STREAM_CONFIGURATION` are also part of
that protocol. They cannot be copied into Viewflow without implementing the
corresponding host parser, capability negotiation, ordering, and encryption.

## Fullscreen and display changes

- `app/settings/streamingpreferences.h` defines three modes:
  `WM_FULLSCREEN` (exclusive), `WM_FULLSCREEN_DESKTOP` (borderless desktop),
  and `WM_WINDOWED`.
- `app/settings/streamingpreferences.cpp` — `StreamingPreferences::reload()`
  recommends desktop fullscreen on macOS and normally on Wayland. Wayland does
  not support modesetting; a slow-GPU exception allows real fullscreen to use
  `wp_viewporter` scaling.
- `app/streaming/session.cpp` maps the preference to
  `SDL_WINDOW_FULLSCREEN` or `SDL_WINDOW_FULLSCREEN_DESKTOP`.
  `Session::updateOptimalWindowDisplayMode()` selects a compatible refresh rate
  for exclusive fullscreen. `Session::toggleFullscreen()` destroys the decoder
  first on Windows/macOS to avoid D3D9 style fights and an Apple Silicon
  `AVSampleBufferDisplayLayer` deadlock, toggles SDL fullscreen, then refreshes
  keyboard and pointer grabs.
- In the SDL event loop, size/display changes are first offered through
  `IVideoDecoder::notifyWindowChanged()`. A refresh-rate change forces decoder
  recreation so `Pacer` attaches to the new display. V-sync is disabled when
  stream FPS exceeds display Hz by more than five.

Local fullscreen state is reusable and independent of GameStream. The only
protocol dependency in this path is recovery after renderer recreation: Moonlight
asks the host for a new IDR frame.

## HDR and alpha limits

### HDR

- `Session::getDecoderInfo()` probes HEVC Main10 and AV1 Main10 through the
  actual hardware/software renderer path. `FFmpegVideoDecoder::isHdrSupported()`
  requires `RENDERER_ATTRIBUTE_HDR_SUPPORT`; 10-bit decode alone is insufficient.
- `Session::validateLaunch()` intersects client formats with
  `NvComputer::serverCodecModeSupport`, rejects H.264 for HDR, and requires a
  common HEVC Main10 or AV1 Main10 profile. These server flags and format masks
  are GameStream/Sunshine negotiation, not portable capability detection.
- `Session::clSetHdrMode()` forwards the host HDR-mode callback to the renderer.
  `FFmpegVideoDecoder::decoderThreadProc()` prefers bitstream side data but can
  synthesize FFmpeg mastering-display and content-light side data from
  `LiGetHdrMetadata()`. It forces BT.2020 primaries and SMPTE ST 2084 PQ while
  `LiGetCurrentHostDisplayHdrMode()` is true.
- HDR-capable frontend examples include D3D11VA
  (`ffmpeg-renderers/d3d11va.cpp`), DRM/KMS (`drm.cpp`), libplacebo Vulkan
  (`plvk.cpp`, including tone mapping to SDR), and VideoToolbox Metal or
  `AVSampleBufferDisplayLayer` (`vt_metal.mm`, `vt_avsamplelayer.mm`). The basic
  SDL renderer explicitly rejects 10-bit video in `SdlRenderer::initialize()`.

Viewflow can reuse the rule "probe decode + render + output together" and the
FFmpeg color-metadata fallback. It cannot reuse host HDR state or metadata calls
unless its sender carries equivalent frame-synchronized metadata. Moonlight
itself notes that the asynchronous HDR message is less reliable than metadata
embedded in the bitstream.

### Alpha

Moonlight provides no alpha-preserving video path:

- Negotiated stream profiles are H.264, HEVC, or AV1 in YUV 4:2:0/4:4:4 and
  8/10-bit variants; there is no alpha-bearing profile.
- `SdlRenderer::isPixelFormatSupported()` accepts YUV420P/YUVJ420P/NV12/NV21
  for the normal path; CPU conversion uses `AV_PIX_FMT_BGR0`, not BGRA.
- `SdlRenderer::prepareToRender()` clears to opaque black and
  `SdlRenderer::renderFrame()` sets `SDL_BLENDMODE_NONE` on the video texture.
- The D3D11 and EGL YUV shaders return alpha `1.0` (`d3d11_yuv420_pixel.hlsl`,
  `d3d11_yuv444_pixel_end.hlsli`, `egl_nv12.frag`). D3D11 explicitly disables
  blending for video while enabling it for overlays.
- Renderer alpha support seen elsewhere is for the local text/status overlay,
  not transmitted video content.

Consequently, Moonlight is useful as an opaque low-latency color-plane
reference only. Viewflow's separate color and alpha planes, atomic `frame_id`,
and transparent proxy composition require independent protocol, decoder, and
GPU-composition work; they cannot be derived from Moonlight's stream format.

## Network and performance statistics

`app/streaming/video/decoder.h` defines `VIDEO_STATS`: received/decoded/rendered/
total frames, network and pacer drops, host processing latency, reassembly,
decode, pacing, render times, RTT/variance, rates, and video Mbps.

The visible collection path is:

- `FFmpegVideoDecoder::submitDecodeUnit()` treats gaps in
  `DECODE_UNIT::frameNumber` as network drops; records host processing latency;
  computes reassembly time from `receiveTimeUs` to `enqueueTimeUs`; and adds
  encoded access-unit bytes to `BandwidthTracker`.
- `FFmpegVideoDecoder::decoderThreadProc()` measures decode latency from
  `enqueueTimeUs` through successful `avcodec_receive_frame()`.
- `Pacer::renderFrame()` measures queue/pacing time and renderer/V-sync time.
- `FFmpegVideoDecoder::addVideoStats()` derives FPS and obtains RTT plus
  variance through `LiGetEstimatedRttInfo()`.
- `FFmpegVideoDecoder::stringifyVideoStats()` formats a roughly two-second
  rolling debug overlay: incoming/decoded/rendered FPS, host processing latency,
  network-drop and jitter-drop percentages, RTT, decode time, queue delay, and
  render time. `submitDecodeUnit()` rotates windows about once per second.
- `app/streaming/bandwidth.cpp` — `BandwidthTracker` uses 250 ms buckets over a
  ten-second ring. Average Mbps uses only the newest 25% of completed buckets;
  peak scans the entire window. Bitrate display is compile-time guarded by
  `DISPLAY_BITRATE`.
- `Session::clConnectionStatusUpdate()` receives coarse `CONN_STATUS_POOR` /
  `CONN_STATUS_OKAY` callbacks and controls the slow-connection overlay.
  `clStageFailed()` and `clConnectionTerminated()` translate protocol stages to
  port flags and call `LiTestClientConnectivity()` against Moonlight's test
  server.

Portable measurements are the local byte buckets, frame-gap count, and stage
timestamps. The following values are not locally inferred by Moonlight Qt and
must not be copied as if they were generic transport metrics:

- `DECODE_UNIT::receiveTimeUs`, `enqueueTimeUs`, frame ordering, reassembly, FEC,
  and loss recovery are produced by `moonlight-common-c`.
- RTT/variance comes from its ENet control connection, not the video datagram
  path.
- `frameHostProcessingLatency` and HDR metadata are GameStream RTP/control
  metadata emitted by the host.
- coarse connection-quality callbacks and port-stage mappings are GameStream
  policy.

For Viewflow, instrument its QUIC datagram receive/reassembly path directly,
keep network loss separate from deliberate latest-frame eviction, and report
transport RTT together with the media-path stage timestamps. Do not label pacer
drops as "network jitter" unless the measured cause is actually arrival jitter;
Moonlight's overlay uses that wording for any pacer backlog drop.

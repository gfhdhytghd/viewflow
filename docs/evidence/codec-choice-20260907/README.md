# AV1 selection on the desktop pair, 2026-09-07

Source: NVIDIA RTX PRO 6000 Blackwell Workstation Edition, driver 610.57.04.
Receiver: Intel Graphics on Core Ultra 7 265K, Windows.

| Codec | NVENC host send/receive p50 / p95 (ms) | D3D11 decode plus GPU completion p50 / p95 (ms) |
|---|---:|---:|
| H264 | 3.204 / 3.427 | 0.703 / 14.789 |
| HEVC | 2.873 / 3.139 | 1.820 / 2.682 |
| AV1 | 1.573 / 1.828 | 0.560 / 4.081 |

AV1 is selected for this pair: lowest median on both sides; the two alternatives
remain benchmark comparisons, not an assertion of universal codec performance.
AV1 has a wider decode tail than HEVC in this run. These separate stage timings
must not be described as measured end-to-end latency.

Encoding used 4096x2048 NV12, 16 synthetic moving text/grid frames uploaded to
CUDA before timing, 330 serial submissions, first 30 excluded. Settings match
the live P1/ULL, no B frames, no lookahead, constant QP 10 setup. QP numbers across
codecs do not prove matched perceptual quality. This probe excludes source
fences/import, RGBA conversion, alpha readback/compression, network and display.

The decode probe reads the exact encoded packet fixtures, forces D3D11 output
with no software fallback, confirms NV12 textures and waits on a D3D11 GPU event
after each output. Each codec produced all 330 frames on GPU. The first 30 are
excluded from latency percentiles. Its synthetic unpaced serial workload is not
a physical presentation or user-input test.

The inbox Media Foundation H264 decoder also decoded all 330 frames; HEVC and
AV1 had no registered MFT candidates. An attempt to install AV1 using WinGet
stalled contacting the Store API; its command-line proxy option required an
administrator-enabled setting. No system proxy setting was changed and no
Store extension was installed. The product therefore uses application-local
FFmpeg/D3D11VA for AV1.

FFmpeg shared LGPL build source:
https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.1-latest-win64-lgpl-shared-8.1.zip
The runtime package's LICENSE.txt is deployed with its DLLs. This URL is a moving
release pointer; record the archive digest below for this run.

Reproduction: build encode.cpp with a C++20 compiler and pkg-config libavcodec,
libavutil; arguments are encoder_name width height output.vfcb. Transfer the
three .vfcb fixtures to Windows. CMake builds decode_ffmpeg.cpp against the
shared distribution include/lib folders, and its bin folder must be on PATH.
Run decode_ffmpeg.exe h264/hevc/av1 corresponding_fixture.vfcb. decode.cpp is the
separate Media Foundation comparison probe. Raw logs are in this directory.
96eca80835f4000c43df261e70a8546a4b0f63fdf2c658f351e4f392483b0dfe  /tmp/viewflow-codec-bench/ffmpeg-win64.zip

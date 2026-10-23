# Dedicated CUVID decoder buffered-output check

Installed FFmpeg n9.0.1 / libavcodec 63.1.101 exposes both the native HEVC decoder with CUDA hardware acceleration and hevc_cuvid. An isolated decoder probe selects either one, keeping CUDA-only format, AV_CODEC_FLAG_LOW_DELAY, hardware-device context and NV12/GLES upload checks. Only the decoder probe target was built and run, on an EGL pbuffer; no application window or input event is created.

| Input | Native HEVC + NVDEC output | hevc_cuvid output |
|---|---:|---:|
| 120 complete access units | 120 | 119 |
| One complete initial access unit | 1 | 0 |

The same 6K stream is used in both arms. The one-frame probe exits 7 in both cases because its original utility requires at least 59 outputs; its explicit units/decoded counts distinguish immediate output from buffering. GL errors are zero. The dedicated decoder therefore cannot directly replace the current implementation for static first/last updates, and is rejected before full-route testing. Finishing a file with EOS is not equivalent to a continuing desktop stream.

[FFmpeg n9.0.1 source](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/libavcodec/cuviddec.c) sets parser display delay to zero under LOW_DELAY, but does not pass CUVID_PKT_ENDOFPICTURE with each packet. The observed one-frame buffering is consistent with waiting for a following access-unit boundary. No production decoder or protocol was changed.

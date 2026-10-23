# Windows 6K source: encoder setting 0

Private candidate, 2026-09-09. WGC → HEVC and exact alpha → local file; this measurement excludes QUIC and live Linux presentation. Full 6144×3456 source; asynchronous alpha readback, encoder input readiness checked before atlas construction, CPU alpha storage reused. The installed reverse executable remains unchanged.

The actual device is Intel Graphics (8086:7d67), using Intel Hardware H265 Encoder MFT. `CODECAPI_AVEncCommonQualityVsSpeed` readback is 0; common low latency is enabled and B frames are zero. Property and activation evidence is in `method/effective-encoder.txt`; event timing is preserved in `runs/source.log`. The mean-bitrate property readback is not interpreted as the actual stream bitrate; the configured output media type requests 24 Mbps.

Decoded 904 of 904 emitted frames, with valid markers, exact opaque alpha, and zero marker regressions. After five seconds of warmup: **30.370 distinct frames/s**, versus 30.861 output packets/s. Duplicates are excluded from the former. Fixture pre-draw to local output median: 118.744 ms. These fixture results include application/compositor queuing; see the later waitable-fixture [full transport comparison](../transport/README.md).

All 35 source files matched the remote build input hashes. Process exit was normal with no watchdog. Installed binary hash and main task state matched before/after. This is performance qualification of a synthetic opaque fixture, not broad desktop or physical input acceptance.

Microsoft documents the [quality/speed control](https://learn.microsoft.com/en-us/windows/win32/codecapi/avenccommonqualityvsspeed-property) as a speed-versus-quality preference, so broader image quality is a separate concern. The matched-grid [quality comparison](../quality/README.md) checks this candidate on the measured content.

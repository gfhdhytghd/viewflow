# Windows 6K source: encoder setting 50

Private candidate, 2026-09-09. WGC → HEVC and exact alpha → local file; this measurement excludes QUIC and live Linux presentation. Full 6144×3456 source; asynchronous alpha readback, encoder input readiness checked before atlas construction, CPU alpha storage reused. The installed reverse executable remains unchanged.

The actual device is Intel Graphics (8086:7d67), using Intel Hardware H265 Encoder MFT. `CODECAPI_AVEncCommonQualityVsSpeed` readback is 50; common low latency is enabled and B frames are zero. Property and activation evidence is in `method/effective-encoder.txt`; event timing is preserved in `runs/source.log`. The mean-bitrate property readback is not interpreted as the actual stream bitrate; the configured output media type requests 24 Mbps.

Decoded 769 of 769 emitted frames, with valid markers, exact opaque alpha, and zero marker regressions. After five seconds of warmup: **26.328 distinct frames/s**, versus 26.328 output packets/s. Duplicates are excluded from the former. Fixture pre-draw to local output median: 120.678 ms. These fixture results include application/compositor queuing; see the later waitable-fixture [full transport comparison](../transport/README.md).

All 35 source files matched the remote build input hashes. Process exit was normal with no watchdog. Installed binary hash and main task state matched before/after. This is performance qualification of a synthetic opaque fixture, not broad desktop or physical input acceptance.

Microsoft documents the [quality/speed control](https://learn.microsoft.com/en-us/windows/win32/codecapi/avenccommonqualityvsspeed-property) as a speed-versus-quality preference, so broader image quality is a separate concern. The matched-grid [quality comparison](../quality/README.md) checks this candidate on the measured content.

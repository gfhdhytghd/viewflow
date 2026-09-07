# Local NVENC availability probe

2026-09-04, no screen capture or output media file. GPU inventory returned
NVIDIA RTX PRO 6000 Blackwell Workstation Edition, driver610.57.04.
Installed pkg-config versions: libavcodec63.1.101, libavutil61.1.101,
libavformat63.1.101.

Executed one bounded synthetic probe:

```sh
ffmpeg -hide_banner -loglevel info -f lavfi -i testsrc2=size=1556x1300:rate=60 -frames:v 60 -an -c:v h264_nvenc -preset p1 -tune ull -bf 0 -rc-lookahead 0 -f null -
```

Exit0;60frames encoded, reported327KiB encoded video,0.29s elapsed/3.35x.
Default bitrate2Mbps yielded final reportedq40.0. This establishes actual
hardware encoder availability only: not adequate desktop text quality, alpha
preservation, per-frame latency, GPU-resident capture, network or decode proof.
The production adapter must negotiate quality/format and preserve paired
alpha instead of inheriting these probe defaults.

## Persistent shim GPU verification

Root independently configured a Release build of `platform/nvenc-encoder`
under `/tmp/viewflow-nvenc-root-review`, built it, and ran CTest (1/1 passed)
plus the synthetic GPU smoke. The first smoke failed because it required
FFmpeg's YUV444P enum, while full-range decode returned the YUVJ444P alias.
After recognizing both full-range 4:4:4 formats, the same pixel/chroma equality
checks remained mandatory.

Rebuilt smoke exited0: three frames in one encoder session, including an
explicitly opaque omitted alpha frame and a subsequent alpha IDR. Reported
first encoded pair sizes: color89,374 bytes, alpha123,118 bytes. Alpha was
software-decoded and compared byte-for-byte, including neutral U/V samples.
This is not a Windows hardware-decoder test, content-quality acceptance,
continuous screen capture, or end-to-end latency measurement.

## Rust ownership and capture adapter verification

The Linux `native-nvenc` feature now links the persistent C ABI. Root ran:

```sh
cargo test -p viewflowd --features native-nvenc nvenc_runtime::tests -- --include-ignored
cargo test -p viewflowd --features native-nvenc hyprcapture_encoder::tests -- --include-ignored
cargo clippy -p viewflowd --features native-nvenc --lib -- -D warnings
```

Results: 3 ownership/ABI tests and 2 capture-adapter tests passed, including
actual synthetic GPU execution; feature Clippy passed. An initial 64x64
ownership fixture was rejected by this GPU's minimum dimensions; the verified
fixture uses 256x256, not a new protocol resolution restriction.

Ownership tests preserve three frames' identity/timestamps and paired output.
A forced Rust output-copy bound failure after native acceptance poisons the
encoder, rejecting subsequent submit and drain calls. The adapter resize test
uses 256x256 then 512x256 and requires nonempty paired IDR output. It does not
exercise the live HyprCapture socket, Windows decode/composition, or network
delivery. These results therefore do not establish the two-frame target.

## Encoded transport integration

Root also ran the ignored GPU integration tests `nvenc_media_gpu` and
`nvenc_quic_gpu` with `native-nvenc`. Both passed. They use three real encoded
pairs rather than mocked Annex-B payloads. The former covers datagram
encode/decode with reversed chunk order; the latter sends descriptors and
frame metadata on a reliable mTLS QUIC stream and encoded planes as actual
QUIC datagrams. Reassembled payloads are byte-identical and pass CodecSession
admission. Receive timestamps are synthetic for completeness testing, so these
tests cannot establish latency or Windows decoder compatibility.

The reproducible `nvenc_decode_fixture` example emits separate color/alpha
access units and expected alpha samples without capturing a desktop. The
256x256, three-frame fixture's alpha stream was identified by ffprobe as H.264
High 4:4:4 Predictive, full-range yuvj444p. Linux software decode of the aggregate
alpha stream compared byte-for-byte with its 196608 expected samples. Windows
hardware sample decoding remains a separate pending gate.

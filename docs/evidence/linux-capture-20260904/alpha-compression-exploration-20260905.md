# Lossless alpha exploration (not a wire-format change)

The current GPU extent is 1936 x 1732: raw 8-bit alpha is 3,353,152 bytes.
The observed roughly 216 KiB VFAR payload cannot be classified as raw merely
from its encoded size. VFAR mode must be read from its validated header.

A read-only Node/zlib experiment extracted alpha from the existing historical
`dolphin-window-1950.vfbg` fixture (1556 x 1300, raw alpha 2,022,800 bytes).
Fixture SHA-256: `5a9f4d17f3c9f429428a49fcf27eb37fbf55a0dd0abef7c96ef43e12b4286547`.
Header, stride and exact input length were checked; each output was inflated
with an exact decoded-size ceiling and compared byte-for-byte to the source.
Ten synchronous encodes per level, sorted sample index 5:

| Raw DEFLATE level | Encoded bytes | Encode median ms |
| --- | ---: | ---: |
| 1 | 73,327 | 6.946 |
| 3 | 63,902 | 7.030 |
| 6 | 51,094 | 21.139 |

This is neither today's GPU sample nor a native Windows decoder benchmark.
It establishes only that an independent lossless entropy codec is worth
comparing against VFAR RLE. It does not authorize replacing VFAR v1 bytes
under an unchanged descriptor, prove a latency win, or justify alpha loss.
Any future mode needs explicit version/codec support, bounded decoder tests,
native receiver compatibility, and actual end-to-end timing. No wire format
or production capture was changed by this experiment.

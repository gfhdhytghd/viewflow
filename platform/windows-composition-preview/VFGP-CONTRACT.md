# VFGP v1/v2: GPU presenter pipe, compressed color plus alpha frames

`viewflow_windows_composition_preview --stdin-compressed` reads a sequence of
complete VFGP records from **one anonymous stdin pipe**. There is no stream
preamble, no recovery scan, and no implicit frame format. A malformed or
truncated record is terminal: the preview exits with an error rather than
attempting to resynchronize potentially mismatched color and alpha.

Each integer is unsigned, big-endian. Each record starts with this fixed 40-byte
header, followed immediately by `color_au_bytes` H.264 bytes and then the
version-selected alpha payload.

| Offset | Size | Field | Required v1 value |
| --- | ---: | --- | --- |
| 0 | 8 | magic | ASCII `VFGP`, then `01 00 00 00` (v1) or `02 00 00 00` (v2) |
| 8 | 4 | header_bytes | `40` |
| 12 | 4 | payload_bytes | `color_au_bytes + alpha_bytes` |
| 16 | 8 | frame_identity | nonzero; strictly greater than the preceding record |
| 24 | 4 | width | nonzero decoded/display width |
| 28 | 4 | height | nonzero decoded/display height |
| 32 | 4 | color_au_bytes | nonzero Annex-B H.264 access unit length |
| 36 | 4 | alpha_bytes | v1: exactly `width * height`; v2: complete VFAR blob byte length |

The fixed header is deliberately versioned through the magic. Both versions
accept only a 40-byte header. A future version needs a new magic/version and an
explicit implementation; writers must not append fields under either magic.

## Version 1 alpha

V1 places exactly `width * height` raw Gray8 samples after the color AU. It is
kept for backwards compatibility.

## Version 2 alpha: VFAR v1

V2's `alpha_bytes` is the byte length of one complete VFAR v1 blob after the
color AU. The parser strictly decodes it to the same raw Gray8 samples supplied
to the GPU compositor; v2 does not alter alpha shader semantics.

| VFAR offset | Size | Field | Required value |
| --- | ---: | --- | --- |
| 0 | 4 | magic | ASCII `VFAR` |
| 4 | 1 | version | `1` |
| 5 | 1 | mode | `0` raw or `1` RLE |
| 6 | 2 | reserved | zero |
| 8 | 4 | width | exactly outer VFGP width |
| 12 | 4 | height | exactly outer VFGP height |
| 16 | 8 | decoded_bytes | exactly `width * height` |
| 24 | variable | coded payload | raw samples or hybrid RLE stream |

Raw mode must contain exactly `decoded_bytes` after its 24-byte header. RLE
mode uses one control byte per run: the low seven bits encode `run_length - 1`;
a clear control is followed by that many literal bytes, and a set high bit is
followed by one repeated byte. Runs are 1 through 128 samples. Decoding must
produce exactly `decoded_bytes`, without truncation, overflow, or trailing
coded bytes.

The preview's `--max-frame-bytes` resource limit defaults to 16 MiB but is
explicitly configurable, including to a value above the roughly 21 MiB needed
by a tightly packed 6K alpha plane. It verifies every addition/multiplication
before allocation and permits only dimensions whose tightly packed alpha plane
fits the selected limit. `alpha_bytes` is one Gray8 value per
pixel, row-major, no stride or padding. It is uploaded as R8 unchanged; it is
not H.264, downsampled, filtered, or reconstructed. In v2 both the complete
outer record and decoded alpha plane are independently bounded by this limit;
a small RLE payload cannot bypass the decoded-plane limit.

`frame_identity` is an application identity, not a Media Foundation timestamp.
The native decoder maps it to its own monotonic timestamps internally, then
requires the decoded output timestamp to map back to the pending identity and
the decoded NV12 dimensions to equal this record's width and height. This makes
color/alpha mixups terminal failures.

Writers should send a single complete Annex-B access unit per VFGP record. The
preview drains decoder output after each record, keeps only bounded decoder
reorder state, and does not queue arbitrary producer input on the UI thread.
At clean stdin EOF it commands the decoder to drain, presents all delayed
matched frames, then exits; partial records remain terminal errors.

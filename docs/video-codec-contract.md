# Video codec contract v1

This is an additive, reliable-session contract for compressed window media. It
does not change the existing `VFMD` datagram header, and it does not retire the
`VFBG` raw fallback.

## Configuration and frame state

Before a sender emits a compressed plane, both peers exchange and accept one
fixed-size `CodecDescriptor` (`VFCD`, 36 bytes) on a reliable control path. It
selects the codec, color/alpha role, coded dimensions, colorimetry, alpha
interpretation, geometry epoch, and nonzero decoder configuration generation.
Unknown enums, reserved bytes, truncation, and extensions are rejected.
Wire dimensions are nonzero but deliberately have no protocol resolution cap.
The caller/backend applies `CodecResourceLimits` after decode with checked luma
sample and decoded-byte calculations; it may reject a shape based on its real
allocation or hardware limits. H.264 dimensions are even because the defined
color contract is NV12.

Each encoded access unit has separately encoded `FrameCodecMetadata` (`VFCF`,
16 bytes). Its nonzero configuration generation must equal the accepted
descriptor. Its `keyframe` bit describes that one access unit; it is not a
property of the session descriptor. `frame_id` and `geometry_epoch` continue
to come from the existing `VFMD` datagram and must match the descriptor's
geometry epoch.

This module defines codec metadata only. Negotiation, reliable control message
assignment, encoder invocation, decoder invocation, and `VFMD` extensions are
intentionally out of scope for this version.

## Supported contracts

| Codec | Plane | Format | Interpretation |
| --- | --- | --- | --- |
| `RawBgra` | color | premultiplied BGRA8 / sRGB | embedded premultiplied alpha |
| `H264` | color | NV12 / BT.709 limited | straight color with paired external alpha |
| `H264` | alpha | YUV444P / full-range alpha luma | luma is alpha; chroma is neutral |
| `LosslessAlpha` | alpha | Gray8 / full-range alpha | `VFAR` independent intra-frame lossless alpha |

H.264 has no interoperable alpha channel. A transparent decorated window
therefore uses matched H.264 color and YUV444P alpha-carrier planes with the same
`frame_id`, geometry epoch, and configuration generation. The receiver waits
for the existing atomic color/alpha admission, decodes both, and premultiplies
the decoded straight color by decoded alpha exactly once in composition.

When a backend cannot produce the H.264 YUV444P alpha carrier (for example a
native encoder rejects that profile), it may pair H.264/NV12 color with the
explicit `LosslessAlpha`/Gray8 alpha descriptor. `LosslessAlpha` is not a color
fallback: it is a full-resolution, straight, 8-bit alpha plane only, with
`AlphaFullRange` and `AlphaPlane` interpretation required. The decoder restores
exact alpha bytes before the same one-time composition premultiplication.

`LosslessAlpha` payloads use `VFAR` version 1. Its 24-byte header carries magic,
version, raw-or-RLE mode, zero reserved bytes, coded width/height, and the
checked `width * height` decoded-byte count. RLE tokens are either literals or
repeated 1–128 byte runs; each frame is independent. The sender chooses raw
mode whenever RLE is equal to or larger than raw samples, so losslessness never
depends on compression winning. A decoder checks encoded, dimensions, luma, and
decoded-byte caller limits before allocating RLE output; it rejects bad magic,
version, reserved bits, inconsistent lengths, truncated/overflowing runs, and
trailing bytes. `VFAR` is carried as the existing alpha `VFMD` payload—there is
no `VFMD` header extension.

The captured full decorated framebuffer remains the proxy texture; this
contract does not substitute a destination-native titlebar or make decoration
pixels source-input targets. A new geometry epoch or decoder configuration
requires a new descriptor/configuration generation and an independently
decodable keyframe before presentation resumes.

## Session admission

`CodecSession` is an additive backend-facing gate. It atomically accepts an
H.264 color/NV12 descriptor paired with either H.264 alpha/YUV444P or
`LosslessAlpha`/Gray8, with matching coded dimensions, geometry epoch, and
configuration generation. It checks the two decoded surfaces against one
caller-provided combined byte budget before mutating state. A rejected pair
leaves the previous active configuration and frame watermark intact.

The default `AlphaPlanePolicy::Required` rejects any omitted alpha plane.
`OpaqueMayOmit` is an explicit policy for a known-opaque frame only; it does
not change descriptor negotiation. Color and alpha report independent keyframe
bits. On first configuration acceptance or configuration change, both planes
must report a keyframe for the same `frame_id`. After an allowed opaque
omission, alpha must resume with an alpha IDR/keyframe; this alpha-only recovery
does not make the color frame a paired recovery boundary.

One `CodecSession` locks to the first successfully admitted window ID. For a
paired frame it requires equal window IDs, frame IDs, geometry epoch/config
generation through the descriptors, and source-submission timestamps. A newer
configuration generation cannot regress the active geometry epoch. Rejected
pairs do not consume the valid same-frame retry.

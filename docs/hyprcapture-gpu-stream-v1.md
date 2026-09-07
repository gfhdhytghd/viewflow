# HCGF v1 GPU frame metadata (integration in progress)

This is a new local GPU transport, not a reinterpretation of HCSF v1 sealed
CPU memfds and not a change to the cross-host media protocol. The initial
format describes one ABGR8888 DMA-BUF plane and a native completion fence.
Other image formats require explicit later negotiation; unsupported formats
must not be silently treated as RGBA.

The base metadata is exactly 232 bytes, with big-endian integers and IEEE-754
doubles. A captured Wayland input binding may append the 88-byte HCGI extension
below in the same seqpacket (320 bytes total). Two SCM_RIGHTS descriptors
accompany the entire packet in order: image, then fence.
The receiver authenticates the expected compositor PID and UID. The producer
authenticates its same-UID receiver on the private session socket. Producer
single-slot export and receiver ownership components are implemented and
tested; native encoder/runtime integration and live presentation are pending.

## Optional HCGI source-input geometry

This local-only extension is not a remote authorization grant. It is frozen
before rendering alongside the HCGF geometry, and checked after renderer re-entry.
The source stream retains the exact window and surface objects until retirement.
Object tokens must not be forwarded as cross-host window identities.

| Extension offset | Field |
| --- | --- |
| 0 | `HCGI` magic |
| 4, 6 | u16 version 1, u16 length 88 |
| 8, 16, 24 | u64 nonzero window token, surface token, PID (1..INT32_MAX) |
| 32, 40, 48, 56 | f64 rendered content x, y, width, height in desktop coordinates |
| 64, 72 | f64 native surface logical width, height |
| 80 | u64 reserved zero |

All geometry is finite and extents are positive. Rendered and native sizes are
distinct; input mapping must account for their ratio as well as decoration
offsets. The original capture sequence/epoch and FDs bind the adjacent extension;
it must never be paired with a separately received frame. HCGR is unchanged.
Receivers accept exactly 232 or 320 bytes, reject malformed extensions, and
close received FDs on failure. A 232-byte frame remains valid for video but
does not establish an input binding. Older receivers reject the extended packet;
update the Linux receiver before loading the updated capture plugin. XWayland
currently emits no input extension and still needs its own input implementation.

## Base HCGF layout

| Offset | Field |
| --- | --- |
| 0 | `HCGF` magic (4 bytes) |
| 4, 6 | u16 version 1, u16 header length 232 |
| 8, 16, 24 | u64 nonzero sequence, original capture monotonic ns, geometry epoch |
| 32, 40, 48, 56 | f64 logical x, y, width, height |
| 64, 68 | u32 full image width, height |
| 72, 76 | u32 DRM fourcc `0x34324241`, byte stride |
| 80, 88 | u64 opaque modifier, byte offset |
| 96, 100, 104, 108 | u32 crop x, y, width, height |
| 112, 116 | u32 flags, reserved zero |
| 120..215 | Twelve shadow doubles, below |
| 216 | u32 shadow power |
| 220..223 | Shadow R, G, B, A bytes |
| 224, 228 | u32 sharp (0/1), reserved zero |

Flags: bit 0 means premultiplied source and is required in v1; bit 1 reverses
rows within the crop; bit 2 enables the shadow snapshot. Unknown bits fail.
Logical position/size are separate from physical image/crop dimensions.
Crop rows use source-memory ordering; consumers must translate the producer's
GL readback crop/origin explicitly, not infer it from window position.

Shadow doubles, in order: left, top, width, height, cutout left, cutout top,
cutout width, cutout height, range, rounding, window rounding, rounding power.
All describe post-crop, top-down pixel coordinates; cutout coordinates are
relative to the shadow origin, as in the existing CPU implementation. The
producer freezes these values with the render's timestamp and geometry.
Disabled shadow has all bytes 120..231 zero. Enabled shadow uses finite values,
positive extents/range, nonnegative roundings, rounding power 1..10 and integer
shadow power 1..4. Zero shadow alpha means no repair, matching the CPU path.

Validation also requires positive dimensions, finite logical geometry,
positive logical width/height, checked crop bounds, stride at least four bytes
per image pixel, and stride/offset representable by EGL's signed attributes.
Do not apply memfd seals or linear-file size assumptions to a tiled DMA-BUF.
Import support, maximum device allocation and actual descriptor validity are
additional native-runtime checks, not proven by metadata validation.

## Required buffer lifecycle before activation

- Producer submits render work and exports a native fence using `glFlush`,
  not a blocking render-thread `glFinish`.
- Keep one exported source allocation immutable until the exact sequence and
  geometry epoch are released. New frames are skipped while that slot is owned;
  they must not queue or overwrite the exported image.
- Receiver waits for the fence within the original frame deadline, imports,
  processes and copies the frame into receiver-owned GPU storage. A release
  is permitted only after GPU reads of the exported source have completed.
- Release messages use the HCGR codec below and must match the outstanding
  identity; event-loop handling is not yet implemented.
- On disconnect or uncertain release, retire the source allocation rather
  than reuse it. Imported references keep the old backing storage alive;
  reconnect must allocate a fresh source framebuffer.
- Close all received handles on every rejection/drop. Resize retires the old
  allocation and changes the epoch; it cannot mutate a consumer-owned frame.

After crop/orientation conversion, preserve top-seam repair, unpremultiplication
and shadow repair in that order. Pair the color and lossless alpha outputs
under the original frame identity. No step may renew its capture timestamp.
This transport must stay opt-in and separate from the user's recording path.

## HCGR release record

Exactly 32 bytes with no ancillary descriptors: `HCGR`, u16 version 1, u16
length 32, u64 nonzero frame sequence at offset 8, u64 nonzero geometry epoch
at offset 16, and eight zero reserved bytes at offset 24. All integers are
big-endian. A syntactically valid record does not authorize arbitrary reuse:
both identities must equal the one outstanding source allocation. Old,
duplicate or mismatched releases must never free a different allocation.
The Rust codec exists; sender/receiver runtime wiring remains pending.

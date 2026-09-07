# Local decorated-window stream v1 (implementation in progress)

This is local compositor IPC, not the Viewflow network protocol. The current
one-shot artifact API remains diagnostic only: measured capture latency alone
is 188–208 ms for a small window.

The proposed persistent path uses an authenticated Unix `SOCK_SEQPACKET`
connection. Each message carries exactly 96 metadata bytes and one SCM_RIGHTS
FD. Pixels are in a sealed memfd, never in the socket packet. The receiver
requires the selected compositor PID and UID, not merely any same-user peer.
Reject truncated messages, unknown ancillary records and extra/missing FDs;
close every received FD even on rejection.

All integers and IEEE-754 doubles are big-endian:

| Offset | Type | Field |
| --- | --- | --- |
| 0 | 4 bytes | HCSF |
| 4 | u16 | Version 1 |
| 6 | u16 | Header length 96 |
| 8 | u64 | Nonzero sequence |
| 16 | u64 | Capture CLOCK_MONOTONIC nanoseconds |
| 24 | u64 | Nonzero geometry epoch |
| 32, 40, 48, 56 | f64 | Logical x, y, width, height |
| 64, 68, 72 | u32 | Pixel width, height, stride |
| 76 | u32 | Format 1: straight RGBA8, top-down |
| 80 | u64 | Payload length |
| 88 | u64 | Reserved zero |

The pixel payload is tightly packed (`stride = width * 4`), with exact FD
length `stride * height`, bounded by the receiver's byte budget. Require
F_SEAL_WRITE, F_SEAL_GROW, F_SEAL_SHRINK and F_SEAL_SEAL before any read.
Positional reads must ignore the open-file-description offset shared with the
sender. Geometry must be finite and dimensions positive; logical and pixel
dimensions are deliberately distinct.

Timestamp and geometry belong to the exact submitted GPU readback slot.
Mapping an older PBO must not attach the latest request's time or geometry.
Translate CLOCK_MONOTONIC to the transport session's clock origin by preserving
age; reject future times and captures predating that session instead of
clamping them to now. Compositor production, memfd sealing and socket sending
must not introduce an unbounded FIFO of stale frames.

Implemented in Rust: header decode, sealed FD import, clock-origin conversion,
exact-peer seqpacket listener/receiver, sequence/geometry lineage, in-place
premultiplication, and explicit start/stop session management. The live-stream
probe reports capture-to-import age (including conversion), not display latency.

The HyprCapture candidate now includes a dedicated fenced PBO path, a bounded
background sender, and start/stop timer integration. A test candidate has been
loaded and exercised in the running compositor; see
`evidence/linux-capture-20260904/live-stream-latency.md` and
`evidence/linux-capture-20260904/gpu-composition-pipe.md` for bounded results.
Integration review found and corrected first-use FBO
reset, per-frame socket closure, and `/dev/shm` listener validation problems.
Source/build and isolated IPC tests do not establish live capture, resize
correctness, destination appearance, or the two-frame latency requirement.

The candidate also uses full decorated-window framebuffer dimensions when an
unrotated window exceeds its source output. Hyprland's fake-render entry resets
the viewport to monitor dimensions, so this stream-only path overrides the
viewport and export projection after entry; allocating a larger FBO alone was
insufficient. Readback bounds are checked before GL calls. Oversized windows
on transformed outputs remain unsupported: the producer notifies and ends the
session instead of silently cropping or waiting forever. The live decorated
Dolphin diagnostic does not establish the oversized/rotated-window case.
Existing recording behavior is not intentionally changed.

The current persistent transport is still CPU RGBA in sealed memfds. Separate
GL/CUDA/NVENC capability probes are not a GPU HCSF transport implementation;
see `evidence/linux-capture-20260904/gl-cuda-capability.md`. Continuous fresh
Windows presentation within the two-frame budget remains unverified.

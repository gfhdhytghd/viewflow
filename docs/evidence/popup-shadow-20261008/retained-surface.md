# Retain the last received pixels outside the current resident region

2026-10-08: after confirming the popup shadow fix, the user requested that
resource-saving regions keep their final snapshot instead of turning clear.

## Change

The receiver previously returned transparent color outside the current resident
rectangle, and generated its input region from that same incomplete alpha.
Each Windows/Linux receiver proxy now owns a persistent RGBA GPU framebuffer
and retained per-window alpha. Incoming resident pixels replace the matching
area; missing pixels do not modify it. Actual transparent pixels still replace
old opaque pixels, with blending disabled. The production shader discards
out-of-resident fragments; a matching scissor limits the GPU update workload.

The saved image is updated even before the first Wayland configure, so a full
first frame is not lost when a partial frame arrives during mapping. Empty
updates do not upload the atlas again for this window. A metadata-only new
window allocates no full-size snapshot before receiving any pixels. A resize
preserves the top-left source overlap and initializes newly added area to
transparent; pixels never received cannot be reconstructed. Snapshot storage
is released with the proxy. Source window closure/removal still closes it.

Input regions and popup-shadow contour hints use retained alpha, preventing
stale visible pixels from becoming click-through merely because they were not
retransmitted. Framebuffer/alpha storage uses actual source-body dimensions,
not the 16K protocol maximum. Cost is one RGBA GPU image plus one CPU alpha byte
per body pixel (in addition to the existing live frame/decoder), not a history
of frames. The wire format, Windows source and resident request policy are
unchanged by this patch.

## Verification

- Added an offscreen EGL test using the exact production vertex/fragment
  shaders on NVIDIA RTX PRO 6000 Blackwell. It compares every RGBA pixel and
  corresponding retained alpha across full, partial, empty and transparent
  updates; enlargement/shrinkage; nonzero body offsets; and final framebuffer
  presentation. A 16K metadata-only fixture confirms no initial alpha allocation.
- The test caught and corrected GL bottom-left versus source top-left overlap
  preservation during resize. Production GPU and CPU snapshots now agree.
- Linux build and CTest 11/11 passed; build warning/error scan empty.
- Deployed `~/.local/lib/viewflow/ivshmem/viewflow_linux_reverse`; previous
  executable saved as `.before-retained-surface`. Restarted only the receiver
  service. Live logs show NVIDIA presentation and IVSHMEM BGRA restored.
- No mouse/keyboard/focus tests injected. User visual acceptance is pending.

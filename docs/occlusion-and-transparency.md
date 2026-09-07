# Occlusion, transparency, and bounded atlas storage

Status: design, not implemented. Current forward and reverse senders pack whole
window rectangles. The forward sender pauses publications that cannot fit; it
does not yet reclaim the pixels hidden by other windows. Clearing those pixels
would reduce encoded bytes but would not reclaim atlas allocations.

## Required representation

Keep full native window geometry, stacking, input regions, and window lifetime
separate from a list of visible image patches. A patch carries source window ID,
capture revision, source pixel rectangle, atlas rectangle, and effective alpha.
The receiver reconstructs each native proxy from patches referencing shared GPU
storage. Merely adding patch metadata while retaining full per-window backing
textures would leave a second source of memory pressure unresolved.

Use a physical-pixel grid (initially 128 by 128, with smaller boundary patches)
for visibility decisions and allocation. Pack only needed patches. Keep padded
NV12 chroma boundaries outside each patch's exact content and alpha bounds.
Compute visibility on the GPU and return compact tile occupancy decisions to
the CPU, rather than downloading every window's color or alpha image for a
CPU scan.

## Transparency rules

Walk effective source stacking from front to back. A pixel of an upper layer
can eliminate a lower layer only when its effective alpha is exactly opaque.
Effective alpha includes window opacity, decorations, corner masks, and
animation opacity, not merely the application's buffer alpha.

A partially transparent pixel keeps the lower pixels that contribute to its
composition. Fully transparent source pixels do not need their own color data.
Background blur additionally retains the required sampling halo. Do not infer
opaque coverage solely from a window's rectangle or native style flags.

Do not flatten every remote window into one desktop screenshot: local windows
must be able to interleave with native remote proxies. Flattening is valid only
for a known contiguous stacking group with no independently composited local
layer between its members.

## Reveal and repair

Visibility changes and their patch set use one scene revision. Resizing,
reordering, moving, and alpha changes invalidate the affected coverage region.
Newly exposed pixels receive priority over ordinary interior damage. Publish a
new patch mapping only when its associated pixels are resident; retain the
previous valid patch set while its replacement arrives. A cached hidden patch
may be displayed briefly during repair, but must not be mislabeled as newly
captured content. Input still uses the correct native window and geometry.

## Resource accounting

Budget capture buffers, encoder inputs, encoded records, decoder surfaces,
patch caches, and proxy backings independently. Opaque coverage bounds the
visible image area approximately by the receiving desktop area. Many full-screen
translucent layers can still require multiple desktop areas; no occlusion
algorithm removes that worst case while preserving independent composition.
Use a fixed resident patch budget, evict hidden patches first, prioritize exposed
patches, and schedule bounded atlas pages when required. Resource pressure must
not terminate unrelated proxies or the paired connection.

## Acceptance evidence

- Overlap two opaque windows: resident transmitted area approaches their visible
  union, while both retain native geometry and can be raised independently.
- Repeat with per-pixel alpha, global opacity, rounded corners, shadows, and blur:
  compare composition with the local source and ensure required underlay remains.
- Reveal moving and changing hidden content: no absent backing texture, black
  rectangle, or stale patch mapping may be exposed.
- Resize, reorder, close, and reconnect under a deliberately small memory budget:
  allocations remain bounded and the session recovers without returning whole
  windows to another screen.
- Report capture-to-display latency and sustained visible-frame rate on real
  moving content; empty-desktop or repeated cached frames do not prove 60 FPS.

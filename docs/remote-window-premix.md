# Remote window composition and visible-region transport

The desktop receiver must preserve one independently focusable and movable
Windows proxy for each remote application window. Local clicks take effect
immediately; source stacking updates acknowledge that local choice asynchronously.
Microsoft RAIL uses a local window for each server window:
https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdperp/485e6f6d-2401-4a9c-9330-46454f0c5aba

## Current behavior and measured bottleneck

The source packs full captured window surfaces into a shared atlas. Color uses
AV1 temporal compression, so an encoded frame does not necessarily transmit every
pixel. Alpha uses lossless RLE and remains a separate full-atlas plane. Recent
Windows samples show static color access units near 150 bytes while alpha is
roughly 245 KB; with two windows visible, alpha grew to roughly 529 KB and color
to 368 KB during interaction. These are observed samples, not percentile results.
The current 5120x2560 atlas accommodates the observed 2434x1642 and approximately
2498x1588 surfaces; this capacity increase is separate from transport optimization.

## Proposed precomposition contract

The receiver reports the visible region and actual z-order of each proxy,
including interleaving local Windows windows. The source computes region ownership
for that exact composition revision. Fully opaque pixels in higher remote windows
can eliminate updates to covered pixels in lower windows. Transparent overlapping
pixels can be precomposed only within a contiguous group of remote windows with no
interleaving local window. Independent alpha must be preserved at each boundary
where the local desktop or a local application contributes to the final image.

The transport retains window IDs, geometry, activation, and input routing as
independent metadata. Shared visible regions may reference one encoded surface;
proxy clip regions specify which portions contribute. Fully covered regions retain
cache entries without receiving repeated updates. A local raise or move invalidates
visibility immediately, requests newly exposed regions, and continues displaying
the existing cached image until those regions arrive. It must never pause or retire
the input stream merely because region content is late.

## Reviewable implementation stages

1. Record per-window capture area, visible area, opaque covered area, color bytes,
   alpha bytes, and exposure-to-update latency. Preserve the existing full surface
   fallback while collecting actual overlap savings.
2. Add receiver visibility revision feedback and source region planning. Regions
   are bounded rectangles and carry stable window ownership. Test local-window
   interleaving, transparent terminals, Snap, minimize, click-to-raise, and exposure.
3. Add encoded shared region references and region clip metadata with capability
   negotiation. Exposed regions receive an independent refresh. Reuse unchanged
   alpha data by explicit content reference, not by pretending stale input/media
   identities are current.
4. Enable precomposition only after image comparison and user-operated interaction
   tests confirm the same visual stacking and input behavior as full surfaces.

Status: design and source inspection completed. Region planning, visibility
feedback, shared-region wire support, and precomposition are not implemented yet.
Current fixes address focus release, queue ownership during input cancellation,
local activation versus delayed source z-order, and atlas capacity.

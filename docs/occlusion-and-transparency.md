# Occlusion, viewport clipping, and transparent precomposition

Implemented for the Hyprland-to-Windows forward atlas. The reverse pipeline
uses a different wire format and does not yet use this patch representation.

The source JSON accepts `"occlusion": "opaque"` (default), `"prerender"`, or
`"off"`. The paired launcher exposes the same setting as
`--occlusion opaque|prerender|off`. Both the Rust receiver and the Windows native
presenter must support sparse patches; capability checks reject older peers
before publication.

## What occupies the atlas

Window geometry, stacking, input ownership, and lifetime are separate from
resident pixel patches. Sources are split on a shared physical 128-pixel grid,
with exact smaller patches at window and viewport boundaries. GPU alpha
classification examines the prepared RGBA pixels, including repaired shadows;
only compact cell summaries return to the CPU. No color image is downloaded
for visibility decisions.

Fully transparent cells consume no atlas slots. In `opaque` mode, a front cell
removes a lower cell only when its alpha is exactly opaque and it completely
covers that lower cell. Partial coverage, unknown stacking, different capture
scales, and fractional grid placement conservatively retain independent
layers. Native style flags are not evidence of opacity.

The configured remote desktop viewport clips residency in source coordinates.
After scrolling a layout, a completely off-viewport window retains its metadata
but has no resident patches. A partially visible window keeps only its visible
source pixels; fractional pixel boundaries round outward. Returning into view
restores patches in the next completed frame. This also applies when stacking
is unknown. Ordinary viewport departure does not mean the window was closed.

Windows proxies display cropped sprites referencing shared atlas surfaces.
They do not allocate a full texture for each window. The atlas uses two shared
composition surfaces so new pixels can be staged before changing bindings.

## Transparency option

`opaque` preserves independent transparent layers and retains a 256-capture-pixel
underlay halo near mixed-alpha cells for receiver backdrop blur. This halo is
conservative at ordinary matching scales, not a proof for arbitrary blur and
cross-display scaling combinations.

`prerender` additionally composites visible remote layers bottom-to-top when
they have exactly the same cell footprint, and sends the resulting patch on
the top window. Different boundary footprints remain independent. This saves
space under transparent overlaps, at the cost of independent local-window
interleaving and potentially different backdrop-blur results. Movement can
briefly display the previous composition while the next frame arrives. Remaining
alpha still participates in native composition. Use `opaque` when independent
composition is more important than these additional savings.

Patch mapping changes require a new scene revision and paired color/alpha
keyframes. A receiver never retags old atlas pixels with a new patch mapping.
Hidden and revealed patch sets are committed with their completed frame.

## Capacity and limits

Sparse startup warms the codec with an empty canvas rather than allocating the
sum of enrolled window rectangles. Live growth accounts for the largest source
preparation dimensions and required patch slots, up to the negotiated canvas
limit. If slots are exhausted at that limit, topmost visible patches take
priority; other patches are omitted while window metadata and input remain.
A single capture exceeding the maximum supported dimensions is still withheld.
The canvas does not automatically shrink after pixels become hidden.

These savings apply to atlas residency and receiver window backings. Source
capture and RGBA preparation still use full window buffers. Grid padding,
transparent layers, blur underlay, codec surfaces, and double buffering also
consume resources. This is not an unlimited-window or fixed-frame-rate claim.

## Verification

Hardware checks on 2026-09-07 used owned textures, without desktop input:

- GPU alpha classification, opaque rejection, transparent source-over,
  reveal/clear behavior, and grow/retry ownership passed.
- The two-layer 256x256 fixture occupied 131,072 pixels in `opaque` mode and
  65,536 pixels in `prerender` mode. Both modes passed fully off-screen,
  partially visible, and fully restored residency checks on the same encoder.
- Windows composition pixel readback verified source crop coordinates, colors,
  removal without stale pixels, and zero per-window full-size surface backings.
- Protocol and parser tests cover sparse patch validation and fragmented input.

These checks establish the tested behavior, not 8K full-motion throughput.

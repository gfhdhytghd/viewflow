# Sparse atlas tile seam correction, 2026-09-09

The user clarified that the artifact was a narrow gap between tiles. The earlier GPU surface retirement change alone did not establish that this gap was corrected.

An offscreen Windows Composition capture oracle renders the production sparse scene against a continuous texture reference. It captures an application-created visual only, with no desktop capture, visible window, focus change, or mouse/keyboard injection. Linear filtering read transparent atlas padding when fractional scaling placed a tile boundary between physical pixels. Changing BorderMode did not eliminate the seam. NearestNeighbor filtering did: the diagnostic comparison covers opaque and half-alpha content, four scales, and quarter-pixel translation. The final production-default oracle uses four packed quadrants and reports zero horizontal/vertical seam pixels in all eight cases.

The production shared sparse surface brush now selects NearestNeighbor. Native 1:1 pixels are unchanged; fractional resizing uses sharper nearest-neighbor sampling and may look more pixelated. All 35 regular Windows tests and the eight offscreen pixel cases passed. The offscreen test requires an interactive user's Composition environment, so it is a separate explicit target rather than a session-0 CTest.

Presenter DD91381853B6F1E1770933E15CAC36C5B19BD68E777DD7E3EC3B025B1AE23A00 was installed and is subsequently superseded by the cross-display fix. Live physical seam acceptance remains user-operated. The subsequent cross-display failure had a separate desktop movement ACK timeout and is recorded in ../win-cross-display-20260909/.

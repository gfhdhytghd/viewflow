# Forward sparse atlas verification, 2026-09-07

Scope: Hyprland-to-Windows. No mouse/keyboard injection or focus-changing tests.
The existing reverse binaries were retained during deployment.

## Checks

- Linux library run: 607 passed, 9 ignored, one new startup fixture initially
  failed because it kept the old tiny decoded-byte allowance. After giving the
  fixture the actual 256 MiB allowance and eight-window limit, the focused
  startup test passed. No production change was needed for that fixture fix.
- Two viewport tests passed: fully outside/touching boundary, partial visibility,
  scroll-back restoration, fractional outward rounding, and signed extremes.
- Native GPU probes passed exact alpha classification and transparent
  source-over, resize/retry ownership, and off-screen/partial/restored residency
  on the same encoder. The opaque two-layer fixture stores 131,072 pixels;
  transparent precomposition stores 65,536. A zero-width viewport region leaves
  every atlas alpha byte zero.
- Windows native suite: 29 passed. The separate interactive-session composition
  probe reported correct display colors and source crops, hidden/reveal mapping,
  independent visuals, and zero per-window full-sized pixel backings.
- Both release binaries built successfully.

## Deployment and observation

The active Linux service uses
`/home/wilf/.local/lib/viewflow/desktop/vf-media-peer-main`. Its binary and the
repository release copy were updated from the same build. Canonical source
configuration explicitly sets `occlusion` to `opaque`. Windows runs the new
receiver and presenter with `--atlas-sparse-v1`.

SHA256:

- Linux peer: `a9d33d3e1c793fca011bbec568b87d6f02934b08b655c831f407a6b913491daf`
- Windows peer: `70cdb38eb4188734bd60d8a59012d60d6b87e9baf827b8c497d4ba88893992c9`
- Windows presenter: `6a046cdcb91b874ff797d4adf3ed83ab4d138f22d159ce11e697f4c1eb053021`

Fresh source records progressed through frames 120, 480, 600, and 720. The
receiver committed frames through 780 and beyond. Observed live residency was
252 patches, 3,523,944 input and stored pixels, zero omitted pixels, on a
4096x2048 canvas. The current scene had no reclaimed regions; it is not evidence
of live overlap savings. Savings were measured in the controlled GPU fixtures.

The Linux supervisor remained active and the Windows reverse process restarted
successfully. Some frames missed the 33 ms performance target and were still
committed without ending the session. This does not establish 60 fps or validate
user-operated scrolling/input interactions.

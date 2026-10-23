# Cross-display drag recovery, shared-edge Snap avoidance, and stacking

The user reported that a Linux application straddling the Windows screen could no longer be moved with Win+drag, that fast Windows Word returns detached at the seam, that slow returns activated Windows Snap, and that a Linux click-to-raise was not reflected on Windows. The preceding IME change was physically confirmed to show candidates; these drag/stacking issues remained separate.

## Observed failure and changes

- The previous Linux log applied one gesture through sequence 49, rejected sequence 50, and rejected subsequent Begin gestures. The old controller retained its active enrollment after an ordinary Rejected result. Its first rejection did not include a branch reason, so clock mapping is a possible trigger, not a proven cause. Matching rejected gestures now retire without restoring the window to its old position; a fresh valid ordered Begin supersedes an orphaned gesture. An old gesture cannot retire a newer drag ID.
- The paired route, immutable target, configuration/topology identity, and ordered sequence checks remain. Cross-device timestamp mapping errors are diagnostic; each accepted native operation receives a local operation watchdog. Successful native moves renew the enrollment's idle watchdog instead of imposing a fixed total drag duration.
- Before deployment, the old source had actually exited with `desktop enrollment release failed: desktop enrollment expired before checked release`, also closing the Windows connection. Expired geometry capabilities now retire locally. A cleanup failure after a cursor handoff no longer propagates through the shared stream as an input failure.
- The return band is eight Windows physical pixels, converted using the actual remote scale, restricted to shared edges and motion toward the local screen. It also applies while the physical left button is held before reverse drag metadata has arrived, avoiding the Windows Snap hot zone in that race.
- Windows records native move-start geometry before capture enrollment and keeps a 256-physical-pixel resident strip around the reverse capture viewport. Linux publishes each decoded drag start, retaining a start until the proxy is mapped. If that proxy arrives after cursor return, the compositor can continue the original press at the current pointer position. Physical release, a new left press, a new capture lease, or connection reset invalidates that continuation; no stale seam-position warp is performed. A vanished target or unrelated existing drag rejects only that continuation.
- A new Linux click-to-raise clears the Windows presenter's earlier local raise override. The requested source window remains first until a captured stacking snapshot acknowledges it; a later Windows click can take precedence again. Unrelated local Windows window slots remain interleaved.

The native move observer follows Microsoft's [SetWinEventHook contract](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook): out-of-context events are handled by the capture thread's message loop. No desktop input was injected during validation.

## Verification and deployment

- Rust library suite: **630 passed, 9 ignored**. After the final enrollment-renewal/expired-cleanup adjustment, the affected desktop tests were rerun: **50 passed**; desktop IPC client tests: **3 passed**.
- Hyprland plugin: **10 CTests passed**, including original-press continuation invalidation after release/new press and connection reset.
- Linux reverse presenter: **2 CTests passed**.
- Windows composition presenter: **35 CTests passed**; Windows reverse source: **6 CTests passed**.
- Release builds succeeded. Source whitespace checks passed. Existing unrelated workspace changes were retained; no commit or push was requested.
- Both Windows native executables, Linux media peer, Linux reverse presenter, and the live Hyprland input plugin were replaced with unique retained backups. The input plugin unloaded/reloaded successfully; `hyprctl configerrors` was empty. The IME capture fix remains in the new Windows reverse source.
- Actual running executable hashes match the candidates in `linux-runtime.json` and `windows-runtime.json`. Windows native visual commits advanced from frame 600 through frame 1020 after startup. This verifies the deployed programs and active media path, not physical drag/stacking acceptance.
- Display layout remains DP-4 at `(0,0)`, 6144×3456 at scale 2, and HEADLESS-13 at `(3072,390)`, 3840×2400 at scale 2. The preceding Linux 256-logical-pixel seam cache remains active.

| Runtime component | SHA-256 |
| --- | --- |
| Linux media peer | `320e00eb40883d17517d463d7d0df9ad25e46d5fa852affb5bfb93e0c5de521c` |
| Linux reverse presenter | `a3dc8aa1ad4dcf337da1287f9bf302a3807879d51994316328efebdb9994ff59` |
| Hyprland input plugin | `a160c326b020744c2b9b33c72ef5f47438e8dab828b833fe611dee0557a9629c` |
| Windows composition presenter | `b33e47132a4c8ccd17bb29cb29319c24a53d2a78cd25fea4ca2626f7c7f44f2a` |
| Windows reverse source | `d508347b4338cd525d55a0848ffedd4482025da9735579efbafdf25404a5cb5d` |

## Physical acceptance

The user was asked to check Win+drag of a Linux window on Windows, fast Word return, slow seam return without Snap, and Linux click-to-raise reflected on Windows. Results are pending. No automated pointer, keyboard, focus, or gesture actions were used to stand in for that check.

## Follow-up report and deployment

The user subsequently reported a roughly half-second pause of the Windows proxy at the seam and occasional ultra-fast detachment. A further correction preserves the native title-bar grab point, observes native gestures independently of codec initialization, and resumes local dragging without waiting for the remote release receipt. See [the follow-up evidence and current hashes](fast-return/README.md). The earlier hashes above remain the first deployment's historical record.

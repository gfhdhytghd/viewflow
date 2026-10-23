# Follow-up: stationary proxy at the seam and ultra-fast detachment

After the preceding deployment, the user reported that the Windows window's Linux portion stayed at its old location for roughly half a second when the pointer crossed, and that an ultra-fast crossing could detach the pointer and leave the window behind. The user clarified that this described the Windows proxy, not a whole Linux desktop freeze. These reports supersede any assumption that the preceding drag change was physically accepted.

## Correction

1. The return path previously waited for the Windows input-release receipt before releasing local pointer capture and resuming the window. It now puts the release in the ordered stream, resumes locally, and retains receipt handling in a separate task. No timeout is used to guess completion or close the session. Regression coverage checks that queueing completes while the remote receipt is still deliberately withheld.
2. The seam event is intentionally not injected at Windows' Snap edge. With a large last motion, however, the old proxy position could be far from the new pointer. Beginning a local drag at those two positions preserved the wrong offset. Windows now records the original title-bar grab offset; the proxy is positioned at `current local pointer - grab offset` before local continuation. Thus an unsent large final motion does not become a permanent pointer/window gap.
3. A dedicated Windows WinEvent observer thread tracks move start/end independently of capture/codec initialization. An ended move remains available until a frame containing that observation is submitted. Linux retains the grab point along with a start that arrives before mapping. The existing original-physical-press check still prevents a released gesture from resuming on a later click.

Frame tile flag 4 carries two optional signed physical-pixel grab coordinates after `geometry_ack`. A local-only `proxy_drag_anchor` input record (kind 12) converts them to Linux millidips and is consumed by the Linux relay. The native capture release extends the existing reverse-target packet to 68 payload bytes when a grab offset is present. The new Windows source, Linux presenter, Linux relay and compositor plugin were deployed together; the Windows Rust relay and composition presenter remain compatible because they do not parse that native frame extension.

The previous IME, eight-pixel shared-edge Snap band, stacking, seam cache, and enrollment recovery changes remain in place. No automatic mouse, keyboard, focus or gesture actions were used.

## Checks

- Rust library: **631 passed, 9 ignored**.
- Final handoff tests after adding the queued-before-receipt regression: **18 passed**.
- Native capture wire: **2 passed**, including grab-offset layout/validation.
- Linux reverse: **2 CTests passed**, including round-trip and truncation checks for the optional coordinates.
- Hyprland input plugin: **10 CTests passed**.
- Windows reverse: **6 CTests passed**.
- Release builds and touched-source whitespace checks passed.

Installed paths and unique backups are recorded in `linux-installed.json` and `windows-installed.json`. The composition presenter is unchanged at `b33e47132a4c8ccd17bb29cb29319c24a53d2a78cd25fea4ca2626f7c7f44f2a`.

| Updated component | SHA-256 |
| --- | --- |
| Linux media peer | `776d99654dcd56977336e965ee5bf1f90b181cd56964ea60371ed770f35901b6` |
| Linux reverse presenter | `6dcc581c8d9db42088dfbabd86fe6d934655bfdfcf2fb9b3ff95ba6fc214464d` |
| Hyprland input plugin | `bfaf5aee76b1255e2599845ce32225c3277c9fc627cabaac1c043331349c389f` |
| Windows reverse source | `bb6973edde8acb05f829acf45d08ded3524277f6a9cef6abda5d1e849060dd74` |

Physical acceptance of this follow-up is pending. New return diagnostics separately report control queue time, local release time, remote receipt time, the native grab point, and delayed-proxy wait time.

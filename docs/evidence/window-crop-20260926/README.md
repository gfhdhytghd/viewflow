# Partial Linux window restart loop, 2026-09-26

Observed: dragging part of a Linux kitty window onto Mac caused repeated native
presenter restarts and screen/audio permission prompts. Linux source logs showed
`GPU encoding failed with status 1: invalid encode input; retire the capture path`
following the first frame of each attempt. Mac logs showed matching presenter
recreation and background capture startup. Mac also attempted to share those
proxy windows back, and its stale native source rejected the application's
`--activity-coordinator` argument with `invalid integer option`.

Root cause of the encode rejection: `CFrame::apply_crop` subtracted crop offsets
from shadow coordinates even when `shadow_enabled == 0`. The C ABI explicitly
requires all disabled shadow fields to be zero, so a nonzero crop origin made
an otherwise valid frame invalid. Only enabled shadows are translated now;
disabled shadow fields retain their canonical zeros. Tests cover nonzero crop
origins with both vertical orientations and an enabled shadow.

macOS discovery now queries proc_pidpath for executable identity instead of
relying solely on NSRunningApplication's application association. A renamed or
unbundled presenter remains excluded from outbound window selection. The
configuration regression covers a presenter named kitty with an empty bundle ID.
The installed native helper was rebuilt to match the current application's
arguments and activity protocol. A macOS 13.1-only attachment constant is now
guarded for the existing 13.0 deployment target.

Validation: two crop tests passed with native-gpu-media enabled; Mac's 22
noninteractive native tests and ConfigurationTests passed. Linux vf-window-peer
and vf-hyprland-windows were installed and SHA-256 verified. Mac native helper
was signed, installed, capability checked and its complete app passed deep/strict
signature verification. The prior app remains in
~/viewflow-group-20260924/Viewflow-before-window-fix.app on Mac.

No mouse input, focus change or permission dialog click was injected. A new
user-operated partial-window drag is still required to verify stable presentation
and absence of repeated permission prompts. These tests do not establish that
macOS will never require its normal screen capture consent.

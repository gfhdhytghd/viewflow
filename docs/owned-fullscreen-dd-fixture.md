# Owned fullscreen Desktop Duplication fixture candidate

Code-only handoff; not a test result. No display mode, input, focus or GPU action
was performed while implementing this entry point. Normal WGC fixture behavior
remains unchanged unless the new explicit DD options are supplied.

`tools/run-dma-6k60.py` accepts `--fullscreen-output '\\.\DISPLAY6'` together
with explicit `--native` Windows and `--linux-native` Linux candidate binaries.
The caller manages transient mode setup/restoration separately. The runner never
sets a display mode. The DD fixture checks its target already exists, is active
and non-primary, and is unrotated 6144×3456 at 60 Hz. The capture coordinator
still performs its own exact DisplayConfig identity and DD capability checks.

Guest startup creates a fresh token and retains the owned fixture process handle.
Native enrollment requires the exact PID, creation FILETIME, VF6KMotionFixture
class and matching token property on the HWND. Only that fixture may be enrolled
outside the ordinary viewport and receive the producer-internal fullscreen
request. Its ordinary proxy geometry requests are ignored during this experiment;
normal user windows retain their existing behavior. No keyboard/mouse event or
Hyprland fullscreen/focus command is synthesized.

The DD fixture uses a normal opaque HWND swapchain at the reserved output's
origin, with NOACTIVATE and no topmost change. Its normal transparent Direct
Composition fixture mode remains the default. Before the motion gate, the DD
variant submits changing initialization frames every 100 ms so the capture
coordinator can observe a post-bind DXGI LastPresentTime. Those submissions are
outside the measured motion loop and logged separately.

The gate only opens after matching a `profile_dd_submit` record with
`shared_source=1` and `profile_dd_shared_ready completed=1` at the same atlas pts
and full 6144×3456 dimensions. A WGC fallback, ordinary bridge copy, unmatched
completion or merely configured route does not pass. A taskbar/other surface
above the fixture can still make DD unavailable; the test does not hide it or
change its z-order. Existing fixture/job stop, native drain and normal-session
recovery remain responsible for cleanup.

Logs distinguish `capture_clock=dxgi-last-present` from WGC timestamps:

- `profile_dd_capture`: source identity, capture timestamp, snapshot copy time,
  dimensions, request generation and shared-source snapshot availability.
- `profile_dd_submit`: atlas pts and source capture timestamp, actual adopted
  shared-source status, `completed=0`.
- `profile_dd_shared_ready`: completed D12/SHM publication, atlas pts and tile size.

This verifies the producer DD→GPU shared snapshot→D12 DMA→receiver candidate
when actually run. It does not establish user-operated Hyprland fullscreen
transitions, physical 6K presentation, or generation-to-photon latency.

Local CPU checks passed: Python compilation, GDI output argument regex checks,
and the gate test covering a correct match, missing submit/completion, different
pts, bridge-only source, wrong size and WGC-only logs. Windows C++ build and
PowerShell AST validation are pending root's serial build; no runtime pass is
asserted here. New pure helpers: `tools/dma_dd_gate.py` and
`tools/test_dma_dd_gate.py`.

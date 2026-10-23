# Shadow plugin unload regression, 2026-09-10

## Cause and correction

Production core PID 1782828: `CRenderPass::clear()` calls a plugin-defined
unique-pointer deleter at unmapped address 0x7f1715375660. The next render was
an off-screen hymission snapshot. Removing window decorations alone left queued
custom shadow passes alive across dlclose.

The fix detaches shadow decorations while code is loaded, including hidden and
unmapped windows for which Hyprland defers ordinary decoration removal. Closed
windows remain weakly tracked while retained for fade-out. It then removes shadow
passes from the main/current renderer queues before unloading the library.

## Isolated validation

A Gamescope headless parent, with no physical output, hosted a separate Hyprland
v0.56.2 instance. Its bubblewrap device namespace exposed only render devices,
not /dev/input or DRM card devices. The passive Qt fixture used app ID
`ViewflowReverse-Mac-1`; no mouse, keyboard, focus, or gesture input was injected.
The production compositor was not used for unload testing.

Aquamarine v0.15.0 in the isolated process required the attached registry-version
compatibility patch because both Weston and Gamescope advertise versions below
Aquamarine's unconditional bind versions. That temporary library was selected
only for the isolated Hyprland using LD_LIBRARY_PATH. System libraries were not
modified. This patch does not change rendering-pass or plugin lifetimes.

`probe.cpp` queues a real production shadow decoration draw, unloads its plugin,
and immediately clears the renderer queue at the production failure site. Load
this test probe only into the isolated compositor. Its optional second argument
selects mapped (0), hidden (1), or unmapped (2) window state before unload.

Negative control: `old-shadow.cpp` uses the pre-fix destructor; its isolated
compositor PID 657939 terminated with SIGSEGV at an unmapped plugin address.
The IPC command returned an empty response, so IPC exit status alone is not a
success criterion. See the recorded core excerpt.

Positive control: the full fixed input/shadow plugin completed 30 cycles,
10 each for mapped, hidden, and unmapped states. Every cycle queued one shadow
pass and returned 1 after unload/clear; a fresh monitor query succeeded after
every cycle. See fixed-result.json. Plugin CTest also passed 10/10.

The tested full plugin and the deployed binary have identical SHA-256 hashes.
It was loaded successfully into the current production compositor PID 487164,
which had no Viewflow plugin loaded and no Mac proxy windows before deployment.
Capture status readback showed phase 0, no held input, and no remote route.
Mac Accessibility permission and physical cursor/window acceptance remain
separate and pending; they are unrelated to this unload crash.

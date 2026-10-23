# Windows fusion mode — 2026-10-07

## Delivered

- Windows headless virtual display at 6144×3456; Intel graphics remains passed
  through, Linux continues rendering on NVIDIA.
- LSA-backed automatic login for `WINDOWSVM\wilf`, without a plaintext
  Winlogon password. Two actual guest reboots returned to an interactive
  desktop without RDP or manual input, and both Viewflow tasks started.
- Quickshell Windows button deployed next to the Linux launcher. Left click
  requests the native Windows Start menu; right click exposes fusion mode and
  Home/temporary-share choices. `bar.png` shows the live rendered button.
- Interactive Windows control agent uses the existing SSH identity. It runs
  with a normal interactive token, so shell launches and SMB credentials belong
  to the same user context as ordinary applications.
- Windows native capture now supports `--fusion-file`, nonactivating recovery
  from minimized application state, reversible minimize-button/menu changes,
  and Start/Search CoreWindow inventory. The shell flag survives transport
  independently of application icon availability.
- Every initial proxy defaults to floating. Existing geometry ownership code
  and tests preserve Hyprland tiling; no periodic force-floating was added.
- Dolphin context menus and an Open With desktop entry open the original UNC
  file using either the default Windows association or its application picker.
  Home and a separate temporary directory are selectable. No implicit copy or
  hidden write-back queue is introduced.

## Runtime evidence

`windows-final-state.log` records automatic login, both running tasks, virtual
resolution, no plaintext Winlogon password, and the IVSHMEM source. The second
reboot also exercised persisted SMB credentials.

`share-roundtrip.log` proves that freshly created filenames containing Chinese
characters and spaces were read in the Windows **interactive** session, changed
there and read back with the exact expected content on Linux. Both Home and
ViewflowTemp passed after reboot. Test files were removed afterward.

The original Home root directory initially failed to expose host-created files
while already-open subdirectories worked. Samba had an active directory lease.
After setting `smb3 directory leases = no` and reconnecting, new files in both
roots passed immediately. This is consistent with the upstream directory-lease
invalidation issue linked in the design document. File leases remain enabled.
The Samba unit also now waits for network-online and binds by `br0`, fixing its
previous loopback-only binding after an early boot.

`linux-proxies.json` records two visible, mapped, floating Windows proxies after
reboot. The agent's policy readback was `[2,0,0]`: two managed HWNDs, zero iconic
windows, zero remaining standard minimize-box styles. No mouse or keyboard
input was injected to establish this readback.

## Validation

- Windows native build succeeded; all **18 CTests** passed, including hidden
  synthetic-HWND fusion style enable/restore, fusion option parsing, shell flag
  framing without icons, and existing capture/geometry/shared-memory coverage.
- Linux build succeeded; all **10 CTests** passed.
- Two Python path-mapping tests passed (Unicode, spaces, file URLs, share scope,
  symlink escapes, and unrepresentable Windows filenames).
- Python syntax, PowerShell parsing, desktop-file validation, QML lint and live
  Quickshell load passed. Hyprland configerrors remained empty.
- Existing unrelated dirty repository changes were preserved; no commit made.

## Not claimed

The user is away from the computer, and project guidance reserves live input
checks for the user. Start-menu activation/focus, application-picker behavior,
actual Office/PDF application edits, custom-app minimize attempts, and the
physical Hyprland tiling shortcut remain **interactive acceptance pending**.
The code and launch entries for them are deployed; build success is not reported
as proof of those interactions. Shared-file read/write and automatic login are
separately runtime-proven. No capture-to-photon latency or sustained dynamic
6K60 claim is made.

Operational usage, locations, sources and rollback are documented in
[windows-fusion-mode.md](../../windows-fusion-mode.md).

## Follow-up: unresponsive Windows button

The user reported an unresponsive button. Readback found the interactive
`Viewflow-Fusion-Agent` task stopped (`Ready`, last result `3221225786`), while
the IVSHMEM session was still running. Three Start requests were queued with
no agent to consume them. The exit's underlying trigger was not established.

Archived the pending requests under guest `control/recovery-20261007` to avoid
replaying old UI actions. The controller now starts the interactive scheduled
task when it is not running before enqueueing a new request. Added agent
transcript logging at `control/agent.log` for future exit diagnosis. Both
scripts were deployed. A noninteractive `ping` exercised recovery from the
observed stopped state and returned `ok=true`, session 1, policy `[2,0,0]`.
Python path tests (2) and syntax validation passed. No Start action or focus
change was injected; the user's next button click remains the UI check.

## Follow-up: terminal instead of anchored Start menu

The interactive PowerShell task was being console-hosted through Windows
Terminal despite `-WindowStyle Hidden`; closing its console also terminated
the agent. Added and built a GUI-subsystem `viewflow_fusion_launcher.exe`,
which starts PowerShell with `CREATE_NO_WINDOW`, waits and forwards its exit
code. Updated the scheduled task and confirmed the launcher/child process
relationship and a successful session-1 ping.

The controller previously always selected the newest Hyprland instance; a
second test compositor was present. It now honors the bar's inherited session
signature/Wayland display. The bar passes its global button coordinates, and
the controller moves the Start proxy to the corresponding active workspace
and below the button before focusing it. The dispatcher constructors were
checked against the installed local Hyprland implementation. Three Python
tests pass, including mocked multi-compositor selection and anchored menu
placement. Quickshell live logs confirm Configuration Loaded after the edit;
unrelated preexisting bar binding/IPC warnings remain. Actual Start-menu
appearance awaits the user's click; no input or focus was injected for testing.

## Follow-up: user click reaches Windows, Start message ineffective

At 23:35 the bar logged actual user clicks and the guest logged corresponding
`start-request`/`start-observed` entries. No StartMenuExperienceHost surface
appeared after SC_TASKLIST. Thus successful PostMessage return was insufficient
and the earlier Start activation remained broken in this guest.

Changed the explicit user Start action to a Win-key down/up pair via SendInput,
with checked event counts and a key-release recovery attempt. Health checks do
not execute this action. See Microsoft's SendInput API documentation:
https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput

Also corrected the GUI launcher lifecycle: its PowerShell child now belongs to
a job with KILL_ON_JOB_CLOSE so stopping the scheduled task does not leave an
old script holding the agent mutex. Rebuilt/deployed; the old orphan was
removed once, subsequent stop/start produced a new launcher and child PID.
User-operated validation of the changed Start action is pending.


## 2026-10-08: banked IVSHMEM and Start follow-up

Supersedes the earlier SendInput activation attempt: Start activation uses the
real taskbar button's UIAutomation TogglePattern. Actual user clicks confirmed
menu appearance and pin/Stage stacking. The user then reported first-map
center flashing, slow startup, and missing hover. The receiver now leaves
shell placement entirely to the bar's preinstalled initial-position rule;
Windows receives cropped-menu motion through SendInput instead of cursor warps.
Non-consuming host button bindings dismiss Start on an outside click.

The 8 GiB BAR experiment failed driver initialization and pinned all backing
pages. Replaced it with a 1 MiB control BAR plus four 1 GiB pixel BARs, and a
VM-local QEMU patch that excludes explicitly CPU-only banks from VFIO DMA
mapping. Intel remains vfio-pci, NVIDIA remains host-owned. All five Windows
IVSHMEM devices report OK. Boot backing allocation: 4 KiB control, 0 pixels.
16384×2 and 2×16384 probes: four frames, both processes exit 0, all CPU pixels
exact and three RGB/alpha GPU samples per frame correct, 512 KiB total slots.
16384×16384 probe: four frames, both exits 0, four received, zero obsolete,
all CPU pixels exact and GPU samples correct, 4 GiB physical slots. Fixture
production took 4119 ms; receiver copy p95 437 ms and upload completion p95
137 ms. These are capacity tests, not desktop presentation latency. Released
test pages before restoring the live transport; runtime logs confirm
`transport=ivshmem format=bgra codec=none` and cropped Start body 1708×1759.

After PCI layout changes, a Fast Startup resume overlapped a new BAR with the
SATA controller and stalled boot. Resetting that stalled boot recovered the
VM; HiberbootEnabled changed from 1 to 0 to use cold initialization afterward.

Linux CTest 10/10 and Windows CTest 19/19 passed. The Hyprland plugin was built
against the running exact efb50993780079460b0cbed1363e2166a2de1d9f headers and
reloaded successfully; the synthetic touchpad/gesture-route test passed.
The persistent native control relay passed 12 sequential read-only pings;
warm round trips measured 30–49 ms. The experimental PowerShell stdio relay
stalled and was replaced; it is not the deployed control transport.

The user confirmed placement, hover, outside-click, and three-finger behavior
with “均正常”. Follow-up reports requested no pointer warp, correct IME
placement, and removal of a residual taskbar Start tooltip.

The explicit focus dispatcher called `warpCursor()` in this compositor.
A scoped plugin `focus_without_warp` operation now calls `fullWindowFocus`
without pointer movement. Plugin build/load passed and read-only API query
returned `function`. Linux controller tests: 3/3.

Live source logs showed Start HWND 0x10202 transitioning to Search HWND 0x10206
while the focused old proxy was removed. The receiver now keeps one Wayland
shell surface across overlapping Start/Search tiles, rebinding guest IDs while
preserving keyboard/pointer state. IME candidates use the captured owner's
cropped guest origin and current host origin. Read-back showed Search at
(38,56), candidate at (81,107), both pinned. The candidate cannot take keyboard
focus, and selecting candidates is excluded from outside-click dismissal.
Build, Linux CTest 10/10, crop/scale/negative-origin self-test, Lua syntax,
configerrors, and five unique dismissal bindings passed. The running transport
remains IVSHMEM BGRA; Windows diagnostic backend is now build-16k.

User validation of the follow-up input fixes is pending. The 104x82 residual
surface had already disappeared before inspection; class/root-owner logging
was deployed to identify it on the next reproduction. It is not claimed fixed.
No test mouse/keyboard input or focus change was injected.

## Office Open With, 2026-10-08

User confirmed the preceding input fix with “这个正常了”, then requested Office
Open With entries. Word, Excel and PowerPoint executables were found in the
Windows Office16 installation. Three per-user Linux desktop entries were
installed and validated. `gio mime` lists the matching entry as recommended
for DOCX, XLSX and PPTX; the existing WPS default is retained. CLI dry-run
checks resolved each selected app to the original Home UNC path. The deployed
interactive agent's read-only `applications` request returned all three actual
executable paths. No document was opened or edited for this verification.


Office follow-up: user reported opening failed. Agent transcript showed
Test-Path access denied. The recently used DOCX resolved from Downloads into
the Lazycat FUSE mount; the same agent could read local Home/README metadata.
A user-owned bindfs bridge and authenticated ViewflowCloud share fixed the
cloud path (the unchanged DOCX is visible with length 1189386). A generated
Unicode/space-named file in the same Downloads directory was read and appended
by the interactive Windows agent, and the original Linux path contained the
expected appended text. The probe file was then removed. CLI bridge routing
and four Python tests passed; no user document was opened or edited by tests.

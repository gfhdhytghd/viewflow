# Symmetric desktop handoff

## Protocol and ownership

The input-only lane is independent of window, clipboard, HID and atlas video
lanes. Each link has one authenticated, ordered QUIC bidirectional stream and
both endpoints have capture and injection adapters. The smaller device ID dials;
OS, group host/client role, hostname and display label do not select direction.

Each endpoint reserves its local desktop before requesting or granting a lease.
The target grants ownership. Simultaneous requests use the smaller device ID as
the tie-breaker; the losing pending request yields before entry. An existing
active owner wins over a new request. A kernel file lock serializes all local
handoff workers and the existing native desktop receiver. Contention rejects
input on that lane, without disconnecting window, clipboard or media sessions.
Hyprland also excludes legacy capture activation while a new handoff is pending
or active, and rejects new capture when legacy capture already owns the seat.

A lease identifies its controller, target and increasing generation within the
connection. Input carries that generation and an increasing stream sequence.
Retired input cannot inject or release a newer lease. Return, disconnect, adapter
loss and ownership replacement release held keys/buttons and restore capture.
Native release acknowledgement precedes releasing the target lock. Connection
loss closes the adapter pipe, giving the adapter an EOF cleanup path. The
shutdown watchdog is a resource-recovery fallback, not a frame deadline.
There is no 33 ms ownership expiry or focus-change termination.

The framing is a 4-byte little-endian length (40), then a 40-byte record:
`u32 type=2, u64 lease, u64 sequence, u32 kind, i32 a,b,c,d`.
Kinds 100/200 request/grant, 202 releases, 203 denies, and 102 negotiates version
and sender/receiver capabilities. Kinds 1–4 carry position, button, scroll and
physical key. Native-only 101/103/201/204 mean return/fault/entry/release-ack.
The fixed length is checked before allocation. This is a new lane; it does not
change the existing atlas wire format.

Layout uses logical display rectangles and the existing per-link `share_origin`.
Only touching edges with a nonempty overlapping interval are eligible. Entry
preserves position along that interval. Remote motion runs in target-local
coordinates; crossing the reciprocal edge returns to the controller. Return
projects the current remote position onto the local edge, one logical unit
inside it. Physical inward motion rearms the edge. Injected events and warps
never initiate capture.

Native adapters distinguish physical and injected events. Windows uses low-level
hook injected flags and an injection marker. macOS uses CGEvent source userdata
and source PID. Hyprland feeds the new route from its existing physical-device
listeners and uses the forwarded-motion guard for injection. A received event
cannot become a new outbound request. A candidate already queued when an entry
arrives cannot reset the incoming owner. Native hooks never wait for network I/O;
Windows/Mac output uses a bounded queue and Linux uses event-loop socket readiness.

Keyboard transport uses physical evdev positions with explicit down/up/repeat.
Control and GUI remain distinct, including Mac→Mac. Shared Windows mappings and
scroll units are copied verbatim from **samesys-review `e477a06b`**, not from its
uncommitted checkout. The adapter wrapper stays in one header. Scroll carries
120 units/detent or 1000 units/point and an explicit end marker. Both axes follow
AppKit sign; Windows horizontal scroll changes sign at the Windows boundary.
Precise integer native APIs retain subunit remainder. Native HID remains on the
existing Linux→Mac receiver lane; no new HID transport is introduced.

## Profiles and compatibility

Current devices advertise optional `handoff_version=1` and `handoff_port` fields.
The existing four service ports remain unchanged. Old peers without these fields
retain their existing lanes and get a capability notice. Native capability
negotiation can independently disable sending or receiving. Input Monitoring
absence on Mac leaves its receiver available if Accessibility permission exists.
Capability status appears in the desktop component status and native logs.

`vf-handoff-peer` starts `viewflow-desktop-handoff`. The native helper has both
roles. Linux's helper connects the plugin capture route to the existing
`viewflow-linux-window-input` implementation in desktop mode. That mode targets
the desktop, never a pinned window. Its virtual keyboard handles modifiers; the
plugin forwards pointer/button/wheel events without recapturing them.

The normal new input-only path needs no decoder, physical GPU or desktop video.
Linux→Windows can use it while the independent atlas worker is unavailable.
Existing Linux→Windows atlas profiles/binaries still have their original path.
With HID enabled, Linux→Mac keeps the existing native-HID cursor sender; the new
lane supplies the reverse direction. With HID disabled, Linux→Mac also uses the
new symmetric sender. Linux→Linux keeps the existing parking/window supervisor,
but its obsolete cursor worker runs in window-only mode; the new worker owns
actual desktop capture. Other window/clipboard workers stay independent.

## Support matrix

“Implemented” means the source path and launch recipe exist. It does **not** mean
native acceptance passed. Each row describes two different devices even when
both use the same OS. Exchange the physical input devices to test the opposite
controller role; group host/client selection does not restrict it.

| Controller → target | Sender / receiver | Offline evidence | Native acceptance |
|---|---|---|---|
| Linux → Linux | Hyprland capture / desktop helper | Built; profiles; portable state; mock QUIC | Unverified |
| Linux → Windows | Hyprland capture / Windows helper; legacy atlas retained | Profiles; portable state; mock QUIC | Unverified |
| Linux → macOS | Existing native HID lane by default; symmetric lane with HID off | Profiles; portable state; mock QUIC | Unverified |
| Windows → Linux | Windows hooks / Linux desktop helper | Profiles; portable state; mock QUIC | Unverified |
| Windows → Windows | Windows hooks / Windows helper | Profiles; portable state; mock QUIC | Unverified |
| Windows → macOS | Windows hooks / Mac helper | Profiles; portable state; mock QUIC | Unverified |
| macOS → Linux | Session event tap / Linux desktop helper | Profiles; portable state; mock QUIC | Unverified |
| macOS → Windows | Session event tap / Windows helper | Profiles; portable state; mock QUIC | Unverified |
| macOS → macOS | Session event tap / Mac helper | Profiles; portable state; mock QUIC | Unverified |

## Offline verification recorded on Linux

- `cargo check -p viewflowd --bin vf-handoff-peer`: passed.
- `cargo build -p viewflowd --bin vf-handoff-peer`: passed.
- `cargo test -p viewflowd --lib desktop_handoff`: **5 passed**.
- `cargo test -p viewflowd --lib input_runtime`: **78 passed**.
- Profile discovery (`test_*profiles.py`), with the new Rust validator selected:
  **17 passed, 2 skipped**. Includes all ordered 3×3 pairs and both local recipes.
  The skipped tests require the old optional release validator bundle.
- Pairing discovery (`test_pairing_*.py`): **31 passed, 1 skipped**. This overlaps
  the profile suite; do not sum these as unique tests.
- `platform/desktop-handoff` CTest: **1 passed**, including four edges, return
  rearming, injection exclusion, held keys/buttons, partial release failure,
  shared modifier mappings, Pause, precise scroll and phase conversion.
- `platform/linux-window-input` CTest: **3 passed**; desktop helper compiled.
- Hyprland plugin: compiled against this host's installed headers. Not loaded.
- `tools/tests/handoff-transport-test.py`: **return and disconnect both passed**
  over real loopback mTLS/QUIC with fake native adapters. No desktop APIs used.
- `git diff --check`: passed.

The first dependency import lacked `spake2`; dependencies were installed only
in `/tmp/viewflow-handoff-tests-venv`. The first group-profile run exposed its
old six-component assertion; it now expects seven because the adjacent link
adds a worker, while still checking that existing link configs stay unchanged.
An attempted `test_runtime.py` discovery found zero tests; it is not counted as
verification. A new offline Worker fixture checks capability status explicitly.
Compiler warnings remain; successful compilation is not live acceptance.

Reproduce the Linux-only checks from the repository root:

```sh
python3 -m venv /tmp/viewflow-handoff-tests-venv
/tmp/viewflow-handoff-tests-venv/bin/pip install -r platform/desktop-app/requirements-pairing.txt
cargo build --locked -p viewflowd --bin vf-handoff-peer
cargo test --locked -p viewflowd --lib desktop_handoff
cargo test --locked -p viewflowd --lib input_runtime
VIEWFLOW_HANDOFF_TEST_BINARY="$PWD/target/debug/vf-handoff-peer" /tmp/viewflow-handoff-tests-venv/bin/python -m unittest discover -s platform/desktop-app -p 'test_*profiles.py'
/tmp/viewflow-handoff-tests-venv/bin/python -m unittest discover -s platform/desktop-app -p 'test_pairing_*.py'
/tmp/viewflow-handoff-tests-venv/bin/python tools/tests/handoff-transport-test.py target/debug/vf-handoff-peer
cmake -S platform/desktop-handoff -B /tmp/viewflow-handoff-core
cmake --build /tmp/viewflow-handoff-core
ctest --test-dir /tmp/viewflow-handoff-core --output-on-failure
cmake -S platform/linux-window-input -B /tmp/viewflow-handoff-linux-input
cmake --build /tmp/viewflow-handoff-linux-input
ctest --test-dir /tmp/viewflow-handoff-linux-input --output-on-failure
cmake -S platform/hyprland-plugin -B /tmp/viewflow-handoff-plugin -DBUILD_TESTING=OFF
cmake --build /tmp/viewflow-handoff-plugin
```

## Binaries and native build commands

All platforms add `vf-handoff-peer` and `viewflow-desktop-handoff`. Package them
with the changed pairing frontend; old bundles do not allowlist the new worker.
Existing `viewflowd` and Windows `vf-media-peer` must also be rebuilt for shared
target ownership. Linux additionally changes `vf-cursor-peer`,
`viewflow-linux-window-input` and `viewflow-hyprland.so`. The macOS app adds the
new worker configuration and bundles it through `tools/build-macos-app.py`.
The HID receiver and driver binaries are unchanged.

### Windows 11 VMs (MSVC; execute in each VM)

Use an x64 Native Tools/Developer PowerShell with Rust MSVC, CMake and Windows
SDK installed. These commands compile and self-test input-only handoff; they do
not require a physical GPU or call native input APIs:

```powershell
cargo build --locked --release -p viewflowd --bin vf-handoff-peer --bin viewflowd --bin vf-media-peer
cmake -S platform/desktop-handoff -B build/handoff-win -A x64
cmake --build build/handoff-win --config Release
ctest --test-dir build/handoff-win -C Release --output-on-failure
.\build\handoff-win\Release\viewflow-desktop-handoff.exe --self-test
```

Expected self-test output includes `handoff captured`, `handoff entered`,
`handoff returned`, `handoff released`, and
`handoff self-test passed: captured entered returned released; no native input`.
This checks portable state and wiring, **not** installed hooks or SendInput.

For the updated GUI bundle, use the repository's normal packaging dependencies:
`python tools/build-desktop-app.py --output dist/handoff-windows`.
For an existing test bundle, copy the rebuilt native helpers and regenerate its
manifest with the normal packager; do not hand-edit a checksum-protected bundle.
Pair the VMs in the updated app, arrange adjacent displays, and verify both
`desktop-handoff` workers run. Their generated config can also be run explicitly:

```powershell
.\target\release\vf-handoff-peer.exe validate --config C:\path\to\desktop-handoff.json
.\target\release\vf-handoff-peer.exe --config C:\path\to\desktop-handoff.json
```

The second command starts live capture/injection and belongs to the tester.
Use the actual materialized config path from that machine; group profiles prefix
it with the peer ID. QUIC UDP reachability and an interactive signed-in desktop
are normal prerequisites. Session-0, elevated targets and secure desktops remain
unverified. No extra GPU setup is needed for this lane.

### macOS (build and run on a real Mac)

```sh
cargo build --locked --release -p viewflowd --bin vf-handoff-peer --bin viewflowd
cmake -S platform/desktop-handoff -B build/handoff-mac -DCMAKE_BUILD_TYPE=Release
cmake --build build/handoff-mac
ctest --test-dir build/handoff-mac --output-on-failure
xcrun swiftc -parse-as-library platform/macos-app/Sources/Configuration.swift platform/macos-app/Tests/HandoffConfigurationTests.swift -o /tmp/viewflow-handoff-config-tests
/tmp/viewflow-handoff-config-tests
```

Build the app with the normal signed packaging workflow in
`tools/build-macos-app.py`. An input-only development build can use
`--without-driver --skip-hardware-tests`; it cannot validate native HID.
The native `.mm` file and Swift changes were reviewed but **not compiled here**.
Grant Accessibility and Input Monitoring to the tested app/helper through normal
system settings. Keep permission-denial testing separate from HID acceptance.

## User-operated acceptance

Never use automated input injection for these acceptance steps. Both endpoints
must run the rebuilt software. Configure two adjacent device rectangles in the
app. Use a local text editor and a scrollable document on each target. Record OS,
scaling, layout, peer IDs, build commit and both worker logs for every row.

Apply this sequence to **each of the nine rows above**:

1. Move a physical mouse across the configured shared edge, inside its overlap.
   Expect controller `handoff captured` and target `handoff entered`. The target
   cursor appears at the corresponding entry position; the controller suppresses
   its local input. Legacy Linux→Mac HID uses its existing cursor/HID logs instead.
2. Type letters, arrows, Home/End, F-keys and keypad keys. Test left/right Shift,
   Control, Alt/Option and GUI/Command separately. Test press, repeat and release.
   Mac→Mac must keep Control as Control and Command as Command.
3. Hold a modifier before crossing. Repeat with a mouse button and a drag.
   Verify local client state is released on capture and remote release is clean.
   Check modifier/button state again after return and disconnect.
4. Scroll vertically and horizontally. Test one wheel detent and small precise
   trackpad motion. A one-point Mac gesture must not become hundreds of pixels.
   Verify end/cancel and momentum endings leave no continuing gesture.
5. Move back through the return edge at a different position along the edge.
   Expect `handoff returned` on the controller and `handoff released` on both.
   The local cursor returns at that position. It must not bounce back remotely.
6. Stop the connection while a key/button is held. Expect release logs and no
   stuck key/button. Restart the link and repeat entry. Other window/clipboard
   workers must remain available after an input adapter failure.
7. Have both users cross simultaneously. One controller wins; there must be no
   pointer ping-pong, repeated injected keystrokes or second target owner.
8. Repeat with left, right, top and bottom arrangements, including partial
   overlap. A corner-only contact must not create a handoff edge.
9. Repeat from the other physical computer, and with the app group host/client
   roles exchanged. Log both directed results, not merely “pairing succeeded”.

Platform-specific recording sheet:

| Ordered pair | Additional required check |
|---|---|
| Linux→Linux | Both updated plugins; virtual-keyboard modifiers; no sender-to-empty-input-port path |
| Linux→Windows | Input-only worker works with atlas/video worker stopped; separately regress existing atlas mode |
| Linux→macOS | HID on preserves existing native touchpad behavior; HID off tests the new lane |
| Windows→Linux | Entry position, wheel sign and virtual-keyboard modifier release |
| Windows→Windows | Two tiny11 VMs; both controller roles; shared extended/international key table |
| Windows→macOS | Control/GUI identity, horizontal wheel sign, Mac permission notices |
| macOS→Linux | Precise milli-points, modifier release and physical event exclusion |
| macOS→Windows | Precise-to-wheel remainder, GUI/Control identity and Windows scaling |
| macOS→macOS | Two real Macs; Control/Command separation; tap recovery; precise scroll/end; both users can initiate |

Short Linux→Linux checklist: pair two updated hosts; place an adjacent edge;
cross and type/scroll; return; reverse the controller; disconnect while holding
a key/button; inspect release and absence of ping-pong. Plugin installation,
loading and all physical input remain the user's actions.

For Mac→Mac, also deny Input Monitoring on one side while leaving Accessibility
available. Confirm its receiver remains usable and its sender capability is
shown unavailable; window/clipboard workers stay up. Restore permission, restart
only that input worker using the app, then repeat steps 1–7. Collect each
`handoff-<peer>.log` plus the app's component statuses.

## Remaining evidence limits

No Windows/MSVC or macOS/Swift native build ran on this Linux host. No live
hooks, event taps, virtual-keyboard injection, plugin load/unload, focus change,
service restart, SSH, deployment or physical acceptance ran. No installed files
under `~/.local/lib/viewflow` or `~/.config` were changed.

All nine native rows remain unverified. In particular: mixed-DPI/multi-monitor
and negative native origins, hotplug, IME, secure/elevated desktops, permission
revocation, actual held-button cleanup, and sustained bidirectional use require
native evidence. The initial native adapters use the paired logical primary
screen geometry; arbitrary native monitor-origin selection is not established.
No performance regression measurement was performed. Existing paths add no new
polling in input callbacks, but that source observation is not a latency proof.

## Windows VM follow-up (2026-11-06)

Baseline `31c4a7c1` was tested by the user on two tiny11 VMs with real hooks
and SendInput. The user reported both capture directions, opposite-edge return,
relative motion, clicks, Shift symbols, Ctrl+A, local suppression, peer-death
cleanup and automatic reconnect working. This supersedes the initial
Windows→Windows “unverified” row for those baseline cases only. The changes
below still require native acceptance.

The core now records pointer placement from native warps and received input.
An interior placement rearms the edge even when the next accelerated physical
event lands directly on it. Changed physical positions may rearm; injected
events never request capture. An unchanged sample at the return edge cannot
bounce back. Presentation-restoration failures no longer skip held-input release.

Windows replaces the standard system cursor images while captured and reloads
the user's cursor scheme on return, release and failure. One session-local mutex
protects ownership across workers. A separate, event-driven guardian waits for
adapter process death and restores the cursor and removes clipping. Startup also
reloads the cursor scheme when no live worker owns it. There is no input polling
or persistent cursor-scheme change. Killing the entire process tree/job can also
kill the guardian; the next adapter startup is the fallback. Custom application
cursors and desktop switches need native testing. See Microsoft's
[system cursor API](https://learn.microsoft.com/en-us/windows/win32/menurc/cursors)
and [SPI_SETCURSORS](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-systemparametersinfow).

Mac tracks successful hide/detach operations separately and undoes both before
return warps, including partial failures, EOF, and ordinary exception cleanup.
Repeated cleanup does not decrement another application's hide count.
Uncatchable process termination cannot run this cleanup; WindowServer behavior
after forced termination and background-helper cursor hiding remain native
acceptance items. The API's foreground and hide-count behavior is documented by
[Apple](https://developer.apple.com/documentation/coregraphics/cgdisplayhidecursor%28_%3A%29).
No blind startup decrement is performed on Mac.

The input-only QUIC lane now negotiates a 3-second idle timeout and sends
keepalives every second. This is a dead-connection watchdog, unrelated to the
33 ms performance target. QUIC loss detection and native release acknowledgment
mean that wall-clock cleanup need not be exactly three seconds. The hermetic
silent-process-death test observed held-input release in **4.00 seconds**, then
reconnection without restarting the receiver. Timeout keeps the existing
lane recovery loop; it does not end other application sessions.

### Installed Windows firewall setup

The per-user MSI stays per-user. The bundle now includes
`setup/configure-windows-firewall.ps1`; the Windows app's network settings has
an **Allow Viewflow inbound connections** button (Chinese:
**允许 Viewflow 入站连接**). Before connecting, click it, approve the normal UAC
prompt, and check that the elevated window reports
`Viewflow firewall setup complete`. Close that window after reviewing the result.
Launching the window alone is not evidence that setup succeeded.

The script permits TCP/UDP for installed `Viewflow.exe` and UDP for installed
`bin/viewflowd.exe`, `vf-handoff-peer.exe`, `vf-window-peer.exe`,
`vf-media-peer.exe`, and `vf-clipboard-peer.exe`. Rules use full executable paths
and all three firewall profiles. Missing optional workers get no rule; run setup
again after installing them. The native handoff adapter has no network listener.

Windows prompt-generated Block rules override Allow rules. Setup removes local
PersistentStore inbound Block rules only when their executable path exactly
matches one of those installed programs. It does not change global defaults,
outbound rules, another installation's rules or Group Policy. A managed Group
Policy block can still prevent access. Updating in the same directory retains
the path-scoped rules; before removing or moving an installation, use `-Remove`
to remove its managed Allow rules. It does not recreate old prompt-generated blocks.

From Developer PowerShell in each Windows VM:

```powershell
cargo build --locked --release -p viewflowd --bin vf-handoff-peer
cmake -S platform/desktop-handoff -B build/handoff-win -A x64
cmake --build build/handoff-win --config Release
ctest --test-dir build/handoff-win -C Release --output-on-failure
.\build\handoff-win\Release\viewflow-desktop-handoff.exe --self-test
powershell -NoProfile -File tools/configure-windows-firewall.ps1 -SelfTest
```

Rebuild/package the Windows app through the existing
`tools/build-desktop-app.py` / `tools/package-windows-msi.py` workflow so the
button and setup script ship together. Use the installed root, not the source
tree, for the following commands. Run actual setup in elevated PowerShell:

```powershell
$bundle = Join-Path $env:LOCALAPPDATA 'Programs\Viewflow' # adjust to actual install
& "$bundle\setup\configure-windows-firewall.ps1" -InstallRoot $bundle -WhatIf
& "$bundle\setup\configure-windows-firewall.ps1" -InstallRoot $bundle
Get-NetFirewallRule -Group Viewflow | Get-NetFirewallApplicationFilter | Format-Table Program
# Before uninstall/move, if needed:
# & "$bundle\setup\configure-windows-firewall.ps1" -InstallRoot $bundle -Remove
```

Focused user-operated acceptance in both VM directions:

1. Return/enter so the local pointer is about 27 pixels from the configured
   left edge. Make one fast physical move directly to x=0. Expect
   `handoff captured` immediately. Repeat all four edges. Stationary or injected
   edge placement alone must not produce a new capture.
2. While captured, expect `handoff cursor hidden` and no visible controller cursor.
   On return/disconnect expect `handoff cursor restored` and normal clipping.
   Kill just the native adapter while captured to test guardian cleanup.
   Separately kill its entire process tree and verify repair at the next start.
3. Hold a modifier and mouse button, then kill only the remote transport or drop
   that VM's network. Expect `recovering: connection lost: timed out` and
   `handoff released` within roughly 3–5 seconds under normal scheduling.
   Restart/reconnect and repeat capture without restarting the surviving app.
4. On a fresh install, run the app's elevated firewall setup. Repeat with an
   existing prompt-generated Block rule. Both peers must connect without another
   firewall Allow click. Inspect that unrelated program rules remain unchanged.

On Mac, rebuild `vf-handoff-peer` and `viewflow-desktop-handoff` using the commands
above in the Mac section; repeat edge rearm and hide/restore tests in both
directions. Include tap failure, adapter EOF and forced termination, recording
cursor visibility as well as `handoff cursor hidden/restored` logs. On Linux,
rebuild the transport, desktop helper and Hyprland plugin; user-operated testing
should repeat accelerated reentry and stationary-edge no-bounce in both directions.

Offline evidence for this follow-up: C++ core test passed; Linux helper CTest
3/3 passed; Rust handoff state tests 5/5 passed; real loopback mTLS/QUIC with fake
adapters passed return, EOF, silent death, held-input release and reconnect;
Python elevated-launch tests 2/2 passed. Linux transport/helper/plugin builds
passed with existing warnings. Windows/MSVC, Mac native builds, PowerShell
SelfTest, actual firewall setup and MSI installation were not run on this host.

## Elevated Windows receiver follow-up (build after fde92e3c)

The user reports that two Windows 11 VMs at baseline `fde92e3c` passed wheel
direction/amount, 150% scale entry/return, cursor hiding and peer-death restoration,
held-Shift release in 3–5 seconds, and replacement of prompt-generated firewall
Block rules. The service integration below has only offline evidence on Linux.

On each received handoff, the Windows adapter now tries the existing
`\\.\pipe\ViewflowInput-v2-<session>` broker. The broker still authorizes the
configured receiver SID and SYSTEM through its local-only pipe ACL. The client
checks the pipe server's SYSTEM token and matching session, using identification
SQOS exactly as the existing Rust service client does. No new network listener,
service privilege, account permission or pairing rule is added.

When reachable, the broker receives all pointer, button, wheel and keyboard
events for that handoff. It uses the existing backend which binds its injection
thread to the current input desktop on each request. Thus Default, UAC secure
desktop and Winlogon use the existing service desktop-transition/release logic.
Controller hooks, capture, cursor warps and local held-key release keep the
in-session path. Service-generated input remains excluded by the injected-event
hook flags. The service protocol and binary are unchanged.

If the service is absent, stopped, denied to this account/session, or already
occupied by another input client, the adapter uses its original in-session
SendInput path for that handoff. The service currently admits one pipe client;
no competing client is disconnected to acquire it. This fallback cannot support
higher-integrity or secure-desktop targets. See Microsoft's
[SendInput integrity constraints](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput).
The app's permission panel reports the missing/stopped service and these limits.
A running-service status is not proof of a reachable broker.

The adapter logs the chosen route at entry:
- `handoff receiver backend=service elevated-input=available secure-desktop=service`
- `handoff receiver backend=session elevated-input=unavailable secure-desktop=unavailable; install/start ViewflowInput for this receiver account`

The route stays fixed until release. A failed or uncertain service operation is
never replayed through local SendInput or a new connection. It releases the
handoff and closes the pipe; the service retains failed held-input cleanup and
retries before accepting its next client. The transport remains recoverable.
Normal return/EOF also closes the pipe, including failed-release paths. No new
polling runs in hooks; broker I/O uses overlapped events and the existing service's
five-second operation-watchdog convention.

The broker wire carries physical pixel coordinates in milli-units, preserving
the adapter's logical-to-physical scaling. Wheel values retain fractional
detents; precise milli-points use 40 points/detent. Keyboard conversion reuses
the shared Windows physical-key table and a generated inverse of the existing
service HID table. `windows-handoff-key-table` regenerates it and a Rust test
checks it for drift. Existing service key coverage still applies: Pause/E1 and
unmapped OEM/browser/system keys are rejected with a diagnostic, not guessed or
replayed locally. This change does not add software Secure Attention Sequence
generation; Ctrl+Alt+Del opening must use the VM console's dedicated action.
Once that screen is open, test its controls through the service.

### VM build and test commands

Run in an x64 Developer PowerShell with MSVC, Windows SDK, Rust MSVC and CMake:

```powershell
cargo build --locked --release -p viewflowd --bin vf-handoff-peer --bin vf-input-service
cargo test --locked -p viewflow-platform windows_input
cargo test --locked -p viewflow-platform --example windows-handoff-key-table
cmake -S platform/desktop-handoff -B build/handoff-win -A x64
cmake --build build/handoff-win --config Release
ctest --test-dir build/handoff-win -C Release --output-on-failure
.\build\handoff-win\Release\viewflow-desktop-handoff.exe --self-test
```

Install the rebuilt adapter in the tested bundle's `bin` directory using the
normal packaging workflow. Rebuild `Viewflow.exe` to include permission text.
No Rust production binary changed in this follow-up; the service build above
ensures the VM tests use the reviewed baseline.

With UAC enabled and “Switch to the secure desktop when prompting for elevation”
enabled, install/start the existing service from elevated PowerShell. Set the
account to the actual medium-integrity receiver user, especially if elevation
uses a different administrator account:

```powershell
.\tools\install-windows-input-service.ps1 -Binary "$PWD\target\release\vf-input-service.exe" -ReceiverAccount "VMNAME\receiver"
Get-Service ViewflowInput
```

Before entering a handoff, run from the receiver's **ordinary** PowerShell:

```powershell
.\build\handoff-win\Release\viewflow-desktop-handoff.exe --service-probe
```

Expect `handoff service-ready secure-desktop-access=ok input-injected=false`.
This probe checks broker identity, session, account authorization and Winlogon
access without hooks or injection. Do not run it during a handoff: the service's
single pipe instance is already occupied.

User-operated acceptance, repeated with each VM as receiver:

1. Keep Viewflow and its adapter at medium integrity. Cross into the receiver.
   Expect `backend=service`, `handoff entered`, and normal pointer/keyboard input.
2. Open an Administrator console on the receiver. From the controller, click to
   activate it, type a harmless command such as `echo handoff`, use Shift symbols
   and Ctrl+A. Verify clicks and keys arrive. Repeat wheel and 150% scale checks.
3. While controlling that VM, request elevation of an application to open a
   consent prompt on the secure desktop. Use the remote pointer to select No.
   Repeat with Yes. Expect input to continue through the prompt and back to
   Default, without a handoff fault solely because the desktop changed.
4. Lock the receiver with Win+L. Dismiss its lock screen through remote input,
   focus the sign-in field and sign in with the tester's own credentials.
   Do not capture passwords in logs. Expect the same link to resume on Default.
5. Use the VM console's Send Ctrl+Alt+Del action, then select Cancel remotely.
   This tests Winlogon controls, not software generation of Ctrl+Alt+Del.
6. Hold Shift or a mouse button and disconnect/kill the controller. Verify release
   in the service-backed target, then restart and capture again. Also stop the
   service during capture: expect `handoff receiver recovering:`, return/release,
   no duplicated input and a usable ordinary-session fallback on the next entry.
7. Stop/uninstall the service and repeat ordinary-window control. Expect
   `backend=session` and the permission-panel warning. Elevated-window and
   secure-desktop control are unavailable in this mode. Starting the service and
   returning/reentering selects it without restarting the other application lanes.

Offline results: portable C++ core/wire test passed; Rust Windows input/wire
tests **22/22** passed; generated key-table test **1/1** passed; Python service
status test **1/1** passed. Windows named-pipe I/O, MSVC compilation, actual
elevated/secure/locked desktop input, service contention, release on desktop
switch and performance remain unverified until these VM checks run.

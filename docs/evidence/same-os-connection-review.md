# Same-OS connection review

Date: 2026-11-06. Branch: `samesys-review`.
Reviewed HEAD: `0e8d8c4de690967ef7f57ad86290176c0c899a25`.

## Follow-up fix status (2026-11-06)

M2, L2 and W3 now have implementation fixes and portable regression tests. C2's
profile matrix now includes all nine ordered pairs. All three overall statuses
remain **partly**: W1/M1/L1 desktop-handoff blockers, Windows parking prerequisites
and native acceptance gaps remain. The original review below is preserved as a
historical record of HEAD `0e8d8c4de690967ef7f57ad86290176c0c899a25`; its old line
references and “no product code changes” statements describe that review only.
This follow-up changes product code and is authorized for a commit on
`samesys-review`. No live deployment or input test is included.

| Finding | Implementation and evidence | Verification boundary |
|---|---|---|
| M2 | `platform/reverse-common/scroll_units.hpp:10` decodes milli-points versus 120-unit lines and end markers. `platform/macos/window_source.mm:586` creates the corresponding Quartz event. Per-window accumulation preserves sub-point totals; release clears that state. | Portable positive/negative, both-axis, fractional, end/restart and invalid-record tests pass; native Quartz/AppKit delivery unverified. |
| L2 | `platform/desktop-app/pairing_profiles.py:85` supplies explicit source platform. `platform/reverse-common/touchpad_routing.hpp:6` and `platform/linux-reverse/main.cpp:245` share the raw-input eligibility decision between record generation and wheel suppression. | Linux/unknown sources retain wheel fallback; Windows is explicitly selected; Mac retains the existing HID-ready decision. Policy tests and Linux native build pass; physical HID unverified. |
| W3 | `platform/reverse-common/windows_keys.hpp:169` / `platform/reverse-common/windows_keys.hpp:177` supply both directions. Used at `platform/windows-window-presenter/main.cpp:326` and `platform/windows-reverse/main.cpp:345`. | Standard/extended keys, F13–F24, keypad, international, media/browser keys have portable round trips. Pause uses VK_PAUSE because WM_KEY cannot encode E1. Native Windows compile/injection unverified. |
| C2 | `platform/desktop-app/test_pairing_profiles.py:35` asserts the ordered 3×3 component/endpoint matrix and explicitly records W1/M1/L1 as missing handoff. Existing profile, option, quality and optional validator loops also cover the diagonal. | Profile suite: 8 passed, 1 optional built-binary test skipped. No claim of operational handoff from successful profile generation. |

### Scroll compatibility

The shared contract retains the existing AppKit and Linux-presenter wire sign:
positive on either axis is AppKit-positive / Wayland-negative. Linux's detent
encoding is unchanged, including fallback from its axis distance. Mac now decodes
120 units as one line instead of 40 pixels; precise input is points instead of
being amplified by about 333×. Quartz selects line-to-pixel behavior for line
scrolling. Native scrolling feel is unverified; pixel-identical behavior to the
old fixed 40-pixel conversion is not claimed.

Horizontal Windows messages use the opposite convention, so the Windows
presenter and source now invert horizontal amounts at their native boundaries.
Windows↔Windows remains a sign-preserving round trip; Windows↔Mac and
Linux↔Mac now share one documented direction convention. The previous Mac source
had an unconditional extra horizontal negation; that is removed. Update both
Windows native window endpoints together. Mixed old/new Windows horizontal
behavior is not guaranteed. The window record layout is unchanged.

The portable key table intentionally rejects unassigned/OEM scan codes with no
specified evdev identity; it does not invent text events. It covers the requested
key classes and handles NumLock/PrintScreen aliases and Pause distinctly. The
new source-platform selection defaults unknown standalone Linux receivers to
wheel fallback. Existing standalone Windows recipes can opt into their known
Windows source using `VIEWFLOW_REVERSE_SOURCE_PLATFORM=windows`; paired profiles
set this automatically. The Mac HID probe, readiness flag and native-report
format are unchanged.

API references checked: [Apple scroll event creation](https://developer.apple.com/documentation/coregraphics/cgeventcreatescrollwheelevent),
[Apple scroll units](https://developer.apple.com/documentation/coregraphics/cgscrolleventunit),
[Apple scroll phases](https://developer.apple.com/documentation/coregraphics/cgscrollphase),
and [Microsoft keyboard scan-code mapping](https://learn.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input).

### Follow-up validation

Build/test outputs stay under `/tmp`, not installed paths. No service, focus,
plugin, SSH, live input, or user clipboard operation was performed.

- `cmake -S platform/reverse-common/tests -B /tmp/viewflow-samesys-input-build -DCMAKE_BUILD_TYPE=Debug`
  and `cmake --build /tmp/viewflow-samesys-input-build -j 4`: passed.
- `ctest --test-dir /tmp/viewflow-samesys-input-build --output-on-failure`: 3/3 passed
  (`scroll_units`, `touchpad_routing`, `windows_keys`).
- `cmake -S platform/linux-reverse -B /tmp/viewflow-samesys-linux-build -DCMAKE_BUILD_TYPE=Debug`
  and `cmake --build /tmp/viewflow-samesys-linux-build -j 4`: passed, including
  `viewflow_linux_reverse` and all test targets.
- `LIBGL_ALWAYS_SOFTWARE=1 __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json ctest --test-dir /tmp/viewflow-samesys-linux-build --output-on-failure`:
  20/20 passed. EGL tests use offscreen Mesa software rendering, not the compositor.
- `PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s platform/desktop-app -p test_pairing_profiles.py -v`:
  8 passed, 1 skipped because the optional native bundle is absent. `spake2` remains
  absent. Its import is deferred to `authenticate`; profile generation and real
  certificate creation/validation need no PAKE package. No fake module injection.
- Selected `test_pairing_protocol.PairingProtocolTests` methods
  `test_each_side_keeps_its_private_key`, `test_ipv6_scope_is_local_to_receiving_socket`,
  and `test_manual_addresses`: 3/3 passed. PAKE/network service tests were not run.
- `PYTHONDONTWRITEBYTECODE=1 python tools/tests/macos-window-source-test.py` and
  `PYTHONDONTWRITEBYTECODE=1 python tools/tests/macos-window-share-test.py`: passed.
- Initial portable build caught a signed/unsigned comparison warning in the new
  Windows test under `-Werror`; corrected the test variable type, rebuilt and passed.
- No Rust source changed; cargo tests were not required or run. macOS/Windows
  platform binaries were not built on this Linux host. Native
  scroll phases, keyboard layouts/IME/media-key dispatch, simultaneous control,
  physical HID, and mixed-version deployment remain unverified.

Changed deliverables: Linux `viewflow_linux_reverse` plus desktop-app Python
profile/protocol files; Mac `viewflow-macos-windows` plus the bundled Python pairing
helper modules; Windows `viewflow-windows-windows` and `viewflow_windows_reverse`
plus desktop-app Python profile/protocol files. `vf-window-peer`, `vf-clipboard-peer`
and compositor plugins are unchanged.

## Scope and result

Code review of the paired application launch path, in Windows, macOS, Linux order. No product code changes or commits. No native processes, live input, focus changes, compositor commands, SSH, deployments, or installed configuration changes were performed. This report is the only worktree change.

“Partly” below means paths exist in code, with identified missing or broken features. It does **not** mean either direction passed a live acceptance test. No pair earns “works” from this review.

| Pair | Overall status | Pairing | Window sharing A→B and B→A | Whole desktop / free cursor handoff |
|---|---|---|---|---|
| Windows↔Windows | **partly** | No same-OS rejection found | Source and presenter exist on both ends; sharing requires parking display bounds | Not configured for this pair |
| macOS↔macOS | **partly** | No same-OS rejection found | ScreenCaptureKit source and AppKit presenter exist on both ends; precise scroll bug | Input listeners exist, but no Mac edge-capture sender is launched |
| Linux↔Linux | **partly** | No same-OS rejection found; some service tests already use two Linux identities | Hyprland source and Wayland presenter exist on both ends; touchpad fallback bug | Both ends launch senders to input ports without receivers |

Linux here means the implemented **Hyprland/plugin source**, with its capture/encoder prerequisites, not arbitrary Linux compositors. A window-only stream is not a full desktop video stream. Input to a remote proxy is not free cursor handoff between physical desktops.

Severity: **blocker** prevents the named feature; **bug** produces incorrect behavior on a reachable path; **gap** is missing implementation or acceptance coverage; **doc** is misleading or incomplete documentation/UI. Blockers below are feature-specific, not claims that pairing fails.

## Shared pairing, identity, topology and transport facts

Verified by reading current code:

- Device validation allows `linux`, `windows`, and `macos` independently. It does not require the peer OS to differ: `platform/desktop-app/pairing_protocol.py:135`.
- Identity is a persisted random 128-bit ID, not the OS or hostname: `platform/desktop-app/pairing_service.py:109`. Discovery rejects the local **ID**, not the local OS: `platform/desktop-app/pairing_service.py:375`. Two fresh installations with the same hostname remain distinct. Copying an installation's identity file to another machine would make it appear to be self; that is an identity-cloning issue, not a same-OS requirement.
- Pair certificates use `vf-<device-id>.local`, a fresh pair CA, and client/server usages: `platform/desktop-app/pairing_protocol.py:179`. Matching hostnames do not create a certificate-name collision.
- Pairing defaults to TCP 44331 (`platform/desktop-app/pairing_protocol.py:26`); media/input/clipboard ports are locally allocated UDP ports (`platform/desktop-app/pairing_service.py:59`). Equal port numbers on different LAN IP addresses are valid. Local sockets, profile paths and locks on separate computers are not a LAN namespace collision. Port allocation releases its reservation before workers start, so local bind races remain possible independently of OS equality; this review did not exercise them.
- Group profiles scope files/components by peer ID and Linux routes by local ID plus slot: `platform/desktop-app/pairing_profiles.py:183`, `platform/desktop-app/pairing_profiles.py:197`. Group roles are explicit, not inferred from platform: `platform/desktop-app/pairing_profiles.py:158`.
- Display layout keys are device IDs; labels are not routing keys. Relative positions become per-link `share_origin`: `platform/desktop-app/pairing_service.py:222`, `platform/desktop-app/pairing_service.py:239`. Two monitors both called the same name do not collide through this code. The advertised device has one width/height/scale (`platform/desktop-app/pairing_protocol.py:145`), not a complete physical monitor inventory. Arbitrary multi-monitor, mixed-DPI and negative-origin behavior is unverified.
- Window transport has explicit `Source` and `Presenter` roles (`crates/viewflowd/src/bin/vf-window-peer.rs:8`). The older `windows_source` name in the common bridge controls stream direction and capability probes, not an OS comparison (`crates/viewflowd/src/reverse_bridge.rs:252`). Magic/version, activity and work-area negotiation exist at `crates/viewflowd/src/reverse_bridge.rs:263`. Profile selection is still OS-based, not a complete feature-capability negotiation; see L2 and C2.
- Clipboard selects exactly one dialer by device-ID ordering for all three pairs: `platform/desktop-app/pairing_profiles.py:54`, `platform/desktop-app/pairing_profiles.py:75`. The dialer and listener both start the bidirectional clipboard synchronizer: `crates/viewflowd/src/bin/vf-clipboard-peer.rs:33`, `crates/viewflowd/src/bin/vf-clipboard-peer.rs:74`.

## Windows↔Windows

### W1 — blocker: no paired desktop/cursor-handoff path

**Evidence:** `platform/desktop-app/pairing_profiles.py:81`, `platform/desktop-app/pairing_profiles.py:88`, `platform/desktop-app/pairing_profiles.py:95`, `platform/desktop-app/pairing_profiles.py:120`.

**Fact:** A Windows↔Windows link builds clipboard, window presenter, and (with `share_bounds`) window source components. The desktop branch requires at least one Linux peer. Neither Windows side starts an edge-input sender or desktop receiver for this pair.

**Scenario:** A user pairs two Windows PCs and moves the pointer across the configured screen edge expecting control of the other desktop. Pairing and proxy windows do not provide that handoff. The generated profile also does not enable a whole-desktop video path.

**Suggested fix:** Add a Windows desktop input source and matching receiver launch recipe, using negotiated capabilities and device routing. Treat whole-desktop capture as a separate feature from per-window capture. Until implemented, state the supported window-only scope in the UI. Do not disconnect otherwise usable window/clipboard sessions.

### W2 — gap: sharing requires pre-existing, unambiguous parking-display geometry

**Evidence:** `platform/desktop-app/pairing_profiles.py:88`, `platform/desktop-app/pairing_profiles.py:94`; `platform/desktop-app/pairing_display.py:6`.

**Fact:** Without `share_bounds`, the profile deliberately omits the Windows source and emits a notice. The display probe accepts one active display whose description contains `virtual`; zero or multiple candidates yield no bounds.

**Scenario:** Two normal Windows installations can pair and receive, yet neither can share windows if neither has an enabled parking display. Two eligible virtual displays also leave selection unresolved.

**Suggested fix:** Provide an explicit parking-display selection/provisioning workflow and retain receiver/clipboard functionality while that prerequisite is absent. This is a technical source requirement, not grounds to prohibit same-OS pairing.

### W3 — bug: window input has an incomplete Windows key round trip

**Evidence:** `platform/windows-window-presenter/main.cpp:323`, `platform/windows-window-presenter/main.cpp:415`; `platform/windows-reverse/main.cpp:341`.

**Fact:** The presenter drops non-extended scan codes above 88 and extended codes outside its switch. The source similarly rejects most evdev codes above 88. This window path does not inherit the broader standalone Windows input backend's key coverage.

**Scenario:** A key message with non-extended scan code `0x64` (an F13 mapping) returns zero and is swallowed at the proxy. A remote Windows application depending on that key never receives it. Unsupported extended keys have the same failure shape.

**Suggested fix:** Use a shared, complete Windows scan-code/evdev translation table with round-trip tests for extended, function, keypad and international keys. Keep Ctrl/Alt/Win distinct. Ordinary modifiers already round-trip through the current table; no Mac-style Ctrl/Command swap was found here.

### Other Windows checks

- **Bidirectional window path exists:** each side can launch `viewflow_windows_reverse` as source and `viewflow-windows-windows` as presenter (`platform/desktop-app/pairing_profiles.py:78`). Source discovery/capture eligibility is at `platform/windows-reverse/main.cpp:402`; native proxy creation is at `platform/windows-window-presenter/main.cpp:648`. Actual WGC/decoder/device prerequisites and both-direction operation were not run.
- **Pointer and wheel:** proxy messages become portable input at `platform/windows-window-presenter/main.cpp:411`; source uses Windows wheel/input injection at `platform/windows-reverse/main.cpp:338`. There is ordinary wheel forwarding, not a Windows physical-HID capture path in this presenter.
- **Proxy recursion:** source excludes all window classes starting with `Viewflow` (`platform/windows-reverse/main.cpp:411`); presenter classes are `ViewflowPortableWindow` and `ViewflowPortableShadow` (`platform/windows-window-presenter/main.cpp:648`). Dragging a received proxy into the parking display should therefore not enroll it as a new source, based on these guards.
- **Input feedback:** normal window input targets the original source window, while the presenter forwards events addressed to its proxy. Focus loss sends release (`platform/windows-window-presenter/main.cpp:421`). These facts reduce direct proxy echo; they are not proof against global-cursor interactions during simultaneous control. No automatic desktop handoff is configured, so a functioning symmetric edge-handoff loop cannot be claimed or tested from these profiles.

## macOS↔macOS

### M1 — blocker: two input listeners do not create desktop handoff

**Evidence:** `platform/desktop-app/pairing_profiles.py:48`; `platform/macos-app/Sources/AppModel.swift:252`, `platform/macos-app/Sources/AppModel.swift:265`, `platform/macos-app/Sources/AppModel.swift:363`.

**Fact:** Both profiles contain an input bind and window destinations. The app launches `viewflowd serve` for input, and source/presenter workers for windows. It does not launch a Mac desktop edge-capture sender. The Linux cursor executable is Linux-only (`crates/viewflowd/src/bin/vf-cursor-peer.rs:1`).

**Scenario:** Two Macs pair and exchange windows, but moving the mouse off a physical display does not send a desktop-control stream to the other Mac. Native HID receiver availability alone does not supply the missing sender.

**Suggested fix:** Implement and launch the Mac desktop sender with explicit handoff ownership, release-on-return and recovery. Keep working per-window input independent. Do not describe input-listener startup as successful desktop handoff or full-desktop streaming.

### M2 — bug: Mac precise-scroll units are decoded as wheel units

**Evidence:** `platform/macos/window_presenter.mm:1007`; `platform/macos/window_source.mm:582`.

**Fact:** The Mac presenter emits precise deltas in **milli-points**, sets `c=precise`, and carries gesture end in `d`. The Mac source ignores both flags and always divides the amount by 3 before creating a pixel scroll event.

**Scenario:** A precise vertical delta of 1 point produces `b=1000`; the remote Mac posts approximately 333 pixels. Gesture-end metadata is ignored. This is a sender/receiver contract mismatch visible without native execution. Actual app scroll distance and horizontal-direction behavior still require native validation.

**Suggested fix:** Define shared scroll units and phase semantics. Decode precise milli-points separately from detents; preserve gesture end. Add Mac→Mac serializer/decoder tests for both axes, small deltas, momentum and end/cancel. Do not compensate with OS-specific timing restrictions.

### Other macOS checks

- **Both directions exist:** each Mac's window sender connects to the other's presenter. Workers are peer/window-scoped (`platform/macos-app/Sources/AppModel.swift:268`, `platform/macos-app/Sources/AppModel.swift:355`). ScreenCaptureKit and input permissions remain native prerequisites, not same-OS exclusions.
- **No unconditional modifier swap found:** presenter uses `evdev_key` (`platform/macos/window_presenter.mm:1021`); source uses `mac_key` (`platform/macos/window_source.mm:566`). Both use the same 115-entry table (`platform/macos/window_keys.hpp:7`). Command maps to GUI and back; Control remains Control. A pure table check found no duplicate mapping in either direction.
- **Shortcut caveat, unverified behavior:** `platform/macos/window_presenter.mm:847` tries configurable `linux_first` rules, then the local responder/menu chain, then remote delivery. The names/comments assume a Linux remote, but the function does not itself remap modifiers. The paired app supplies no remote-platform shortcut policy in its presenter arguments (`platform/macos-app/Sources/AppModel.swift:277`). Whether specific Command shortcuts are consumed locally is unverified; test Cmd-Q/W/C/V and system-reserved shortcuts on two Macs before claiming parity. Do not treat the name alone as a confirmed bug.
- **Raw HID:** the AppKit presenter emits pointer/button/key/scroll events; its scroll path is not a raw native-HID sender. Mac receiver support cannot make Mac↔Mac raw touchpad forwarding work by itself. M2 also breaks the ordinary precise-scroll fallback.
- **Proxy recursion guard:** native enrollment excludes `org.viewflow.*` and helper executable/application prefixes (`platform/macos-app/Sources/Configuration.swift:245`). Separate helper processes are covered by the executable-name check. Source events carry a Viewflow user-data marker (`platform/macos/window_source.mm:354`), but this review did not establish complete marker filtering across all observation paths. Simultaneous two-user global cursor interaction remains unverified.

## Linux↔Linux

### L1 — blocker: cursor senders target absent input listeners

**Evidence:** `platform/desktop-app/pairing_profiles.py:106`, `platform/desktop-app/pairing_profiles.py:112`, `platform/desktop-app/pairing_profiles.py:120`; `tools/paired-linux-session.py:47`; `crates/viewflowd/src/bin/vf-cursor-peer.rs:20`.

**Fact:** Both Linux profiles launch `paired-linux-session`, which selects `vf-cursor-peer` for any non-Windows peer. Each sender targets the other peer's `input` port. Neither profile creates a listener on that port; `windows-receive` listens on the separate `windows` port. Merely enabling the existing `viewflowd --input-backend native` recipe is not a demonstrated solution: its documented native backend targets Windows/macOS (`crates/viewflowd/src/lib.rs:230`).

**Scenario:** Two Hyprland machines pair successfully; both cursor workers attempt a connection to an unused input service. Per-window sharing can still be launched, but crossing into the remote viewport cannot control the other desktop. No Linux full-atlas desktop receiver is selected either.

**Suggested fix:** Add the Linux desktop input receiver and explicit capability-based role selection. Preserve the independent window and clipboard links while cursor setup recovers. Do not repeatedly launch a known-incompatible cursor recipe merely because the peer is not Windows.

### L2 — bug: Linux receiver is treated as Windows for raw touchpad forwarding

**Evidence:** `platform/desktop-app/pairing_profiles.py:84`; `platform/linux-reverse/main.cpp:255`, `platform/linux-reverse/main.cpp:432`, `platform/linux-reverse/main.cpp:1471`; `platform/linux-window-input/main.cpp:231`, `platform/linux-window-input/main.cpp:252`.

**Fact:** Linux↔Linux leaves `mac_shadow` false. The presenter discovers a physical touchpad and, on the non-Mac branch, emits Windows-style `touchpad_contact` / `touchpad_frame` records without a Linux receiver capability check. When the touchpad is available, finger-origin Wayland wheel events are suppressed. The Linux source input helper does not implement those record kinds. It returns a recoverable error and releases held input rather than exiting.

**Scenario:** With a discoverable local touchpad, two-finger scrolling over a remote Linux proxy loses the wheel fallback and sends unsupported touch records. With no discoverable raw touchpad, that suppression condition is false and ordinary wheel forwarding remains. The desktop sender's HID environment flags at `platform/desktop-app/pairing_profiles.py:133` do not configure this separate window presenter.

**Suggested fix:** Negotiate supported input formats per window source. For a Linux source, retain wheel fallback unless a compatible touchpad receiver is present. Apply the user's HID setting to window presentation as well. Unsupported optional touch input must retain the session and unrelated windows; the helper's existing local recovery is preferable to a new disconnect rule.

### Other Linux checks

- **Window path exists both ways:** each side launches a presenter (`platform/desktop-app/pairing_profiles.py:81`) and the non-Windows window-sharing worker (`tools/paired-linux-session.py:54`). That worker uses `vf-hyprland-windows` and `viewflow-linux-window-input`. Source capture requires Hyprland/Viewflow and NVENC as described by `crates/viewflowd/src/bin/vf-hyprland-windows.rs:4`. No claim is made for GNOME/KDE or systems without the required encoder.
- **Keyboard:** Wayland evdev codes pass through the presenter (`platform/linux-reverse/main.cpp:468`) to the source's virtual keyboard (`platform/linux-window-input/main.cpp:195`). No unconditional Mac modifier swap was found. The source installs its own local keymap (`platform/linux-window-input/main.cpp:94`); remote layout/group/IME synchronization is not established by this physical-key transport. Different active layouts remain a coverage gap even when both OSes are Linux.
- **Pointer and recursion:** source button/motion delivery uses `with_forwarded_motion` (`platform/linux-window-input/main.cpp:189`). Enrollment excludes `ViewflowReverse-*` (`tools/macos-window-share-linux.py:16`), matching presenter app IDs (`platform/linux-reverse/main.cpp:1565`). This guards against re-sharing received proxies. It does not prove absence of input feedback under all capture/virtual-keyboard combinations.

## Findings shared by all three pairs

### C1 — gap: clipboard and file drag-and-drop have different support boundaries

**Evidence:** `crates/viewflowd/src/clipboard_sync.rs:229`, `crates/viewflowd/src/clipboard_sync.rs:253`; `docs/clipboard-sync.md:10`; `platform/reverse-common/wire.hpp:76`; `crates/viewflowd/src/lib.rs:2224`.

**Fact:** Clipboard text/PNG synchronization is OS-independent and suppresses echo by recording installed content as the observed baseline. Copied files, rich text and multiple flavors are not supported. The native window input protocol contains window manipulation and input kinds, not a file-drop transaction. General `FileDragOffer` handlers exist elsewhere in the daemon; their presence does not establish integration with these paired native proxies.

**Scenario:** Copying text between same-OS peers has an implemented route, but copying files or dragging a file from a local file manager onto a remote proxy has no demonstrated end-to-end paired-native drop path. Moving a *window* between displays is a separate operation.

**Suggested fix:** Document clipboard formats separately from file transfer and window dragging. Wire native drag source/destination adapters to the transfer protocol before claiming file drop support. Add two-direction file tests per pair. File drop completion and clipboard native installation were not verified here.

### C2 — doc: UI settings and “every platform pair” tests obscure capability gaps

**Evidence:** `platform/desktop-app/qml/Main.qml:578`; `platform/desktop-app/test_pairing_profiles.py:115`, `platform/desktop-app/test_pairing_profiles.py:46`, `platform/desktop-app/test_pairing_profiles.py:155`; `README.md:76`.

**Fact:** The HID switch is shown for remote members without a per-feature compatibility condition. The profile test named `test_every_platform_pair_generates_local_allowlisted_profile` uses combinations of distinct OSes; quality/option tests use permutations, also excluding equal pairs. Native offline-validator pairs are explicitly cross-OS. README's window-sharing description names macOS↔Hyprland/Windows, not a same-OS support matrix.

There **are** Linux↔Linux pairing-service fixtures: the default platform is Linux (`platform/desktop-app/test_pairing_service.py:16`), and reconnect tests construct host/client with that default (`platform/desktop-app/test_pairing_service.py:133`). Those verify control-plane intent, not native window/desktop compatibility. Do not describe the repository as having no same-OS tests at all.

**Scenario:** A green “every platform pair” profile test misses L1. An enabled HID toggle suggests effective forwarding even where there is no sender or compatible source input decoder.

**Suggested fix:** Test the full ordered 3×3 platform matrix. Assert complementary endpoints and input capabilities, not only valid JSON. Add same-OS scroll/key round trips, proxy-exclusion fixtures, identical hostname/display-label fixtures, and recovery tests with simultaneous streams. Show capabilities and prerequisites in the UI while retaining usable lanes. Publish a matrix that distinguishes code paths, offline proof and user-operated native acceptance.

## Verification and limits

Completed:

1. Read repository `AGENTS.md` and `docs/security-and-availability-policy.md`. Findings and suggested fixes treat 33 ms as a target, not a cutoff. No new focus/freshness authorization restriction is recommended.
2. Read profile generation, app worker construction, common transport, source/presenter input and enrollment code for all three pairs. All line references above are for the reviewed HEAD.
3. Ran an isolated Python AST fixture against the actual pure functions `valid_id`, `validate_device`, `endpoint`, `geometry`, `quality_mode`, and `build_profile`. It extracted function definitions without importing the pairing service or starting any sockets/native workers. Fixtures used distinct IDs, identical hostnames and identical service port numbers on the two modeled devices, synthetic certificate strings, and Windows parking bounds. Results:
   - Windows: each profile contains `clipboard`, `windows-receive`, `windows-share`.
   - macOS: each profile contains window destinations/listener configuration and an input bind.
   - Linux: each profile contains `clipboard`, `windows-receive`, `desktop-share`; both target the remote input port, neither creates that listener.
   - Exactly one clipboard dialer for every pair.
   - The 115 Mac key-table entries have unique forward/reverse mappings; Command and Control are distinct.

The AST check is **configuration/table evidence only**. It bypasses module imports and uses fake PEM strings. It does not prove PAKE, TLS, materialization, native decoding, pairing over a LAN, or native input delivery.

Failed / not run:

- Attempted to import and run the existing offline profile unittest methods with `PYTHONDONTWRITEBYTECODE=1 python`, excluding the optional real-binary validator. Import failed before tests ran: `ModuleNotFoundError: No module named 'spake2'` at `platform/desktop-app/pairing_protocol.py:23`. No dependency installation or workaround that changes product files was performed. No existing unittest pass is claimed.
- No builds, native executables, hardware captures, pairing-service network tests, clipboard reads/writes, or live acceptance tests were run.
- No proof of same-OS simultaneous-control behavior, cursor ping-pong absence, physical touchpad semantics, multi-monitor/DPI correctness, IME behavior, elevated Windows target control, or sustained bidirectional stream recovery. These need hermetic adapter tests followed by separately authorized, user-operated native acceptance. They are not assumed to work because an opposite-OS path worked previously.

Review acceptance: requested code-review scope and evidence report complete; native feature acceptance remains unverified. Product code and Git history unchanged.

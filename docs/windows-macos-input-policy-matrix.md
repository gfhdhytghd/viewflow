# Windows to macOS input-policy coverage matrix

This is an implementation and test-coverage comparison, not a promise that the
two operating systems have the same native input APIs.  It separates policies
that can be shared from Windows-only mechanisms such as the secure desktop,
Precision Touchpad injection, and the Windows shell's Win key behavior.

The current incident to keep in mind is a Linux `Super+Q` binding being
captured and delivered to macOS as `Command+Q`.  The macOS receiver deliberately
maps HID GUI to Command; the table therefore does not describe that mapping as
a keyboard-layout bug.

| Policy / behavior | Windows coverage | macOS coverage | Status and required next step |
| --- | --- | --- | --- |
| Local shortcut wins over cross-desktop capture | The Windows proxy has a tested Win-key reservation policy: a reserved Win press is replayed when unused, while a Win key consumed by a native move or an owner loss is drained rather than replayed. | The Quartz receiver maps HID GUI to Command, and accepts the following key normally. There is no receiver-side policy test for a locally-owned `Super+Q`/`Command+Q` pair. | **This round: add source-side local-binding capture exemption.** The decision belongs at the Linux capture boundary, before a HID event is put on the connection. It must be keyed by the actual local binding and target route, not a blanket ban on Command shortcuts. |
| `Super+Q` regression | `desktop_move_gesture_test` covers Windows reservation, replay, consumed tails, and focus/owner loss, although it does not itself model a Hyprland `Super+Q` binding. | No automated test currently proves that a Linux-local `Super+Q` is not forwarded as `Command+Q`, nor that the capture route survives the attempted shortcut. | **This round: add a configuration/integration test once `allow_input_capture` is represented in the source configuration.** It should check that a binding with `allow_input_capture: false` executes locally and produces no remote GUI/Q events; a binding marked true continues to be capturable. It must not synthesize desktop input. |
| Modifier shortcut used for native window move | Windows has `DesktopMoveKeyReservation` plus `DesktopSourceWinKeys`: it distinguishes tap, shortcut, move, and drain-only tails. | The Mac proxy uses Command+mouse for native drag, clears the remote held set, and drains later unmatched tails. Keyboard shortcuts use native-first fallback with configurable Linux-first exceptions. | **Implemented without a blanket Command ban.** The existing wire format is sufficient. |
| Keyboard forwarding eligibility | Windows validates the focused, foreground, visible proxy before forwarding keyboard input. | Mac now requires a key, visible proxy for ordinary keys and key equivalents. AppKit gets shortcuts first; only unhandled or configured Linux-first shortcuts are forwarded. | **Implemented.** No protocol change is indicated. |
| Cancellation while keys are physically held | Windows `KeyboardHeldState` records held usages, switches to a drain-only state on geometry cancellation, validates modifier masks, and rejects a new key-down until the physical tail is drained. | Mac records forwarded non-modifier keys and modifiers, emits `ReleaseAll` and clears both sets on focus loss or native shortcut handling, then ignores unmatched key-up tails. | **Implemented for the Mac native-window proxy.** Recovery remains local and keeps the connection alive. |
| Forced release of a shell modifier | Windows input cleanup sends a private cancellation mask before releasing a held Win key, preventing cleanup from looking like a standalone Win tap. Normal key-up remains unchanged. | Mac cleanup emits ordinary Command key-up. | **Not a direct Command+Q fix.** `Command+Q` is invoked when Q is delivered while Command is held, so the required P0 fix is the source capture exemption above. A Mac-specific cleanup mask needs an OS-level semantic and a focused test before being added; do not blindly copy the Windows unassigned-key trick. |
| HID key and button release coverage | Windows tests an exhaustive supported HID table plus all five mouse buttons and a stateless force-release plan. | Mac tests representative key mappings, duplicate/repeat behavior, buttons, wheel accumulation, and held-input cleanup. Its documentation explicitly rejects consumer/media usages and F21--F24. | **Known capability gap, not a shortcut policy.** Expand the Mac HID table and cleanup plan only when those usages have defined Quartz semantics; add an exhaustive mapping/release test in the same change. No wire upgrade is required. |
| Shared desktop absolute coordinates | Windows has physical-virtual-desktop normalization and negative-origin/range tests. | The Mac receiver accepts native Quartz desktop coordinates, while its deployment documentation says a shared-layout source must translate the origin first. | **Mac integration missing.** Add the shared-layout adapter and negative-origin/Retina tests. `DesktopPointerPosition` already carries the necessary coordinates, so this is not a protocol upgrade. |
| Source-proxy IME isolation | Windows creates its proxy under a thread-scoped IME-disable policy, retaining source-side text composition. | macOS native-window documentation still lists IME as future work; the AppKit proxy has no equivalent policy or test. | **Needs macOS proxy implementation and acceptance work.** Keep composition at the source application as specified by the architecture. Assess native AppKit input-context requirements first; no wire change is currently established. |
| Lock-screen / secure-desktop input | `ViewflowInput` has a LocalSystem service and a session worker that rebinds the active Windows input desktop. | There is no corresponding macOS mechanism in this repository. | **Platform-specific / do not port.** This is a Windows secure-desktop facility, not ordinary macOS cross-screen input parity. |
| Cursor-suppression system setting | The Windows service can clear `EnableCursorSuppression` after the first absolute pointer position of a lease. | No matching macOS setting exists in this project. | **Platform-specific / do not port.** Retain ordinary macOS pointer delivery and diagnose cursor visibility independently. |
| Raw precision-touchpad frames | Windows accepts raw frames over the cursor connection and injects them through the Windows synthetic touchpad API. | macOS keeps raw cursor touchpad mode disabled and uses the separate DriverKit HID bridge. | **Intentional platform split / no protocol upgrade implied.** Do not route Windows raw-touchpad settings into the Mac Quartz backend. DriverKit and its host remain the Mac implementation boundary. |

## Evidence boundaries

The Windows reservation and drain policies are native-window-proxy policies;
they are useful behavioral precedents, but they are not evidence that Windows
already has a generic Hyprland shortcut exception.  Likewise, macOS mapping
tests prove that GUI becomes Command, but do not prove whether the target app
consumed a Quartz post.

Relevant current sources and tests:

- Windows reservation and its tests: `platform/windows-composition-preview/desktop_move_gesture.h`, `platform/windows-composition-preview/desktop_move_gesture_test.cpp`.
- Windows cancellation state: `platform/windows-composition-preview/keyboard_input.h`, `platform/windows-composition-preview/keyboard_input_test.cpp`.
- Windows injector cleanup: `crates/viewflow-platform/src/windows_input.rs`.
- Mac Quartz mapping and cleanup: `crates/viewflow-platform/src/macos_input.rs`, `crates/viewflow-platform/src/macos_input/native.rs`.
- Mac native window key handling: `platform/macos/window_presenter.mm`, with mapping-only test `platform/macos/window_keys_test.cpp`.
- Deployment limitations: `deploy/macos/README.md`, `docs/windows-lock-input.md`, and `docs/linux-windows-touchpad.md`.

## Acceptance boundary

Automated coverage must use configuration, event records, or native event
construction only.  It must not post real keyboard/mouse input, change focus,
or terminate a Mac application to test `Command+Q`.  After code and deployment
checks pass, the user should physically verify that `Super+Q` creates the local
terminal while cursor capture remains connected, and that unrelated enabled
remote Command shortcuts still reach the selected Mac target.
